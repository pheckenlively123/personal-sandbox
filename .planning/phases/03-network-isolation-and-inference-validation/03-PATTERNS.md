# Phase 3: Network Isolation and Inference Validation - Pattern Map

**Mapped:** 2026-06-16
**Files analyzed:** 2 (rebuild.sh modified, README.md modified)
**Analogs found:** 2 / 2

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `rebuild.sh` | orchestrator/script | request-response (CLI gate chain) | `rebuild.sh` itself (Phase 2) + `scripts/verify-pins.sh` | exact (self-extension) |
| `README.md` | documentation | — | `README.md` itself (Phase 2) | exact (self-extension) |

---

## Pattern Assignments

### `rebuild.sh` (orchestrator, gate chain)

**Analog 1:** `rebuild.sh` (lines 1–219) — the file being extended; all new gates must match its conventions exactly.

**Analog 2:** `scripts/verify-pins.sh` (lines 1–280) — demonstrates the fail-closed, host-side verification discipline used in Phase 1. Every new gate in Phase 3 mirrors this posture.

---

#### Shebang and strict-mode pattern
`rebuild.sh` lines 1, 26:
```bash
#!/usr/bin/env bash
set -euo pipefail
```
All new functions added to `rebuild.sh` must operate under this top-level strict mode. Use `|| true` to suppress non-fatal errors where needed; never disable `pipefail` locally.

---

#### Logging helper pattern
`rebuild.sh` lines 33–40:
```bash
ts() { python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }

log_step() {
    echo "" >&2
    echo "=== [$(ts)] Step $1: $2 ===" >&2
}
log_info()  { echo "INFO: $1" >&2; }
log_error() { echo "ERROR: $1" >&2; }
```
New steps adopt `log_step N "description"` banners. New helper functions use `log_info` for progress and `log_error` before `exit 1`. All output goes to stderr.

---

#### Step-banner numbering pattern
`rebuild.sh` lines 119, 129, 136, 178 (existing Steps 1–4):
```bash
log_step 1 "Resolve cooldown versions and build container image"
log_step 2 "Tag :latest alias"
log_step 3 "Teardown existing sandbox and images"
log_step 4 "Create sandbox"
```
Phase 3 inserts one step before Step 1 (called "Step 0" or prepended to the preflight region) and adds Steps 5, 6, 7 after the existing Ready check. Numbering is sequential integers with the same `log_step N "..."` call.

**New step layout:**
```
Step 0 (new, before Step 1): Provider preflight — openshell inference get check
Step 1–4: unchanged
Step 5 (new, after Ready check): NET-04 — policy assertion
Step 6 (new): NET-05 — egress smoke test
Step 7 (new): D-06  — round-trip inference test (non-fatal)
```

---

#### Fail-closed preflight gate pattern
`rebuild.sh` lines 102–108 (tools-on-PATH preflight):
```bash
for cmd in podman openshell python3 jq; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        log_error "Required tool not found on PATH: ${cmd}"
        exit 1
    fi
done
log_info "Preflight passed — all required tools found"
```

`scripts/verify-pins.sh` lines 67–76 (fail-closed input validation):
```bash
if [[ ! -f "${LOCK_FILE}" ]]; then
    echo "FAIL: versions.lock not found at ${LOCK_FILE}" >&2
    exit 1
fi
```

The provider preflight (D-03) follows the same structure: check a condition, `log_error` with an actionable message, `exit 1`. Never silently continue on uncertainty.

---

#### Tolerate-absent vs hard-error teardown pattern
`rebuild.sh` lines 139–150 (tolerate-absent sandbox delete):
```bash
DELETE_OUT=$(openshell sandbox delete "${SANDBOX_NAME}" 2>&1) && true
DELETE_RC=$?
if [[ $DELETE_RC -ne 0 ]]; then
    if echo "${DELETE_OUT}" | grep -q "sandbox not found"; then
        log_info "Sandbox ${SANDBOX_NAME} not found — nothing to tear down"
    else
        log_error "openshell sandbox delete failed: ${DELETE_OUT}"
        exit 1
    fi
else
    log_info "Sandbox ${SANDBOX_NAME} deleted"
fi
```
Phase 3 applies the inverse discipline: a *present* Anthropic egress path (NET-04) or a *missing* provider (D-03) must hard-error. Use output capture + grep, not exit-code alone, when CLI exits 0 in both states.

