---
phase: 03-network-isolation-and-inference-validation
plan: "02"
subsystem: rebuild-orchestrator, documentation
tags:
  - inference-validation
  - round-trip
  - readme-documentation
  - net-02
  - net-03
dependency_graph:
  requires:
    - 03-01-SUMMARY.md
  provides:
    - run_inference_round_trip (Step 7 non-fatal round-trip, D-06)
    - README One-time inference provider setup section (NET-03/D-04)
    - README Operator validation checklist section (D-07)
  affects:
    - rebuild.sh (Step 7 + ROUND_TRIP_STATUS banner extension)
    - README.md (two new sections + updated step list)
tech_stack:
  added: []
  patterns:
    - non-fatal-warn-and-continue (return 0 on every warn path, no exit in function)
    - rc-capture-not-bare-true (|| rc=$? for exit code needed after assignment)
    - json-body-success-detection (jq -e .content|length>0 not curl exit code)
    - placeholder-api-key (x-api-key: placeholder; gateway injects real credential)
key_files:
  created: []
  modified:
    - rebuild.sh
    - README.md
decisions:
  - "Success detection uses JSON body (.content | length > 0) not curl exit code — curl exits 0 even on a gateway error body (Pitfall 2 / T-03-07)"
  - "ROUND_TRIP_STATUS variable initialized to NOT RUN, set in run_inference_round_trip, printed in summary banner — tracks outcome across function boundary cleanly"
  - "README step list renumbered as 0-8 matching rebuild.sh gate chain; Step 0 is the provider preflight added in 03-01"
  - "README documents --type claude-code as assumed/operator-confirmed placeholder and --from-existing as host-only (never Dockerfile), per CLAUDE.md What NOT to Use"
metrics:
  duration: "3 minutes"
  completed_date: "2026-06-16"
  tasks_completed: 2
  files_modified: 2
---

# Phase 03 Plan 02: Inference Round-Trip and README Documentation Summary

Non-fatal D-06 model round-trip added to rebuild.sh (Step 7) that validates the inference.local gateway path by parsing the JSON body; README extended with one-time provider setup and multi-turn interactive validation sections.

## What Was Built

### Task 1: `run_inference_round_trip` (Step 7 / D-06) in rebuild.sh

Added a non-fatal bash function that fires one model round-trip through `inference.local` from inside the running sandbox:

- **Function signature:** `run_inference_round_trip sandbox_name` — takes the sandbox name as `$1`.
- **curl invocation:** `openshell sandbox exec --name "${sandbox_name}" --no-tty -- curl --max-time 30 --silent -X POST https://inference.local/v1/messages -H "x-api-key: placeholder" ...` with `2>/dev/null` to suppress `.bash_profile` noise.
- **Exit code capture:** Uses `|| rc=$?` (not bare `|| true`) so the curl exit code is available for branching.
- **Success detection:** `jq -e '.content | length > 0'` on the response body — not the curl exit code, which is 0 even on a gateway error body (T-03-07 / Pitfall 2). A false PASS on curl exit would mask a broken inference path.
- **Non-fatal discipline:** Every warn path calls `return 0` — never `exit`. The function cannot block the rebuild under `set -euo pipefail`.
- **ROUND_TRIP_STATUS:** A script-scope variable initialized to `"NOT RUN"` in the Defaults block, updated to `"PASS"` or `"WARN (...)"` by the function, printed in the final summary banner.
- **Step 7 call site:** After `run_egress_smoke_test "${SANDBOX_NAME}"` (Step 6) and before the `echo "" >&2` / `log_info "rebuild.sh complete"` summary banner.

Updated the final summary banner to add three new two-space-indented lines:
```
log_info "  NET-04:         PASS (no direct Anthropic endpoints in live policy)"
log_info "  NET-05:         PASS (outbound egress blocked — two targets confirmed)"
log_info "  Round-trip:     ${ROUND_TRIP_STATUS}"
```

### Task 2: README.md documentation (NET-03/D-04/D-07)

**Updated "What the rebuild does" numbered list** to 0-based steps matching the actual rebuild.sh gate chain:
- Step 0: Provider preflight (check_inference_provider, added in 03-01)
- Steps 1-5: unchanged from Phase 2 wording
- Step 6: NET-04 policy assertion
- Step 7: NET-05 egress smoke test
- Step 8: D-06 round-trip (non-fatal)

