---
phase: 03-network-isolation-and-inference-validation
plan: "01"
subsystem: rebuild-orchestrator
tags:
  - network-isolation
  - egress-gates
  - inference-preflight
  - security
dependency_graph:
  requires:
    - 02-02-SUMMARY.md
  provides:
    - check_inference_provider (Step 0 preflight)
    - assert_no_anthropic_egress (Step 5 NET-04 gate)
    - run_egress_smoke_test (Step 6 NET-05 gate)
  affects:
    - rebuild.sh (extended with 3 new functions and 2 new step banners)
tech_stack:
  added: []
  patterns:
    - ANSI-strip-before-grep (openshell inference get output)
    - inverted-jq-e-assertion (network_policies absence check)
    - sandbox-exec-stderr-suppress (2>/dev/null for .bash_profile noise)
    - fail-closed-gate-chain (exit 1 on any violation before summary banner)
key_files:
  created: []
  modified:
    - rebuild.sh
decisions:
  - "check_inference_provider detects unconfigured provider via ANSI-stripped output grep (not exit code — which is 0 in both states per Pitfall 1)"
  - "assert_no_anthropic_egress uses inverted jq -e sense: match found = VIOLATION (exit 0 from jq), no match = PASS; // {} guard handles absent network_policies key"
  - "run_egress_smoke_test tests two independent targets (api.anthropic.com + example.com) to prove deny-all, not just an Anthropic-specific block (T-03-02)"
  - "All openshell sandbox exec calls redirect stderr 2>/dev/null to suppress non-fatal .bash_profile Permission denied noise"
metrics:
  duration: "3 minutes"
  completed_date: "2026-06-16"
  tasks_completed: 2
  files_modified: 1
---

# Phase 03 Plan 01: Egress Isolation Gates Summary

Three fail-closed network-isolation gates added to rebuild.sh: provider preflight (Step 0), NET-04 live policy assertion (Step 5), and NET-05 blocking two-target egress smoke test (Step 6).

## What Was Built

Extended `rebuild.sh` with three new bash functions and their call sites, making the zero-egress guarantee provable on every rebuild:

1. **`check_inference_provider`** (Step 0 / D-03, NET-03): Runs `openshell inference get`, strips ANSI escapes via sed, greps for "Not configured". Exits 1 with actionable operator guidance (provider create + inference set commands) if unconfigured. Call site: immediately after the tools-on-PATH preflight, before BUILD_DATE computation. Prevents the OpenShell #759 ~290s hang.

2. **`assert_no_anthropic_egress`** (Step 5 / D-02, NET-04): Queries the live sandbox policy via `openshell policy get --full -o json`, then uses `jq -e` with inverted sense — exit 0 from jq means a matching Anthropic endpoint was found (VIOLATION); non-zero means no match (PASS). The `// {}` guard handles the correct deny-all state where `network_policies` is absent from the JSON entirely.

3. **`run_egress_smoke_test`** (Step 6 / D-05, NET-05): Iterates over two independent targets (`https://api.anthropic.com` and `https://example.com`). For each, runs curl with `--max-time 8` from inside the sandbox via `openshell sandbox exec --no-tty`. PASS condition is curl exit != 0 (proxy blocked it). Any exit 0 (connection succeeded) triggers `log_error` + `exit 1`. All exec invocations carry `2>/dev/null` to suppress the non-fatal `.bash_profile: Permission denied` noise.

## Acceptance Criteria Status

| Criterion | Status |
|-----------|--------|
| `bash -n rebuild.sh` exits 0 | PASS |
| `check_inference_provider` count == 2 (def + call) | PASS |
| ANSI strip sed expression present | PASS |
| `Not configured` grep (not exit-code branch) | PASS |
| Call site placement: Preflight passed < check_inference_provider < log_step 1 | PASS |
| `exit 1` on Not configured path | PASS |
| `assert_no_anthropic_egress` count == 2 (def + call) | PASS |
| `run_egress_smoke_test` count == 2 (def + call) | PASS |
| `log_step 5` and `log_step 6` present | PASS |
| `network_policies // {}` guard in jq expression | PASS |
| Two targets: api.anthropic.com + example.com | PASS |
| `rc -eq 0` branch triggers `exit 1` (VIOLATION) | PASS |
| All `openshell sandbox exec` lines have `2>/dev/null` | PASS |
| Steps 5 + 6 after Ready check, before summary banner | PASS |
| No `policy update --add-endpoint` anywhere in rebuild.sh | PASS |

## Deviations from Plan

None — plan executed exactly as written. The only non-mechanical choice was restructuring the `openshell sandbox exec` call in `run_egress_smoke_test` to single-line form (matching the PATTERNS.md reference implementation) so the `2>/dev/null` redirect is on the same line as the `sandbox exec` invocation, satisfying the acceptance criterion literally.

## Threat Surface Scan

No new network endpoints, auth paths, file access patterns, or schema changes introduced. All new code is read-only inspection of `openshell` CLI output and fail-closed gate logic. No new external packages. Threat model in PLAN.md covers all new code paths (T-03-01 through T-03-06, T-03-SC).

## Known Stubs

None. All three functions are fully wired to their call sites and produce concrete PASS/VIOLATION output on every rebuild.

## Self-Check: PASSED

- `rebuild.sh` exists and was modified: confirmed (git diff shows +84 lines)
- Task 1 commit 40f4640 exists: confirmed
- Task 2 commit 34ea703 exists: confirmed
- `bash -n rebuild.sh` exits 0: confirmed
- Three functions defined and called (count == 2 each): confirmed