---

#### Output capture with error suppression pattern
`rebuild.sh` lines 139, 206 and `scripts/verify-pins.sh` lines 154–163:
```bash
# Capture output and tolerate non-zero exit
DELETE_OUT=$(openshell sandbox delete "${SANDBOX_NAME}" 2>&1) && true
DELETE_RC=$?

# From verify-pins.sh: curl with silent failure
response=$(curl -sf "https://registry.npmjs.org/${pkg}" 2>/dev/null || true)
if [[ -z "${response}" ]]; then
    echo "FAIL: Registry query failed for ${pkg} (network error or empty response)" >&2
    VIOLATIONS=$(( VIOLATIONS + 1 ))
fi
```
For `openshell sandbox exec` calls specifically, always redirect stderr to `/dev/null` to suppress the non-fatal `/home/sandbox/.bash_profile: Permission denied` noise before capturing output. Pattern for all Phase 3 exec calls:
```bash
output=$(openshell sandbox exec --name "${SANDBOX_NAME}" --no-tty -- <cmd> 2>/dev/null) || true
rc=$?
```

---

#### jq-based assertion pattern (fail-closed)
`scripts/verify-pins.sh` lines 215–225 (recursive jq extraction):
```bash
TRANSITIVE_PAIRS=$(jq -r '
  def allpkgs: ...;
  .dependencies | allpkgs
' "${NPM_SNAPSHOT}" | sort -u)

if [[ -z "${TRANSITIVE_PAIRS}" ]]; then
    echo "FAIL: versions-npm.json has no transitive deps (malformed or empty)" >&2
    exit 1
fi
```
NET-04 uses the same posture: `jq -e` exits non-zero when no match is found (PASS state) and 0 when a match is found (VIOLATION). The surrounding `if` inverts the sense:
```bash
if echo "${policy_json}" | jq -e '<selector>' >/dev/null 2>&1; then
    log_error "VIOLATION: ..."
    exit 1
fi
log_info "PASS: ..."
```

---

#### Non-fatal warn-and-continue pattern
`rebuild.sh` lines 159–170 (image prune tolerate-error):
```bash
podman rmi --force --ignore "${img}" >/dev/null 2>&1 || true
...
podman image prune --force >/dev/null 2>&1 || true
```
D-06 (round-trip test) is the only Phase 3 gate that is non-fatal. Follow this same `|| true` pattern, then branch on `$rc` to log PASS or WARN without exiting:
```bash
response=$(... 2>/dev/null) || rc=$?
if [[ ${rc} -ne 0 ]]; then
    log_info "D-06 WARN: ... (non-fatal)"
    return 0
fi
```

---

#### Final summary banner pattern
`rebuild.sh` lines 213–218:
```bash
echo "" >&2
log_info "rebuild.sh complete — sandbox ${SANDBOX_NAME} is Ready"
log_info "  Image:          localhost/claude-sandbox:${BUILD_DATE}"
log_info "  Bind mount:     ${CLAUDESHARED_ABS} -> /claudeshared (read-write)"
log_info "  Policy:         ${PROJECT_ROOT}/policy.yaml"
log_info "  Egress audit:   ./rebuild.sh --audit (surfaces openshell logs)"
```
Phase 3 moves the "Ready" banner to after Step 7. Add new lines to the summary for the three new gates (NET-04 PASS, NET-05 PASS, D-06 round-trip status). The format is `log_info "  Label: value"` with two-space indent alignment.

---

#### Ready-check pattern (post-create gate)
`rebuild.sh` lines 205–211:
```bash
log_info "Verifying sandbox is in Ready state..."
if openshell sandbox list --names 2>/dev/null | grep -q "^${SANDBOX_NAME}$"; then
    log_info "Sandbox ${SANDBOX_NAME} is running"
else
    log_error "Sandbox ${SANDBOX_NAME} not found after create — check openshell logs for details"
    exit 1
fi
```
Phase 3's NET-04 and NET-05 gates slot in after this existing Ready check. The ready check itself is unchanged.

