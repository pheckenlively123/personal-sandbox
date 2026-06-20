---
phase: 04-claude-code-launch-and-mcp-audit
plan: "02"
subsystem: sandbox-launch-and-doc-reconciliation
tags:
  - claude-launch
  - rebuild-sh
  - architecture-b
  - doc-reconciliation
  - autonomous-mode
dependency_graph:
  requires:
    - 04-01-SUMMARY.md
  provides:
    - ./rebuild.sh claude verb (D-01, RUN-01)
    - --dangerously-skip-permissions + --plugin-dir launch via exec --tty --workdir (RUN-02)
    - D-02: no OAuth precondition check in claude verb
    - D-13: ROADMAP/REQUIREMENTS/PROJECT.md reconciled to Architecture B
  affects:
    - rebuild.sh (claude verb added to whitelist + dispatch + usage/help)
    - .planning/ROADMAP.md (Phase 4 criterion #3, Phase 3 goal/criteria)
    - .planning/REQUIREMENTS.md (Core Value line, NET-01..05 notes)
    - .planning/PROJECT.md (Core Value, Key Decisions)
tech_stack:
  added: []
  patterns:
    - verb-first-rebuild-sh (case-dispatch pattern: whitelist → dispatch → usage — mirrors connect/login)
    - exec-tty-workdir-claudeshared (openshell sandbox exec --tty --workdir /claudeshared — canonical launch path)
    - doc-truth-correction-surgical (copy phrasing from authoritative source CLAUDE.md, no wholesale rewrites)
key_files:
  created: []
  modified:
    - rebuild.sh
    - .planning/ROADMAP.md
    - .planning/REQUIREMENTS.md
    - .planning/PROJECT.md
decisions:
  - "D-01 resolved: claude verb ships in rebuild.sh reusing the connect/login exec --tty --workdir pattern; no separate mechanism needed"
  - "D-02 resolved: no OAuth precondition check in claude verb — claude handles the unauthenticated case itself; verb just informs operator of prerequisite"
  - "D-13 resolved: ROADMAP/REQUIREMENTS/PROJECT.md reconciled to Architecture B wording; inference.local/gateway/zero-egress references removed; 3-host allowlist language from CLAUDE.md used"
metrics:
  duration: "~20 minutes (Tasks 1+2 auto; Task 3 human-verify approved by operator)"
  completed_date: "2026-06-19"
  tasks_completed: 3
  files_modified: 4
---

# Phase 04 Plan 02: `claude` Launch Verb + Architecture B Doc Reconciliation Summary

Shipped `./rebuild.sh claude` as the first-class autonomous launch path (RUN-01/RUN-02) and reconciled ROADMAP/REQUIREMENTS/PROJECT.md to Architecture B (D-13); live verification confirmed Skills(6)/Agents(11) loaded and the verb launches cleanly (criterion #1).

## What Was Built

### Task 1: `claude` verb added to rebuild.sh (commit `8a9b787`)

The `claude` verb was added to rebuild.sh at three sites to match the existing verb-first dispatch pattern:

1. **Verb whitelist (`case "$1"`)**:  `claude` added alongside `rebuild|status|connect|login|down|audit` so the verb-first parser accepts it (without this, the script exits with "Unknown verb").

2. **Dispatch block (`case "${VERB}")****: A `claude)` branch placed after `login)` and before `down)`. The branch:
   - Calls `ensure_podman_ready`
   - Emits `log_info` lines stating the launch target, plugin dir (`/opt/claude-engineering-toolkit`), and prerequisite note (sandbox created + `./rebuild.sh login` done — no OAuth check per D-02)
   - Execs: `openshell sandbox exec --name "${SANDBOX_NAME}" --tty --workdir "${SHARED_DIR}" -- claude --dangerously-skip-permissions --plugin-dir /opt/claude-engineering-toolkit`
   - `exit 0` on success

3. **All three usage/help strings**: `claude` listed with a one-line description; header comment block updated.

Flags used are the correct forms per CLAUDE.md (`--dangerously-skip-permissions` not `--allow-dangerously-skip-permissions`; `--plugin-dir` not `--plugin-url`). No user-supplied arguments pass through to claude (V5/T-04-06 mitigated). `bash -n rebuild.sh` passes.

### Task 2: Architecture B doc reconciliation (commit `de07d92`)

Surgical, copy-from-CLAUDE.md edits to three planning docs — no requirement IDs added/removed, no checkbox state changes:

**PROJECT.md**: Core Value rewritten from the stale "zero direct network egress — brokered through OpenShell gateway" framing to Architecture B: Claude runs in-sandbox, authenticates via subscription OAuth, reaches a 3-host TLS-passthrough allowlist (api.anthropic.com / platform.claude.com / claude.ai) binary-scoped to claude. Key Decisions rows updated to reflect in-sandbox OAuth + direct-allowlist model (removed gateway / `--from-existing` provider / inference.local / ANTHROPIC_API_KEY placeholder references).

**REQUIREMENTS.md**: Core Value line updated to Architecture B. Each of NET-01 through NET-05 received a `(superseded by Architecture B — see CLAUDE.md)` note or wording correction: NET-04 inverted from "ASSERT absent" to "ASSERT api.anthropic.com IS present"; NET-05 narrowed to deny posture for non-allowlisted hosts only.

**ROADMAP.md**: Phase 4 criterion #3 changed from "zero-egress sandbox" to "3-host-allowlist sandbox" with a parenthetical clarifying the criterion. Phase 3 goal/criteria gateway/inference.local wording reconciled to the direct 3-host allowlist. Architecture B note added to Phase 4 details.

### Task 3: Live verification (checkpoint:human-verify, APPROVED)

Operator performed two verification steps:

**Headless precheck (criterion #1 — agents/skills loaded):**
```
openshell sandbox exec --name claude-sandbox --no-tty -- claude --plugin-dir /opt/claude-engineering-toolkit plugin details claude-engineering-toolkit
```
Result: Skills (6) + Agents (11) — both counts > 0. Confirmed the `--plugin-dir` flag in the verb's exec is correct.

**Interactive launch via the new verb:**
```
./rebuild.sh claude
```
Result: Interactive autonomous session started with no startup errors; `--dangerously-skip-permissions` active (no per-action permission prompts); toolkit agents/skills available in session. Operator confirmed clean launch and exited with `/exit`.

**Criterion #1 SATISFIED**: `claude --dangerously-skip-permissions --plugin-dir /opt/claude-engineering-toolkit` launches inside the sandbox without errors and reports toolkit agents/skills as loaded.

## Acceptance Criteria Status

| Criterion | Status |
|-----------|--------|
| `./rebuild.sh claude` recognized by verb whitelist | PASS |
| Claude verb execs `--dangerously-skip-permissions --plugin-dir /opt/claude-engineering-toolkit` | PASS |
| Exec uses `--tty --workdir /claudeshared` pattern (D-01) | PASS |
| No OAuth precondition check in verb (D-02) | PASS |
| `bash -n rebuild.sh` passes | PASS |
| Usage/help strings updated | PASS |
| `inference.local` absent from ROADMAP/REQUIREMENTS/PROJECT.md | PASS |
| "Architecture B" / "3-host" wording present | PASS |
| Requirement IDs and checkbox states unchanged | PASS |
| Skills(6)/Agents(11) confirmed via headless precheck | PASS (live) |
| `./rebuild.sh claude` launches cleanly — criterion #1 satisfied | PASS (live — operator approved) |

## Deviations from Plan

None — plan executed exactly as written. All decisions (D-01, D-02, D-13) resolved as specified; live verification passed at the checkpoint.

## Threat Surface Scan

No new network endpoints introduced. The `claude` verb bridges the operator shell to an in-sandbox exec — this is the same trust boundary as `connect` and `login` (already modeled). New surface relative to this plan:

- `rebuild.sh claude` now execs `claude --dangerously-skip-permissions` (T-04-04: accepted — locked Architecture B trade-off; autonomy contained by sandbox + 3-host binary-scoped egress; sandbox deleted between sessions)
- Subscription OAuth token at `~/.claude/.credentials.json` accessible to autonomous claude (T-04-05: accepted — egress binary-scoped to claude, limited to 3 Claude auth/API hosts, TLS passthrough)
- Verb argument injection (T-04-06: mitigated — verb accepts no user arguments; case dispatch only; flags are literals; no eval)

All surface covered by the PLAN.md threat register (T-04-04 through T-04-06). No surface beyond what the plan modeled.

## Known Stubs

None. The `claude` verb is fully wired and verified live. Doc reconciliation is complete — no placeholders remain.

## Self-Check: PASSED

- Task 1 commit `8a9b787` exists: confirmed via `git log`
- Task 2 commit `de07d92` exists: confirmed via `git log`
- Task 3: operator-approved human-verify checkpoint with live evidence (Skills 6 / Agents 11; `./rebuild.sh claude` launched cleanly)
- `rebuild.sh` contains `claude --dangerously-skip-permissions --plugin-dir /opt/claude-engineering-toolkit`: confirmed (Task 1)
- ROADMAP.md contains "3-host" and no `inference.local`: confirmed (Task 2)
- PROJECT.md contains "Architecture B": confirmed (Task 2)
- Criterion #1 satisfied: live evidence confirms toolkit agents/skills loaded
