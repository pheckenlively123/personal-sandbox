---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
status: Ready to execute
last_updated: "2026-06-15T22:15:36.488Z"
progress:
  total_phases: 4
  completed_phases: 1
  total_plans: 5
  completed_plans: 4
  percent: 25
---

# Project State: Claude Sandbox (Fedora 44 / OpenShell)

---

## Project Reference

**Core Value**: Claude can run fully autonomous (`--dangerously-skip-permissions`) inside a sandbox that has zero direct network egress — all model inference is brokered through the OpenShell gateway — so elevated permissions can't be used to reach or exfiltrate to the open internet.

**Current Focus**: Phase 2 — Rebuild Script and Sandbox Lifecycle

---

## Current Position

Phase: 02 (rebuild-script-and-sandbox-lifecycle) — EXECUTING
Plan: 2 of 2
**Phase**: 2 — Rebuild Script and Sandbox Lifecycle
**Plan**: 02-02 — Ready to execute
**Status**: 02-01 complete (BLD-03 satisfied); ready to start 02-02 (rebuild.sh end-to-end slice)

**Overall Progress**:

```
[Phase 1] [Phase 2] [Phase 3] [Phase 4]
[ DONE ✓ ] [  ....  ] [  ....  ] [  ....  ]
  100%        0%          0%          0%
```

**Phase Progress**: 1 of 4 phases complete (25%)

---

## Performance Metrics

**Plans executed**: 3
**Plans succeeded first try**: 3
**Repair cycles used**: 0
**Phases complete**: 1 / 4

---

## Accumulated Context

### Key Decisions Made

| Decision | Phase | Rationale |
|----------|-------|-----------|
| 4 phases at coarse granularity | Roadmap | Research's suggested 4-phase structure maps cleanly to the 4 requirement clusters; phases have distinct failure modes worth isolating |
| RUN-03/RUN-04 (bind mount) in Phase 2 | Roadmap | Bind mount is configured at `openshell sandbox create` time, not at Claude launch time — belongs with lifecycle, not Claude config |
| RUN-01/RUN-02 (Claude launch flags) in Phase 4 | Roadmap | MCP audit only meaningful after zero-egress confirmed (Phase 3); blocked plugins look like policy failures otherwise |
| Phase 01 P01 | 427 | 3 tasks | 5 files |
| Phase 01 P02 | 254 | 2 tasks | 4 files |
| Phase 01-dockerfile-and-supply-chain-pinning P03 | 7min | 2 tasks | 5 files |
| Phase 02 P01 | 20min | 3 tasks | 2 files |

### Open Questions / Risks

- **BLD-06 (podman → OpenShell image handoff)**: How OpenShell resolves a podman-built image across separate image stores is an open research item. Must be confirmed empirically in Phase 2.
- **NET-03 exact provider flags**: Exact `openshell provider create ... --from-existing` and `openshell inference set` invocations to be confirmed during Phase 3 execution.
- **OpenShell issue #759 (290s hang)**: Root cause unknown. Preflight check mitigates but may still affect interactive sessions.
- **`--userns=keep-id` support in OpenShell `sandbox create`**: Whether OpenShell exposes this Podman flag is unconfirmed. Fallback: run container as UID 0.
- **claude-engineering-toolkit MCP network calls**: Fork not yet audited for outbound HTTP at agent load time or tool invocation. Audit is the primary task of Phase 4.

### Implementation Notes

*(Populated during execution)*

### Blockers

*(None — Phase 1 shipped clean; the jq-missing build blocker was fixed and re-verified)*

---

## Session Continuity

**Last updated**: 2026-06-15 (Phase 2, Plan 1 complete — BLD-03 satisfied)
**Last action**: 02-01-SUMMARY.md committed (574c97a) — plan 01 fully complete; operator verified cooldown.date + build.date labels via podman inspect
**Next action**: Execute 02-02-PLAN.md (rebuild.sh end-to-end slice)
**Stopped at**: Completed 02-01-PLAN.md
**Resume file**: None

---
*State initialized: 2026-06-13*

## Decisions

- [Phase ?]: re-query not cached dates
- [Phase ?]: associative array cache
- [Phase ?]: CUTOFF_EXCL exclusive next-day-midnight bound replaces T23:59:59Z for all publish-date comparisons in verifier and resolver (CR-01 fix)
- [Phase 02]: ARG BUILD_DATE + five LABEL lines added to Dockerfile via D-04 pattern (LABEL-via-ARG for portability — provenance travels with image regardless of build entry point)
- [Phase 02]: build-and-lock.sh --build-date flag added with T-02-01 YYYY-MM-DD allowlist validation before podman build invocation
- [Phase ?]: [Phase 02]: T-02-01 mitigation — BUILD_DATE allowlist-validated against YYYY-MM-DD regex before podman build invocation; no eval
