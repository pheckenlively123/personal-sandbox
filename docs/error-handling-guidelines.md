# Error-Handling Guidelines

A repo-specific playbook for the bash scripts in this sandbox: `rebuild.sh`, `scripts/*.sh`, `tests/*.sh`. Every rule below is grounded in code already in the repo. The default posture is **fail-closed**: when a check cannot prove success, it must exit non-zero, never silently pass.

## 1. Script preamble (mandatory)

Scripts that reference local files resolve paths from `BASH_SOURCE` via one of two forms:

**`scripts/*.sh` and `tests/*.sh`** (in a subdirectory — need `..` to reach the project root):

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
```

**`rebuild.sh`** (at the project root — no parent traversal needed):

```bash
#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

**`resolve-versions.sh`** (no local file paths — defines neither):

```bash
#!/usr/bin/env bash
set -euo pipefail
```

Rules that apply to all scripts:

- `set -e` (exit on error), `-u` (unbound var = error), `-o pipefail` (a failed stage fails the pipe) are non-negotiable. Do not weaken them globally.
- Resolve paths from `BASH_SOURCE`, never `$0` or `pwd`. Scripts are invoked from multiple working directories.

## 2. Logging helpers — use them, do not reinvent

Standard helpers (defined in `rebuild.sh` and `audit-plugins.sh`):

```bash
ts() { python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }
log_step() { echo "" >&2; echo "=== [$(ts)] Step $1: $2 ===" >&2; }
log_info()  { echo "INFO: $1" >&2; }
log_error() { echo "ERROR: $1" >&2; }
```

- **All diagnostics go to stderr.** stdout is reserved for machine-parsable output (e.g. `resolve-versions.sh` emits clean `KEY=VALUE` on stdout; everything else `>&2`). Never `echo` an INFO line to stdout in a script another script parses.
- Use `log_error` immediately before an `exit 1` on a genuine failure. Use `log_step N "..."` to banner each phase.
- Helpers are **copy-pasted, not sourced** (`audit-plugins.sh` duplicates them deliberately to stay self-contained). Keep them in sync if you change one.
- Prefix-convention for echoed result lines (parsed by tests/humans): `INFO:`, `ERROR:`, `FAIL:`, `PASS:`, plus bracket tags like `[HANG]`, `[MISMATCH]`, `[UNEXPECTED]`.

## 3. `set -e` pitfalls this repo navigates

These are real footguns under `set -euo pipefail`. Follow the established forms exactly.

**3a. Capturing command output without aborting** — a bare `var=$(cmd)` aborts the whole script if `cmd` exits non-zero. To inspect the failure yourself, capture inside the `if`:

```bash
if ! policy_json=$(openshell policy get "${sandbox_name}" --full -o json 2>&1); then
    log_error "NET-04: 'openshell policy get' failed — cannot assert policy"
    exit 1
fi
```

