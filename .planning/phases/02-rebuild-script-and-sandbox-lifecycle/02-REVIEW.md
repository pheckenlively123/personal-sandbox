---
phase: 02-rebuild-script-and-sandbox-lifecycle
reviewed: 2026-06-15T00:00:00Z
depth: standard
files_reviewed: 4
files_reviewed_list:
  - rebuild.sh
  - scripts/build-and-lock.sh
  - Dockerfile
  - policy.yaml
findings:
  critical: 1
  warning: 6
  info: 4
  total: 11
status: issues_found
---

# Phase 02: Code Review Report

**Reviewed:** 2026-06-15T00:00:00Z
**Depth:** standard
**Files Reviewed:** 4
**Status:** issues_found

## Summary

Reviewed the Phase 02 build/lifecycle surface: `rebuild.sh` (orchestrator), `scripts/build-and-lock.sh` (resolve→build→lock seam), `Dockerfile`, and `policy.yaml`. The scripts are generally careful — `eval` was correctly removed in favor of allowlist parsing, `set -euo pipefail` is used throughout, teardown is project-scoped (`localhost/claude-sandbox:*` only, never `rmi -a`), and `--from` uses a full local image ref (never `--from .`). Input-validation discipline is mostly present.

The most serious issue is a teardown/create ordering bug: the script deletes the OpenShell sandbox **after** building the new image but offers no rollback, and — more importantly — a non-idempotent `--name` collision path that can leave the system without a working sandbox if create fails. Several robustness gaps remain around unvalidated operator input propagating into `jq --argjson`, a non-anchored path-validation regex, an unquoted argument expansion in the audit path, and a Dockerfile that pulls an untrusted upstream HEAD with no integrity pinning.

## Critical Issues

### CR-01: `--audit` passes unquoted, word-split `${since_arg}` into `openshell` — and `audit_sandbox` can never receive a `since` value

**File:** `rebuild.sh:45-51`, `rebuild.sh:93-96`
**Issue:** Two coupled defects in the audit path:

1. `audit_sandbox` builds `since_arg="--since ${since}"` and then calls `openshell logs "${name}" ${since_arg} --source all` with `${since_arg}` **unquoted** so it word-splits into two argv elements. This is a deliberate-but-fragile idiom. Because `since` is never actually passed by the only caller (line 95 calls `audit_sandbox "${SANDBOX_NAME}"` with no second arg), `since` is always empty, `since_arg` is always `""`, and the unquoted-empty-variable then relies on `set -u` *not* firing. With `set -u` active, an **unquoted empty** expansion is tolerated, but if a future caller ever passes a `since` value containing whitespace or a glob, it will be split/globbed and can inject unintended `openshell` flags. The construct is also unreachable dead functionality as written (no CLI flag plumbs `since` through).

   This matters because the audit path is the operator's only egress-verification tool (D-07) and is documented as the safety mechanism; a silently-broken or injectable argument-assembly path in that tool is a correctness/security defect.

**Fix:** Use an array to assemble optional args safely, and only call the audit subcommand's argument plumbing if you actually expose it:

```bash
audit_sandbox() {
    local name="${1:-claude-sandbox}"
    local since="${2:-}"
    local args=(logs "${name}" --source all)
    [[ -n "$since" ]] && args=(logs "${name}" --since "${since}" --source all)
    openshell "${args[@]}"
}
```

If `--since` is not a supported CLI flag yet, remove the dead `since` plumbing entirely to avoid a latent injection seam.

## Warnings

### WR-01: Teardown of the running sandbox happens before create with no rollback — a failed `create` leaves no sandbox

**File:** `rebuild.sh:136-150` (delete) then `rebuild.sh:194-211` (create)
**Issue:** Step 3 deletes the existing `claude-sandbox` unconditionally, then Step 4 creates the new one. If `openshell sandbox create` fails (bad policy, image, mount rejection), the operator is left with **no** sandbox at all — the previously-working one is already gone. Decision D-01 calls for a full clean rebuild, but "clean rebuild" should not mean "destroy the working environment before the replacement is proven to come up." This is a blast-radius / availability defect.
**Fix:** Either (a) delete the old sandbox only after a successful create under a temporary name then rename/swap, or (b) wrap create in error handling that re-reports clearly that the prior sandbox was already torn down. Minimum mitigation:

```bash
if ! openshell sandbox create --name "${SANDBOX_NAME}" ... ; then
    log_error "Create failed AND prior sandbox was already deleted — no sandbox is active."
    log_error "Re-run ./rebuild.sh after resolving the create error."
    exit 1
fi
```

### WR-02: `COOLDOWN_DAYS` is never validated in `rebuild.sh` or `build-and-lock.sh` before reaching `jq --argjson`

**File:** `rebuild.sh:56,70,74,121`; `scripts/build-and-lock.sh:34,38,218`
**Issue:** Operator-supplied `COOLDOWN_DAYS` is passed verbatim from `rebuild.sh` → `build-and-lock.sh` → `jq -n --argjson cooldown_days "${COOLDOWN_DAYS}"` (line 218). Only `resolve-versions.sh` validates it (`^[0-9]+$`). The build-and-lock flow does call the resolver first, so a non-numeric value aborts there — but this is incidental, not defense-in-depth. If the resolver call order ever changes, or `--argjson` is reached with e.g. `COOLDOWN_DAYS="4} ,\"x\":1"`, jq would parse attacker-influenced JSON. The project mandates allowlist-validating operator inputs at each boundary.
**Fix:** Validate at entry in both wrappers:

```bash
if ! [[ "${COOLDOWN_DAYS}" =~ ^[0-9]+$ ]] || (( COOLDOWN_DAYS <= 0 )); then
    log_error "--cooldown-days must be a positive integer, got: '${COOLDOWN_DAYS}'"
    exit 1
fi
```

### WR-03: `CLAUDESHARED_ABS` validation regex is unanchored and permits embedded newlines / control characters