---

### Concrete Code Excerpts for the Three New Gates

These are the verified implementations from RESEARCH.md, annotated with the rebuild.sh conventions they must match:

#### Provider Existence Preflight (Step 0 / D-03)

Must use `|| true` on the subshell (exits 0 in all states), strip ANSI before grepping, and call `log_error` + `exit 1` on violation. Pattern mirrors the tools-on-PATH preflight at `rebuild.sh` lines 102–108:

```bash
check_inference_provider() {
    local output
    output=$(openshell inference get 2>&1 | sed 's/\x1B\[[0-9;]*[mK]//g')
    if echo "${output}" | grep -q "Not configured"; then
        log_error "Inference provider is not configured — sandbox create would hang ~290s."
        log_error "One-time setup (operator action, see README):"
        log_error "  openshell provider create --name claude-code --type claude-code --from-existing"
        log_error "  openshell inference set --provider claude-code --model <MODEL>"
        exit 1
    fi
    log_info "Inference provider configured — preflight passed"
}
```

Call site: immediately after the tools-on-PATH preflight loop, before `log_step 1`.

---

#### NET-04 Policy Assertion (Step 5 / D-02)

Must call `log_step 5 "..."`, use `jq -e` with inverted sense, and call `log_error` + `exit 1` on violation. Pattern mirrors `scripts/verify-pins.sh` jq assertion style:

```bash
assert_no_anthropic_egress() {
    local sandbox_name="${1}"
    local policy_json
    policy_json=$(openshell policy get "${sandbox_name}" --full -o json 2>&1)

    # jq -e exits 0 if a matching entry is found (VIOLATION), non-zero if no match (PASS)
    if echo "${policy_json}" | jq -e \
        '.policy.network_policies // {} | to_entries[] | .value.endpoints[]? | select(.host | test("anthropic"; "i"))' \
        >/dev/null 2>&1; then
        log_error "NET-04 VIOLATION: Direct Anthropic endpoint found in effective policy!"
        log_error "Policy output: ${policy_json}"
        exit 1
    fi
    log_info "NET-04 PASS: No direct Anthropic endpoints in effective policy"
}
```

---

#### NET-05 Egress Smoke Test (Step 6 / D-05)

Must use `2>/dev/null` on sandbox exec to suppress `.bash_profile` stderr noise, exit non-zero only on `rc -eq 0` (connection succeeded), and test two independent targets:

```bash
run_egress_smoke_test() {
    local sandbox_name="${1}"
    local -a targets=("https://api.anthropic.com" "https://example.com")

    for target in "${targets[@]}"; do
        local rc=0
        openshell sandbox exec --name "${sandbox_name}" --no-tty \
            -- curl --max-time 8 --silent "${target}" 2>/dev/null || rc=$?

        if [[ ${rc} -eq 0 ]]; then
            log_error "NET-05 VIOLATION: Egress to ${target} SUCCEEDED — zero-egress is broken!"
            exit 1
        fi
        log_info "NET-05 PASS: ${target} blocked (curl exit ${rc})"
    done
}
```

---

#### D-06 Round-Trip Test (Step 7, non-fatal)

Must use `|| rc=$?` (never bare `|| true` when the exit code is needed), parse JSON body not curl exit code for success detection, and `return 0` on all warn paths:

```bash
run_inference_round_trip() {
    local sandbox_name="${1}"
    local response rc=0

    response=$(openshell sandbox exec --name "${sandbox_name}" --no-tty \
        -- curl --max-time 30 --silent \
        -X POST https://inference.local/v1/messages \
        -H "Content-Type: application/json" \
        -H "x-api-key: placeholder" \
        -d '{"model":"any","max_tokens":10,"messages":[{"role":"user","content":"ping"}]}' \
        2>/dev/null) || rc=$?

    if [[ ${rc} -ne 0 ]]; then
        log_info "D-06 WARN: curl failed (rc=${rc}) — inference path unverified (non-fatal)"
        return 0
    fi
    if echo "${response}" | jq -e '.content | length > 0' >/dev/null 2>&1; then
        log_info "D-06 PASS: inference.local returned a model response"
    else
        local err
        err=$(echo "${response}" | jq -r '.error // "unknown"' 2>/dev/null || echo "${response}")
        log_info "D-06 WARN: inference.local error: ${err} (non-fatal — see README for provider setup)"
    fi
}
```

