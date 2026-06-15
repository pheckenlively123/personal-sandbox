---
phase: 02-rebuild-script-and-sandbox-lifecycle
plan: 01
subsystem: infra
tags: [dockerfile, podman, bash, image-labeling, supply-chain, build-args]

# Dependency graph
requires:
  - phase: 01-dockerfile-and-supply-chain-pinning
    provides: Dockerfile with four ARG-pinned supply-chain versions and build-and-lock.sh resolve+build+lock loop
provides:
  - ARG BUILD_DATE + five ARG-fed LABEL lines in Dockerfile (cooldown.date, build.date, govulncheck.version, gsd.core.version, claude.code.version)
  - build-and-lock.sh --build-date flag with YYYY-MM-DD allowlist validation and fifth --build-arg BUILD_DATE passthrough
  - Date-tagged image (claude-sandbox:<YYYY-MM-DD>) with podman-inspectable provenance labels
affects: [02-02, rebuild.sh, phase-3-network-isolation]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "LABEL-via-ARG (D-04): provenance labels fed by build ARGs so they travel with the image regardless of build entry point"
    - "Allowlist-validate operator CLI args before use in subprocess invocations (T-02-01 injection mitigation)"

key-files:
  created: []
  modified:
    - Dockerfile
    - scripts/build-and-lock.sh

key-decisions:
  - "D-04 LABEL-via-ARG: five LABEL lines fed by ARGs (not --label flag) so provenance is baked into the image layer regardless of which script builds it"
  - "T-02-01 mitigation: BUILD_DATE allowlist-validated against ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ before podman build invocation; no eval"
  - "COOLDOWN_DATE remains first ARG (cache-bust anchor) — new ARG BUILD_DATE added after existing four to preserve cache ordering"

patterns-established:
  - "Pattern: LABEL-via-ARG for image provenance — use ARG declarations before LABEL so values are set at build time, not hardcoded"
  - "Pattern: validate operator-supplied date strings with allowlist regex before passing to subprocess (fail-closed, error to stderr)"

requirements-completed: [BLD-03]

# Metrics
duration: ~20min (across two executor sessions, paused at Task 3 human-verify checkpoint)
completed: 2026-06-15
---

# Phase 02 Plan 01: Image Provenance Slice Summary

**Dockerfile extended with ARG BUILD_DATE and five ARG-fed LABEL lines (D-04); build-and-lock.sh gains --build-date flag with YYYY-MM-DD validation; operator-confirmed podman inspect shows cooldown.date and build.date labels on the date-tagged image (BLD-03 verified)**

## Performance

- **Duration:** ~20 min (two executor sessions)
- **Started:** 2026-06-15T22:00:00Z
- **Completed:** 2026-06-15T22:30:00Z
- **Tasks:** 3 (2 auto + 1 human-verify checkpoint)
- **Files modified:** 2

## Accomplishments

- Dockerfile now declares `ARG BUILD_DATE` alongside the four existing supply-chain ARGs, and bakes five provenance labels into the image layer via the LABEL-via-ARG pattern (D-04)
- build-and-lock.sh accepts `--build-date YYYY-MM-DD` (both space and `=` forms), defaults to today, validates against a YYYY-MM-DD allowlist regex (T-02-01 injection mitigation), and passes `--build-arg BUILD_DATE=${BUILD_DATE}` as a fifth build-arg alongside the existing four
- Operator ran a live podman build and confirmed via `podman inspect` that the date-tagged image (`claude-sandbox:<date>`) carries both `cooldown.date` and `build.date` labels — satisfying BLD-03 / ROADMAP success criterion #2

## Task Commits

Each task was committed atomically:

1. **Task 1: Add ARG BUILD_DATE + five provenance LABEL lines to Dockerfile** - `387269c` (feat)
2. **Task 2: Add --build-date flag and BUILD_DATE passthrough to build-and-lock.sh** - `88c0bc2` (feat)
3. **Task 3: Human-verify cooldown/build-date label round-trip** - Verified by operator (no code commit — checkpoint gate); prior state commit: `77368af`

**Plan metadata:** (this SUMMARY commit)

## Files Created/Modified

- `Dockerfile` — Added `ARG BUILD_DATE` after existing four ARGs; added five LABEL lines (cooldown.date, build.date, govulncheck.version, gsd.core.version, claude.code.version) positioned after full ARG block and before first RUN, preserving COOLDOWN_DATE as first ARG (cache-bust anchor)
- `scripts/build-and-lock.sh` — Added `BUILD_DATE` default in Defaults block, `--build-date` case in arg-parse loop (both `--build-date VALUE` and `--build-date=VALUE` forms with empty-arg guard), YYYY-MM-DD allowlist validation after arg-parse, and `--build-arg "BUILD_DATE=${BUILD_DATE}"` in podman build invocation

## Decisions Made

- **LABEL-via-ARG (D-04):** Used `LABEL key="${ARG}"` form rather than `podman build --label` in the script. This bakes provenance into the image layer, making labels visible via `podman inspect` regardless of which build entry point was used.
- **T-02-01 injection mitigation:** `BUILD_DATE` is operator-supplied and flows into a `--build-arg`; allowlist-validated against `^[0-9]{4}-[0-9]{2}-[0-9]{2}$` immediately after arg-parse, before any podman invocation. No eval.
- **Cache ordering preserved:** `COOLDOWN_DATE` remains first ARG (cache-bust anchor per Pitfall 4 in PATTERNS.md); `BUILD_DATE` added fifth in the ARG block.

## Deviations from Plan

None — plan executed exactly as written. All three success criteria satisfied (two automated, one human-verified).

## Issues Encountered

None. The plan paused at the Task 3 human-verify checkpoint as designed. The operator ran the real podman build and confirmed the label round-trip, then approved to continue.

## Human-Verify Gate Record

**Task 3 checkpoint (gate="blocking"):** Operator ran `bash scripts/build-and-lock.sh --tag "claude-sandbox:${BUILD_DATE}" --build-date "${BUILD_DATE}"` and inspected the resulting image via `podman inspect`. Confirmed both `cooldown.date` and `build.date` labels present on the date-tagged image. Approved.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- BLD-03 satisfied: date-tagged image with podman-inspectable cooldown.date and build.date labels
- Plan 02 (rebuild.sh end-to-end slice) can proceed: it relies on `--build-date` flag existing in build-and-lock.sh and the five LABEL lines being in the Dockerfile
- Remaining Phase 2 requirements (BLD-01, BLD-02, BLD-04, BLD-05, BLD-06, RUN-03, RUN-04) are addressed by 02-02-PLAN.md

## Threat Flags

No new security-relevant surface introduced beyond the plan's threat model. T-02-01 (BUILD_DATE injection) was mitigated as planned. T-02-02 and T-02-03 accepted as planned.

---
*Phase: 02-rebuild-script-and-sandbox-lifecycle*
*Completed: 2026-06-15*
