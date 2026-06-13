---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
status: Ready to execute
last_updated: "2026-06-13T22:43:17.492Z"
progress:
  total_phases: 4
  completed_phases: 0
  total_plans: 0
  completed_plans: 0
  percent: 0
---

# Project State: Claude Sandbox (Fedora 44 / OpenShell)

---

## Project Reference

**Core Value**: Claude can run fully autonomous (`--dangerously-skip-permissions`) inside a sandbox that has zero direct network egress — all model inference is brokered through the OpenShell gateway — so elevated permissions can't be used to reach or exfiltrate to the open internet.

**Current Focus**: Phase 1 — Dockerfile and Supply-Chain Pinning

---

## Current Position

**Phase**: 1 — Dockerfile and Supply-Chain Pinning
**Plan**: None started
**Status**: Not started

**Overall Progress**:

```
[Phase 1] [Phase 2] [Phase 3] [Phase 4]
[  ....  ] [  ....  ] [  ....  ] [  ....  ]
  0%          0%          0%          0%
```

**Phase Progress**: 0 of 4 phases complete

---

## Performance Metrics

**Plans executed**: 0
**Plans succeeded first try**: 0
**Repair cycles used**: 0
**Phases complete**: 0 / 4

---

## Accumulated Context

### Key Decisions Made

| Decision | Phase | Rationale |
|----------|-------|-----------|
| 4 phases at coarse granularity | Roadmap | Research's suggested 4-phase structure maps cleanly to the 4 requirement clusters; phases have distinct failure modes worth isolating |
| RUN-03/RUN-04 (bind mount) in Phase 2 | Roadmap | Bind mount is configured at `openshell sandbox create` time, not at Claude launch time — belongs with lifecycle, not Claude config |
| RUN-01/RUN-02 (Claude launch flags) in Phase 4 | Roadmap | MCP audit only meaningful after zero-egress confirmed (Phase 3); blocked plugins look like policy failures otherwise |

### Open Questions / Risks

- **BLD-06 (podman → OpenShell image handoff)**: How OpenShell resolves a podman-built image across separate image stores is an open research item. Must be confirmed empirically in Phase 2.
- **NET-03 exact provider flags**: Exact `openshell provider create ... --from-existing` and `openshell inference set` invocations to be confirmed during Phase 3 execution.
- **OpenShell issue #759 (290s hang)**: Root cause unknown. Preflight check mitigates but may still affect interactive sessions.
- **`--userns=keep-id` support in OpenShell `sandbox create`**: Whether OpenShell exposes this Podman flag is unconfirmed. Fallback: run container as UID 0.
- **claude-engineering-toolkit MCP network calls**: Fork not yet audited for outbound HTTP at agent load time or tool invocation. Audit is the primary task of Phase 4.

### Implementation Notes

*(Populated during execution)*

### Blockers

*(None — starting fresh)*

---

## Session Continuity

**Last updated**: 2026-06-13 (roadmap created)
**Last action**: Roadmap and STATE.md written; REQUIREMENTS.md traceability updated
**Next action**: Begin Phase 1 planning with `/gsd-plan-phase 1`

---
*State initialized: 2026-06-13*