---

### `README.md` (documentation)

**Analog:** `README.md` itself (lines 1–74, Phase 2 version).

**Section structure pattern** (`README.md` lines 1–74):
```markdown
# personal-sandbox
<one-line description>

## Rebuilding the sandbox
<prose intro>
```bash
./rebuild.sh
```
<decision rationale paragraph>
### Options
### What the rebuild does
<numbered list matching rebuild.sh steps>
### Shared workspace (`~/claudeshared`)
---
## Post-session egress audit
<prose + code block>
### What to look for in the logs
<bullet list>
**Note:** <cross-reference note>
```

Phase 3 adds two new top-level sections after "Post-session egress audit":

1. **One-time inference provider setup** — documents the operator steps for `openshell provider create` + `openshell inference set` (D-04). Follows the `## Section\n<prose>\n```bash\n<commands>\n```\n**Note:**` pattern.

2. **Operator validation checklist** — documents the multi-turn interactive validation (D-07, criterion #2). Follows a `### Steps\n1. ...\n2. ...` numbered list under the section.

Also updates the **"What the rebuild does"** numbered list to include Steps 5–7.

---

## Shared Patterns

### Fail-closed gate discipline
**Source:** `scripts/verify-pins.sh` lines 67–87 and `rebuild.sh` lines 102–108
**Apply to:** All three new `rebuild.sh` functions (Steps 0, 5, 6)
```bash
# Pattern: capture output, check condition, log_error + exit 1 on violation
OUTPUT=$(command 2>&1) || true
if <violation-condition>; then
    log_error "<GATE-ID> VIOLATION: <what went wrong>"
    exit 1
fi
log_info "<GATE-ID> PASS: <what passed>"
```
Non-zero exit propagates immediately via `set -euo pipefail`. The only exception is D-06 (Step 7), which uses `return 0` explicitly on warn paths.

### stderr-to-/dev/null for sandbox exec
**Source:** Pattern documented in RESEARCH.md (Pitfall 4); consistent with `rebuild.sh` lines 159, 167 (`>/dev/null 2>&1 || true` pattern)
**Apply to:** All three `openshell sandbox exec` calls (Steps 6 and 7)
```bash
output=$(openshell sandbox exec --name "${SANDBOX_NAME}" --no-tty -- <cmd> 2>/dev/null) || rc=$?
```

### ANSI stripping before grep
**Source:** RESEARCH.md Pattern 1 (Pitfall 1 in Common Pitfalls section); no existing analog in codebase (first use)
**Apply to:** Step 0 (`check_inference_provider`) only
```bash
output=$(openshell inference get 2>&1 | sed 's/\x1B\[[0-9;]*[mK]//g')
```

### jq-e inverted assertion
**Source:** `scripts/verify-pins.sh` lines 133–144 (check_date function — exits 1 on violation found)
**Apply to:** Step 5 (`assert_no_anthropic_egress`)
```bash
# jq -e exits 0 when match found = VIOLATION; exits non-zero when no match = PASS
if echo "${json}" | jq -e '<selector>' >/dev/null 2>&1; then
    log_error "VIOLATION"; exit 1
fi
log_info "PASS"
```

---

## No Analog Found

No files in this phase lack a codebase analog. Both `rebuild.sh` and `README.md` are direct self-extensions with strong existing patterns, and `scripts/verify-pins.sh` provides the fail-closed gate discipline for all new assertion functions.

---

## Metadata

**Analog search scope:** `/Users/patrickheckenlively/git/personal-sandbox/` (root), `scripts/`
**Files scanned:** `rebuild.sh` (219 lines), `scripts/verify-pins.sh` (280 lines), `README.md` (74 lines)
**Pattern extraction date:** 2026-06-16
