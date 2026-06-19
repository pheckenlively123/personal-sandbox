---
phase: 03-network-isolation-and-inference-validation
verified: 2026-06-16T00:00:00Z
status: human_needed
score: 3/4
overrides_applied: 0
human_verification:
  - test: "Confirm curl https://api.anthropic.com from inside the running sandbox fails (proxy error or connection refused)"
    expected: "curl exits non-zero; NET-05 smoke test logs PASS for both api.anthropic.com and example.com; rebuild.sh reaches summary banner without exit 1 from Step 6"
    why_human: "requires a live OpenShell sandbox with the zero-egress policy active; cannot be verified statically or without the runtime"
  - test: "Run ./rebuild.sh end-to-end after completing the provider setup documented in README; confirm Step 7 logs D-06 PASS"
    expected: "Summary banner shows Round-trip: PASS, confirming inference.local successfully brokered a model response"
    why_human: "requires a live OpenShell gateway with a registered claude-code provider and a running sandbox; the automated D-06 round-trip is non-fatal and the result cannot be verified without a live gateway"
  - test: "Confirm openshell inference get preflight (Step 0) exits with a clear error before sandbox create when no provider is registered"
    expected: "rebuild.sh exits 1 before any log_step 1 banner; the error message names the two operator commands (provider create and inference set); no ~290s hang occurs"
    why_human: "requires temporarily unregistering the provider on the live host (or a clean host without provider setup) to exercise the fail-closed path"
  - test: "Confirm the live policy assertion (Step 5) logs NET-04 PASS on the created sandbox"
    expected: "openshell policy get output contains no api.anthropic.com or other direct Anthropic endpoint; jq exits non-zero (no match); rebuild.sh logs NET-04 PASS and does not call exit 1"
    why_human: "requires a live created sandbox and the openshell policy get command to return real policy JSON; cannot be verified from the static script"
---

# Phase 3: Network Isolation and Inference Validation — Verification Report

**Phase Goal:** The running sandbox has zero direct internet egress enforced by the OpenShell policy, and Claude Code can successfully complete a model round-trip through the gateway inference broker — no direct connection to `api.anthropic.com` from inside the sandbox.
**Verified:** 2026-06-16
**Status:** human_needed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `curl https://api.anthropic.com` from inside the sandbox fails (net-zero egress proof) | ? UNCERTAIN — requires live runtime | NET-05 smoke test is correctly implemented: `run_egress_smoke_test` iterates over `api.anthropic.com` and `example.com`, captures curl exit code via `|| rc=$?`, exits 1 if `rc -eq 0`. Logic is correct but requires live sandbox execution to confirm |
| 2 | Claude Code inside sandbox completes live multi-turn interactive session via inference.local | ? UNCERTAIN — requires live runtime | `run_inference_round_trip` at Step 7 is non-fatal; README Operator validation checklist documents the >=2 round-trip requirement. Automation cannot substitute for the interactive session |
| 3 | `rebuild.sh` runs `openshell inference get` as preflight and exits with clear error if provider not registered | VERIFIED (static) | `check_inference_provider` defined at lines 48-59; called at line 226 after tools preflight (line 222) and before `log_step 1` (line 237); greps ANSI-stripped output for "Not configured"; exits 1 with actionable error naming both operator commands |
| 4 | Rebuild script asserts live egress policy contains no `api.anthropic.com` or direct Anthropic endpoint | VERIFIED (static) | `assert_no_anthropic_egress` defined at lines 69-83; called at Step 5 (line 335); uses inverted `jq -e` (exit 0 = match found = VIOLATION + exit 1; non-zero = no match = PASS); `// {}` guard handles absent `network_policies` key (the correct deny-all state) |

**Score:** 3/4 truths code-verified (static); 1/4 additionally requires operator validation

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `rebuild.sh` | `check_inference_provider`, `assert_no_anthropic_egress`, `run_egress_smoke_test`, `run_inference_round_trip` functions + call sites | VERIFIED | All four functions defined; each has exactly 2 occurrences (definition + call site) per grep output |
| `README.md` | "One-time inference provider setup" and "Operator validation checklist" sections with verbatim commands | VERIFIED | Both sections present at lines 91 and 125; `provider create --name claude-code --type claude-code --from-existing` and `inference set --provider claude-code` present verbatim |
| `policy.yaml` | Filesystem-only (Landlock schema); no `network_policies` or `network` section | VERIFIED | policy.yaml contains only `version`, `filesystem_policy`, `landlock`, `process` keys; explicit comment "Egress policy intentionally deferred to Phase 3. Do not add a network section here." |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| rebuild.sh main flow | `check_inference_provider` | Called at line 226, after `log_info "Preflight passed"` (line 222), before `log_step 1` (line 237) | WIRED | Ordering confirmed: preflight (222) < provider check (226) < Step 1 (237) |
| rebuild.sh main flow | `assert_no_anthropic_egress` | `log_step 5` at line 334; call at line 335; after Ready check (line 325); before Step 6 | WIRED | Ordering confirmed: Ready check (325) < Step 5 (334) < Step 6 (340) |
| rebuild.sh main flow | `run_egress_smoke_test` | `log_step 6` at line 340; call at line 341; before Step 7 | WIRED | Ordering confirmed: Step 5 (334) < Step 6 (340) < Step 7 (346) |
| rebuild.sh main flow | `run_inference_round_trip` | `log_step 7` at line 346; call at line 347; before summary banner (line 350) | WIRED | Ordering confirmed: Step 6 (340) < Step 7 (346) < summary (350) |
| README operator setup | `check_inference_provider` preflight | README commands (`provider create` + `inference set`) satisfy the preflight check that Step 0 asserts | WIRED | README documents both required commands verbatim; links to the preflight in the "What the rebuild does" step 0 entry |