**3b. Capturing an interactive exit code** — wrap with `set +e` / `set -e` to preserve the real rc (e.g. claude's `/exit`→0, Ctrl-C→130):

```bash
set +e
openshell sandbox exec --tty ... -- claude --dangerously-skip-permissions ...
exec_rc=$?
set -e
if [[ ${exec_rc} -ne 0 && ${exec_rc} -ne 130 ]]; then
    log_error "...exited ${exec_rc}..."
fi
exit "${exec_rc}"
```

The `down`/teardown variant uses `cmd 2>&1) && true; rc=$?` for the same effect when the value, not a branch, is what you need next.

**3c. `grep -c` integer guarantee** — `grep -c` prints `0` and exits 1 on no-match, which aborts under `set -e`. The correct form is `|| true` then `${x:-0}`:

```bash
statsig_count=$(echo "${log_output}" | grep -c 'DENIED.*claude\.exe.*statsig' || true); statsig_count=${statsig_count:-0}
```

Do **NOT** use `|| echo 0` — `grep -c` already printed `0`, so that double-counts to `"0\n0"` and breaks the later `[[ "${x}" -gt 0 ]]` arithmetic test. `${x:-0}` only guards the rare grep-error (exit 2, empty output) case.

**3d. Arithmetic increments** — `VAR=$(( VAR + 1 ))` is safe. A bare `(( x++ ))` evaluates to 0 on the first increment and **aborts under `set -e`**. Always use the assignment form:

```bash
VIOLATIONS=$(( VIOLATIONS + 1 ))   # safe
# (( VIOLATIONS++ ))               # FORBIDDEN — aborts when result is 0
```

## 4. Fail-closed validation (the default)

Pattern from `verify-pins.sh` (D-03) and `build-and-lock.sh`. A check must **never exit 0 on uncertainty**.

- **Missing inputs are fatal.** Validate every file before use: `[[ ! -f "${LOCK_FILE}" ]] && { echo "FAIL: ..." >&2; exit 1; }`.
- **Malformed JSON is fatal.** Validate with `jq empty "${FILE}"` before any `jq` query that assumes structure.
- **Empty registry responses are fatal / counted.** Every `curl -sf ... || true` must be followed by an empty-check; an empty or `null` result is a violation, not a pass (`npm_publish_date`, `check_date`, the govuln/gsd/claude fetches in `build-and-lock.sh`).
- **Unresolved transitive deps are fatal.** The flattener emits a `__MISSING__` sentinel for npm-missing/invalid nodes (WR-02) so the loop counts them rather than silently dropping them.
- **Registry-controlled output is allowlist-validated, never `eval`'d** (CR-02): resolver `KEY=VALUE` pairs and `BUILD_DATE` are regex-checked (`^[0-9]{4}-[0-9]{2}-[0-9]{2}$`, `^v?[0-9][0-9A-Za-z._-]*$`) and assigned via `printf -v`. Unknown keys → exit 1.
- **Validate non-empty before logging** (IN-01): under `set -u`, check `[[ -z "${!VAR:-}" ]]` and emit a friendly error *before* referencing the var unguarded.
- Helper convention: extract repeated checks into named helpers (`check_date()`, `npm_publish_date()`) that take `pkg`/`ver`/`pub_date` and update the shared `VIOLATIONS` counter.

## 5. Tolerate-absent vs. fatal

Most failures are fatal. The exception is **idempotent teardown**: "already gone" is success, everything else is fatal.

```bash
DELETE_OUT=$(openshell sandbox delete "${SANDBOX_NAME}" 2>&1) && true
DELETE_RC=$?
if [[ ${DELETE_RC} -ne 0 ]]; then
    # openshell wraps errors with box-drawing chars, splitting "not found".
    # Normalize to alnum+space before matching, so "not\n  | found" still matches.
    DELETE_NORM=$(printf '%s' "${DELETE_OUT}" | tr -dc '[:alnum:][:space:]' | tr -s '[:space:]' ' ')
    if printf '%s' "${DELETE_NORM}" | grep -qi "not found"; then
        log_info "Sandbox not found — nothing to delete (idempotent)"
    else
        log_error "openshell sandbox delete failed: ${DELETE_OUT}"
        exit 1
    fi
fi
```

Rules:
- **Normalize openshell output (`DELETE_NORM`) before pattern-matching** its human-formatted errors — box-drawing line-wraps will defeat a naive `grep`.
- **Only the specific "already absent" signal is tolerated.** Any other non-zero result is fatal. Never blanket-swallow with `|| true` on a state-changing command whose failure matters.
- Cleanup-only side commands (`podman rmi --force --ignore ... || true`, `podman image prune --force ... || true`) may use `|| true` because their failure does not affect correctness. Distinguish these from assertions, which must never be silenced.

## 6. Validate-before-assert (the NET-04 fetch guard)

Before asserting anything against fetched data, prove the fetch succeeded **and** is well-formed. A failed `openshell policy get` must not feed garbage into `jq` checks that would misreport as "host NOT found":

```bash
if ! policy_json=$(openshell policy get "${sandbox_name}" --full -o json 2>&1); then
    log_error "NET-04: policy get failed — cannot assert policy"; exit 1
fi
if ! echo "${policy_json}" | jq empty >/dev/null 2>&1; then
    log_error "NET-04: policy output is not valid JSON"; exit 1
fi
# ...only now run the jq -e selectors that assert host presence/absence
```

The same principle drives the telemetry check (§7): a failed `openshell logs` fetch must be a violation, not an empty string that reports a false PASS.

## 7. Accumulate-then-gate vs. fail-fast

Choose by intent:

- **Fail-fast** (return at first error): input/precondition validation, where there is nothing useful to continue past. Used throughout `verify-pins.sh` setup and `build-and-lock.sh` steps — each unmet precondition `exit`s immediately.
- **Accumulate-then-gate** (`VIOLATIONS` counter, hard-fail once at the end): audits that must report *every* failure in one run, not stop at the first. Used in `audit-plugins.sh` and the per-package loops in `verify-pins.sh`:
  - Each failure does `VIOLATIONS=$(( VIOLATIONS + 1 ))` (and appends to `FAILED_PLUGINS`) and `return 0` — never aborts the loop.
  - A final gate runs after all checks: `if [[ "${VIOLATIONS}" -gt 0 ]]; then log_error ...; exit 1; fi`.
  - A **failed sub-fetch counts as a violation**: a failed `openshell logs` increments `VIOLATIONS` (the statsig/sentry counts would otherwise default to 0 and report a false PASS — criterion #3 silently not evaluated).

## 8. Exit-code classification (audit harness)

`audit-plugins.sh` classifies each plugin invocation by exit code and output. Reuse this taxonomy:

- **124 = HANG** (timeout) → always FAIL, no exception (D-07).
- **MUST_SUCCEED**: exit 0 = PASS; any non-zero = `[UNEXPECTED]` FAIL.
- **MUST_FAIL_CLEAN**: exit 0 **alone is not a PASS** — output must also match a network/MCP error pattern (`grep -qiE "40[13]|connection refused|...|mcp.*error|..."`). Exit 0 with no such error = `[MISMATCH]` FAIL (D-10 — no WARN escape). Non-zero exit = `[UNEXPECTED]` FAIL.
- Unknown expected-verdict value → `[CONFIG]` FAIL (fail-closed on misconfiguration).
- Capture rc without aborting: `output=$(... 2>&1) || rc=$?`.

## 9. Traps and cleanup

- **Always clean up created resources via an `EXIT` trap**, and null the handle after manual cleanup so the trap is a no-op:

  ```bash
  cleanup_container() { [[ -n "${CID:-}" ]] && podman rm "${CID}" >/dev/null 2>&1 || true; }
  trap cleanup_container EXIT
  # ...later, after explicit rm:
  CID=""   # so the trap doesn't try to remove again
  ```

- **Split INT and TERM traps** to emit the conventional signal exit codes and a clear "partial run, no summary" message instead of a bare `set -e` abort:

  ```bash
  trap 'echo "ERROR: interrupted (SIGINT) — partial run, no summary." >&2; exit 130' INT
  trap 'echo "ERROR: terminated (SIGTERM) — partial run, no summary." >&2; exit 143' TERM
  ```

## 10. Argument parsing

- Validate required flag arguments: `--flag` with a missing value uses `[[ -z "${2-}" ]]` (note the `${2-}` form, safe under `set -u`) → error + exit 1.
- Support both `--flag value` and `--flag=value`; reject unknown args/verbs with a usage message and `exit 1` (fail-closed, never ignore).

## 11. Quick checklist before committing a script

- [ ] `set -euo pipefail` present; paths from `BASH_SOURCE`.
- [ ] Diagnostics on stderr; stdout clean if parsed downstream.
- [ ] No bare `var=$(cmd)` for fallible commands; no `(( x++ ))`; `grep -c` uses `|| true; ${x:-0}`.
- [ ] Inputs file-checked + `jq empty`-validated before use; empty fetches treated as failures.
- [ ] Fatal by default; tolerate-absent only for idempotent teardown, with normalized matching.
- [ ] Registry/CLI output allowlist-validated, never `eval`'d.
- [ ] Audit-style scripts accumulate `VIOLATIONS` and hard-fail once at the end; failed sub-fetches count as violations.
- [ ] `EXIT` cleanup trap (null the handle after manual cleanup); split `INT`/`TERM` traps where relevant.