**File:** `rebuild.sh:186`
**Issue:** The guard `[[ "${CLAUDESHARED_ABS}" =~ ^/[^\"\'\\]+ ]]` is anchored only at the start (`^`), with **no `$` end anchor**. It matches any string that *begins* with `/` followed by one non-quote/backslash character — the rest of the string is unconstrained. A `HOME` value such as `/home/u"x` would still fail (good), but `/home/u\n"evil` matches because the regex only needs a prefix match; the `"` later in the string is never examined. Since `CLAUDESHARED_ABS` is interpolated raw into the `--driver-config-json` JSON string (line 198), an unescaped `"` or `\` reaching that point breaks JSON or injects mount fields.
**Fix:** Anchor both ends and forbid all JSON-hostile characters across the whole string:

```bash
if ! [[ "${CLAUDESHARED_ABS}" =~ ^/[^\"\\$'\n'$'\r']+$ ]]; then
    log_error "CLAUDESHARED_ABS is not a safe absolute path: ${CLAUDESHARED_ABS}"
    exit 1
fi
```

Prefer building the JSON with `jq` (as Step 4 of build-and-lock already does for versions.lock) so escaping is handled by the tool rather than hand-validation.

### WR-04: Dockerfile clones an upstream toolkit over plain `git clone` with no commit pin or integrity check

**File:** `Dockerfile:59-60`
**Issue:** `git clone https://github.com/pheckenlWork/claude-engineering-toolkit.git` pulls whatever HEAD is current at build time, with no pinned commit/tag and no signature verification, then `--plugin-dir`-loads it into a Claude Code instance running `--dangerously-skip-permissions` (line 94). CLAUDE.md explicitly accepts this as trusted (IMG-05, T-01-05), so this is a documented risk-acceptance rather than an unknown hole — but the lack of even a commit pin defeats the reproducibility constraint the rest of the build works hard to satisfy (every other dependency is cooldown-pinned). A force-push or compromise of the fork silently changes what runs with elevated permissions.
**Fix:** Pin to a specific commit SHA for reproducibility and tamper-evidence:

```dockerfile
ARG TOOLKIT_REF
RUN git clone https://github.com/pheckenlWork/claude-engineering-toolkit.git /opt/claude-engineering-toolkit \
    && git -C /opt/claude-engineering-toolkit checkout "${TOOLKIT_REF}"
```

### WR-05: `--depth=Infinity` npm-ls snapshot captured with `|| true` can mask a non-existent or empty global tree

**File:** `Dockerfile:71-72`
**Issue:** `{ npm ls -g --json --depth=Infinity > /versions-npm.json || true; } && jq empty /versions-npm.json`. The `|| true` correctly tolerates npm's non-zero exit on extraneous/unmet peers (documented in the comment), and `jq empty` validates JSON syntax. But `jq empty` passes on `{}` or `{"problems":[...]}` — i.e. a snapshot that proves the global install tree is broken or empty would still satisfy the gate and ship as the "pin-held" evidence file. The downstream `verify-pins.sh` is expected to catch this, but the in-image gate gives false assurance.
**Fix:** Add a presence assertion that the snapshot actually lists the pinned packages, e.g. `jq -e '.dependencies["@opengsd/gsd-core"] and .dependencies["@anthropic-ai/claude-code"]' /versions-npm.json` after `jq empty`.

### WR-06: `podman tag` in Step 2 is not idempotent-safe against a partially-failed prior run

**File:** `rebuild.sh:130`
**Issue:** Step 2 runs `podman tag localhost/claude-sandbox:${BUILD_DATE} localhost/claude-sandbox:latest` with no guard. If `build-and-lock.sh` succeeded but a previous run died between build and teardown, this is fine; but the bigger issue is ordering — `:latest` is (re)pointed to today's image *before* teardown (Step 3) runs, and Step 3's keep-list (`KEEP_LATEST`) depends on that tag already pointing at the current build. That coupling is correct only when `BUILD_DATE` is unique per day. Two rebuilds on the **same day** reuse the same `:${BUILD_DATE}` tag, so the second run's "old image" loop (line 158-169) sees only the kept tags and the freshly-rebuilt image silently replaces the first — acceptable, but the date-only granularity means same-day rebuilds cannot coexist and there is no log noting the overwrite.
**Fix:** Either include a time component in the tag (`${BUILD_DATE}-$(date +%H%M%S)`) for uniqueness, or log explicitly that a same-day rebuild overwrites the prior `:${BUILD_DATE}` image so the operator is not surprised by the missing prior artifact.

## Info

### IN-01: Ready check only confirms presence in `sandbox list`, not "Ready" state

**File:** `rebuild.sh:204-211`
**Issue:** The log and comment claim "Verifying sandbox is in Ready state" but the check is `openshell sandbox list --names | grep -q "^${SANDBOX_NAME}$"` — that only proves the sandbox *exists* by name, not that it reached a Ready/running state. A sandbox stuck in `Error`/`Provisioning` would still pass.
**Fix:** Query actual status (e.g. `openshell sandbox get "${SANDBOX_NAME}" -o json | jq -r '.status'`) and assert it equals the ready value, or soften the log message to "Verifying sandbox exists."

### IN-02: `BUILD_DATE` is recomputed in `build-and-lock.sh` (line 212), discarding the validated value passed from `rebuild.sh`

**File:** `scripts/build-and-lock.sh:212`
**Issue:** `rebuild.sh` computes `BUILD_DATE` once (line 113) and passes it via `--build-date` so the image tag and lock metadata agree. But `build-and-lock.sh:212` overwrites `BUILD_DATE` with a fresh `date.today()` right before writing `versions.lock`. If a build straddles UTC midnight, the lock file's `build_date` can disagree with the image tag (`claude-sandbox:${BUILD_DATE}` from the passed-in value). Minor, but defeats the single-source-of-truth intent.
**Fix:** Remove line 212; reuse the already-validated `${BUILD_DATE}` from argument parsing.

### IN-03: `ts()` shells out to `python3` for every log banner

**File:** `rebuild.sh:33`
**Issue:** `ts()` spawns a Python interpreter per timestamp. `date -u +%Y-%m-%dT%H:%M:%SZ` produces the identical string with no subprocess-heavy dependency, and `date` is already assumed present. Minor quality/robustness (one fewer hard dependency on `python3` for logging, though python3 is preflight-checked).
**Fix:** `ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }`

### IN-04: `/app` listed read-only in policy but never created in the image

**File:** `policy.yaml:26`; `Dockerfile` (no `/app`)
**Issue:** The filesystem baseline grants read-only `/app`, but the Dockerfile never creates `/app`. This is harmless (a read-only grant on a missing path) and is carried over from the upstream default policy per the header comment, but it is dead configuration that can confuse future readers into thinking the app lives there.
**Fix:** Drop `/app` from the baseline if it is not part of this image, or add a comment noting it is inherited from the upstream default and intentionally unused.

---

_Reviewed: 2026-06-15T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