---

### Logic Correctness Checks (in lieu of execution)

These are static code-correctness checks that verify the gate logic is implemented as specified, which is especially important for security-critical gates that cannot be live-tested in this verification pass.

| Check | Criterion | Evidence | Status |
|-------|-----------|----------|--------|
| Provider detection via ANSI-stripped output (not exit code) | `openshell inference get` exits 0 in all states; detection must grep "Not configured" | Line 50: `sed 's/\x1B\[[0-9;]*[mK]//g'`; line 51: `grep -q "Not configured"` — no branch on exit code | PASS |
| NET-04 inverted `jq -e` assertion | `jq -e` exit 0 = match found = VIOLATION; non-zero = no match = PASS | Lines 75-81: `if echo ... | jq -e ...` exits 0 triggers `exit 1`; else path logs PASS | PASS |
| NET-04 `// {}` null-guard | Absent `network_policies` field must be treated as empty (correct deny-all state) | Line 76: `.policy.network_policies // {} | to_entries[]...` | PASS |
| NET-05 two-target probe | Proves deny-all, not just Anthropic-specific block (T-03-02) | Line 96: `targets=("https://api.anthropic.com" "https://example.com")` | PASS |
| NET-05 PASS = curl exit != 0 | Blocked connection exits non-zero; VIOLATION = exit 0 only | Lines 99-106: `rc=0`; `|| rc=$?`; `if rc -eq 0 → exit 1`; else PASS | PASS |
| `sandbox exec` stderr suppressed | `.bash_profile: Permission denied` noise suppressed | Lines 100, 131-137: all `openshell sandbox exec` invocations carry `2>/dev/null` | PASS |
| `run_inference_round_trip` never calls `exit` | Non-fatal gate must never block the rebuild | Lines 127-153: function body inspected — `return 0` at line 142; no `exit` statement | PASS |
| D-06 success via JSON body parse (not curl exit code) | `inference.local` returns curl exit 0 even on gateway error | Line 144: `jq -e '.content | length > 0'` — curl exit ignored for success detection | PASS |
| No double `/v1` path in round-trip URL | `ANTHROPIC_BASE_URL=https://inference.local` (no `/v1`); raw curl targets full path once | Line 133: `https://inference.local/v1/messages` — single `/v1`; no `inference.local/v1/v1` anywhere in file | PASS |
| No `openshell policy update --add-endpoint` in rebuild.sh | CLAUDE.md anti-pattern: defeats zero-egress | Grep across entire rebuild.sh — string not present | PASS |
| `ROUND_TRIP_STATUS` propagates to summary banner | Banner must reflect actual round-trip outcome | Line 172: initialized `"NOT RUN"`; updated in function (lines 141, 146, 151); printed at line 357: `${ROUND_TRIP_STATUS}` | PASS |
| README anti-patterns absent | `--allow-dangerously-skip-permissions` must not appear as a usage instruction; `inference.local/v1` must not appear | `--allow-dangerously-skip-permissions` appears only in a "NOT" clause (line 144); no `inference.local/v1` in README | PASS |
| policy.yaml has no network section | D-01: filesystem policy and egress policy are separate concerns | policy.yaml keys: `version`, `filesystem_policy`, `landlock`, `process` only — no `network_policies` key | PASS |

---

### Data-Flow Trace (Level 4)

Not applicable — this phase delivers shell script gates, not components rendering dynamic data. All data flows are control-flow decisions (exit 0 / exit 1 / return 0) traced in the Logic Correctness Checks table above.

---

### Behavioral Spot-Checks (Step 7b)

Bash syntax check requires live execution. Bash execution was not available during this verification pass. Based on static code review:
- `set -euo pipefail` is declared at line 26
- All pipeline operations that could fail under `-e` are correctly guarded (`|| rc=$?`, `|| true` not used for rc-capturing paths)
- No unguarded bare `!` negations that would interact badly with `set -e`