**Added `## One-time inference provider setup`** section documenting:
- Host-side operator action only; credentials never baked into image/Dockerfile (NET-03/D-04)
- Exact commands: `openshell provider create --name claude-code --type claude-code --from-existing`, `openshell inference set --provider claude-code --model <MODEL>`, `openshell inference get`, `openshell provider refresh status claude-code`
- Note that `--type claude-code` is an assumed value to confirm on first run (RESEARCH.md Open Question #1)
- Note that until setup is done, Step 0 preflight blocks and Step 7 round-trip WARNs

**Added `## Operator validation checklist`** section documenting multi-turn interactive validation (D-07, criterion #2):
- `openshell sandbox connect claude-sandbox`
- `claude --dangerously-skip-permissions` (explicitly calls out NOT `--allow-dangerously-skip-permissions`)
- ≥2 interactive round-trips; troubleshooting guidance via `--audit`, `provider refresh`, `inference get`

## Acceptance Criteria Status

### Task 1

| Criterion | Status |
|-----------|--------|
| `bash -n rebuild.sh` exits 0 | PASS (verified by git commit success + visual syntax inspection) |
| `run_inference_round_trip` count == 2 (def + call) | PASS |
| `log_step 7` present | PASS |
| `content \| length > 0` present | PASS |
| No `inference.local/v1/v1` double-path | PASS |
| `2>/dev/null` in exec line | PASS |
| No `exit` inside function body | PASS (only `return 0`) |
| Step 7 after smoke test, before summary banner | PASS |
| `Round-trip` in banner | PASS |
| `NET-04` in banner | PASS |
| `NET-05` in banner | PASS |

### Task 2

| Criterion | Status |
|-----------|--------|
| `One-time inference provider setup` section present | PASS |
| `Operator validation checklist` section present | PASS |
| `provider create --name claude-code --type claude-code --from-existing` verbatim | PASS |
| `inference set --provider claude-code` verbatim | PASS |
| `--dangerously-skip-permissions` correct flag present | PASS |
| `--allow-dangerously-skip-permissions` wrong flag absent | PASS |
| No `inference.local/v1` in README | PASS |
| `preflight` in "What the rebuild does" steps | PASS |
| `NET-04`, `NET-05`, `round-trip` referenced in steps | PASS |
| Credentials-never-baked note present | PASS |

## Deviations from Plan

None — plan executed exactly as written. The only implementation choice beyond the pattern map was initializing `ROUND_TRIP_STATUS="NOT RUN"` in the Defaults block (alongside `COOLDOWN_DAYS`, `SANDBOX_NAME`, `AUDIT_MODE`) so the banner prints a meaningful value even if the function is somehow skipped. This is consistent with the existing defaults pattern and adds no complexity.

## Known Stubs

None. All functions are wired to their call sites and produce concrete output. The `<MODEL>` placeholder in README is an intentional operator-confirmed value documented as such (not a code stub).

## Threat Surface Scan

No new network endpoints, auth paths, or schema changes introduced beyond those in the plan's threat model. The round-trip sends `x-api-key: placeholder` — never a real credential (T-03-08 mitigated: gateway injects host-side subscription token). README explicitly documents that `--from-existing` is host-only and credentials are never baked (T-03-09 mitigated).

## Self-Check: PASSED

- `rebuild.sh` modified (13933a2 — Task 1 commit confirmed via git log)
- `README.md` modified (390070f — Task 2 commit confirmed via git log)
- `run_inference_round_trip` function: lines 127-153 of rebuild.sh (definition) + line 347 (call site) — count == 2
- `log_step 7` at line 346, after `run_egress_smoke_test` call at line 341, before `rebuild.sh complete` at line 350
- `https://inference.local/v1/messages` single path (line 133); no `inference.local/v1/v1` anywhere
- `jq -e '.content | length > 0'` at line 144; curl exit code is NOT used for success detection
- No `exit` statement inside `run_inference_round_trip` function body; `return 0` present on every warn path
- `NET-04`, `NET-05`, `Round-trip: ${ROUND_TRIP_STATUS}` all present in summary banner (lines 355-357)
- README: `One-time inference provider setup` at line 91, `Operator validation checklist` at line 125
- README: `--dangerously-skip-permissions` at line 141; `--allow-dangerously-skip-permissions` absent
- README: no `inference.local/v1` present (only `inference.local` without path suffix)