**Status: SKIP** — requires `bash -n rebuild.sh` to confirm zero syntax errors; recommend operator runs this before first use.

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| NET-01 | 03-01-PLAN.md | Zero direct internet egress (deny-all) | VERIFIED (static) + UNCERTAIN (runtime) | `run_egress_smoke_test` with two targets is the runtime proof; logic correct statically; live result needs operator confirmation |
| NET-02 | 03-02-PLAN.md | Inference brokered through inference.local gateway | VERIFIED (static) + UNCERTAIN (runtime) | `run_inference_round_trip` (non-fatal) + README operator checklist with >=2 interactive round-trips; `ANTHROPIC_BASE_URL=https://inference.local` already baked in Dockerfile (Phase 2); live gateway result needs operator confirmation |
| NET-03 | 03-01-PLAN.md, 03-02-PLAN.md | Credentials injected via provider mechanism, never baked into image | VERIFIED | `check_inference_provider` is assert-only (never creates provider); README "One-time inference provider setup" documents host-side `--from-existing` path; rebuild.sh contains no credential values; `x-api-key: placeholder` is intentional non-credential |
| NET-04 | 03-01-PLAN.md | Rebuild script asserts no direct Anthropic endpoint in live policy | VERIFIED (static) + UNCERTAIN (runtime) | `assert_no_anthropic_egress` correctly queries live sandbox and uses inverted `jq -e`; runtime result depends on live `openshell policy get` |
| NET-05 | 03-01-PLAN.md | Egress smoke test from inside sandbox fails before handing to operator | VERIFIED (static) + UNCERTAIN (runtime) | `run_egress_smoke_test` logic correct; PASS condition is curl exit != 0; tests two targets; runtime result needs live sandbox |

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| rebuild.sh | 135 | `x-api-key: placeholder` | INFO | Intentional design (T-03-08): gateway injects real credential; placeholder is never a real key. Not a stub. |

No blockers found. No TBD/FIXME/XXX debt markers in `rebuild.sh` or `README.md`.

---

### Human Verification Required

#### 1. NET-05 Egress Smoke Test — Runtime Confirmation

**Test:** Run `./rebuild.sh` on a host with the sandbox correctly built and inference provider configured. Observe Step 6 output.
**Expected:** Both `https://api.anthropic.com` and `https://example.com` are blocked; rebuild.sh logs `NET-05 PASS: ... blocked (curl exit 56)` (or other non-zero) for each target and does not exit 1 from Step 6. Summary banner shows `NET-05: PASS`.
**Why human:** Requires a live running OpenShell sandbox with the zero-egress policy enforced. The static gate logic is correct, but the actual enforcement depends on the OpenShell proxy (10.200.0.1:3128) being active — confirming this is a runtime observation.

#### 2. Inference Round-Trip — D-06 PASS and Multi-Turn Interactive Session

**Test:** After `./rebuild.sh` completes with all gates passing, check the summary banner for `Round-trip: PASS`. Then: `openshell sandbox connect claude-sandbox`, run `claude --dangerously-skip-permissions`, send >=2 messages and confirm model responses.
**Expected:** Summary banner shows `Round-trip: PASS`; interactive session delivers >=2 model responses routed through `inference.local` with no direct Anthropic egress.
**Why human:** The D-06 round-trip is non-fatal and its PASS/WARN outcome cannot be determined without a live gateway. The interactive multi-turn session (roadmap criterion #2) explicitly cannot be scripted (D-07 decision).

#### 3. Provider Preflight Fail-Closed Path

**Test:** On a host with no inference provider registered (or temporarily remove it), run `./rebuild.sh` and observe the output.
**Expected:** Script exits 1 after logging `ERROR: Inference provider is not configured...` with the two operator commands, before any `=== [ts] Step 1 ===` banner appears. No ~290s hang.
**Why human:** Requires either a clean host or temporarily unregistering the provider to exercise the fail-closed path.

#### 4. NET-04 Live Policy Assertion — PASS Confirmation

**Test:** After sandbox create, observe Step 5 output in `./rebuild.sh`.
**Expected:** `NET-04 PASS: No direct Anthropic endpoints in effective policy` logged; rebuild continues to Step 6.
**Why human:** Requires a live `openshell policy get <sandbox-name> --full -o json` response to validate the actual policy JSON structure returned by the OpenShell CLI for a deny-all sandbox.

---

### Gaps Summary

No gaps. All static-verifiable must-haves are VERIFIED. The phase's four success criteria are correctly implemented in code. The four human verification items above are runtime confirmations that cannot be collapsed into static analysis — they represent the nature of the phase deliverable (shell gates that orchestrate live OpenShell CLI calls).

Status is `human_needed` (not `gaps_found`) because the logic, wiring, and gate semantics are all correctly implemented; what remains is operator execution to confirm the live runtime behaves as designed.

---

_Verified: 2026-06-16_
_Verifier: Claude (gsd-verifier)_
