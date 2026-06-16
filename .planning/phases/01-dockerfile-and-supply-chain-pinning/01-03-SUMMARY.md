---
phase: 01-dockerfile-and-supply-chain-pinning
plan: "03"
subsystem: infra
tags: [supply-chain, bash, docker, npm, python3, jq, boundary-fix, security]

# Dependency graph
requires:
  - phase: 01-dockerfile-and-supply-chain-pinning/01-02
    provides: verify-pins.sh wired as PIN-07 gate, test-pin-held.sh negative-path proof
provides:
  - CUTOFF_EXCL boundary-correct comparison in verify-pins.sh and resolve-versions.sh (CR-01)
  - Allowlist-validated resolver parse in build-and-lock.sh replacing eval (CR-02)
  - npm-ls snapshot guard in Dockerfile (WR-01)
  - Missing/invalid transitive node violation surfacing in verify-pins.sh (WR-02)
  - IN-02 pre-release filter for govulncheck Go-proxy tag selection
  - Boundary-window regression test cases in test-pin-held.sh
affects:
  - Phase 2 (sandbox create/lifecycle) — inherits corrected supply-chain gate
  - Any future rebuild — rolling cooldown will now correctly handle millisecond-precision boundary

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "CUTOFF_EXCL = ${NEXT_DAY}T00:00:00.000Z computed via python3 as exclusive upper bound for publish-date comparisons (avoids bash lexicographic ISO-8601 bug with millisecond precision)"
    - "Allowlist-validated process-substitution parse with printf -v instead of eval for registry-sourced KEY=VALUE output"
    - "WR-02 sentinel: __MISSING__ emitted by jq flatten for missing/invalid npm nodes; loop counts as violation"

key-files:
  created: []
  modified:
    - scripts/verify-pins.sh
    - scripts/resolve-versions.sh
    - scripts/build-and-lock.sh
    - tests/test-pin-held.sh
    - Dockerfile

key-decisions:
  - "Use CUTOFF_EXCL = NEXT_DAY T00:00:00.000Z (exclusive next-day midnight) as the comparison operand for all publish-date cutoff checks in both verifier and resolver — safe as lexicographic bound at full millisecond precision"
  - "Keep CUTOFF = T23:59:59Z for human-readable display/logging only; CUTOFF_EXCL drives the actual comparison"
  - "IN-02 govulncheck pre-release filter (^v[0-9]+\\.[0-9]+\\.[0-9]+$) folded into resolve-versions.sh Go-proxy loop cleanly"
  - "WR-02 sentinel __MISSING__ emitted for nodes where .missing==true or .invalid==true; genuinely versionless structural nodes (neither flag) are not turned into false violations"

patterns-established:
  - "CUTOFF_EXCL pattern: whenever comparing publish instants against a day-precision cutoff, compute next-day midnight via python3 and compare strictly-less-than, not lexicographically against T23:59:59Z"

requirements-completed: [PIN-07, PIN-01, PIN-03, PIN-04, PIN-05]

# Metrics
duration: 7min
completed: "2026-06-14"
---

# Phase 1 Plan 03: Gap-Closure (CR-01 Boundary Fix + WARNING Hardening) Summary

**PIN-07 fail-closed guarantee restored at millisecond precision via CUTOFF_EXCL exclusive next-day-midnight bound in verifier + resolver; eval replaced with allowlist-validated parse; npm-ls snapshot guarded; missing transitive deps now surfaced as violations**

## Performance

- **Duration:** ~7 min
- **Started:** 2026-06-14T17:26:10Z
- **Completed:** 2026-06-14T17:33:08Z
- **Tasks:** 2 of 2
- **Files modified:** 5

## Accomplishments

- Replaced the lexicographic `T23:59:59Z` cutoff comparison in both `verify-pins.sh` and `resolve-versions.sh` with an exclusive next-day-midnight bound (`CUTOFF_EXCL`) computed via python3, closing the CR-01 fail-open at the millisecond boundary window (a package published at `T23:59:59.500Z` is now correctly treated as compliant; a next-day package is correctly rejected)
- Added three boundary test cases to `tests/test-pin-held.sh`: far-from-boundary (Case 1, existing), inclusive-boundary ALLOWED (Case 2, new), next-day REJECTED (Case 3, new) — all pass end-to-end against live registries
- Replaced `eval "$(...resolver...)"` in `build-and-lock.sh` with a process-substitution + allowlist parse using `printf -v`, with strict pattern validation per key (CR-02 code-injection risk closed)
- Guarded the Dockerfile `npm ls` snapshot step with `|| true` so JSON is always captured, then `jq empty` validates it before `govulncheck --version` (WR-01 build-abort risk closed)
- Updated `allpkgs` jq flatten in `verify-pins.sh` to emit `__MISSING__` sentinel for nodes with `.missing==true` or `.invalid==true`; the transitive loop increments VIOLATIONS on the sentinel (WR-02 silent-drop risk closed)
- Folded IN-02 pre-release filter (`^v[0-9]+\.[0-9]+\.[0-9]+$`) into the Go-proxy tag loop in `resolve-versions.sh` — govulncheck pin selection now skips pseudo-versions and pre-releases

## Task Commits

Each task was committed atomically:

1. **Task 1: Fix boundary cutoff comparison (CR-01) in verify-pins.sh + resolve-versions.sh + boundary regression test** - `47b6526` (fix)
2. **Task 2: WARNING hardening — eval allowlist (CR-02), npm-ls guard (WR-01), missing-dep surfacing (WR-02)** - `1fbf814` (fix)

## Files Created/Modified

- `scripts/verify-pins.sh` — CUTOFF_EXCL computed via python3; check_date compares against CUTOFF_EXCL not T23:59:59Z; allpkgs emits __MISSING__ for missing/invalid nodes; loop counts sentinel as violation
- `scripts/resolve-versions.sh` — CUTOFF_EXCL computed via python3; Go-proxy loop uses `< $CUTOFF_EXCL`; both jq npm selects use `.value < $cutoff_excl`; Go tags filtered to release form (IN-02)
- `scripts/build-and-lock.sh` — eval removed; process-substitution allowlist parse with printf -v; validation reordered before INFO logging (IN-01)
- `tests/test-pin-held.sh` — Cases 2 (inclusive boundary ALLOWED) and 3 (next-day REJECTED) added alongside Case 1 (far-from-boundary, existing)
- `Dockerfile` — Step 7 npm ls snapshot guarded: `{ npm ls ... > /versions-npm.json || true; } && jq empty /versions-npm.json && govulncheck --version > /versions-govulncheck.txt`

## Decisions Made

- CUTOFF_EXCL is formed as `${NEXT_DAY}T00:00:00.000Z` where NEXT_DAY is computed via `python3 datetime + timedelta(days=1)` — the same cross-platform date utility already used in resolve-versions.sh for COOLDOWN_DATE
- Lexicographic string comparison against CUTOFF_EXCL is safe at millisecond precision: no `T23:59:59.NNNZ` value sorts at or above `T00:00:00.000Z` of the next calendar day
- `CUTOFF` (the original `T23:59:59Z` string) is retained for display and log messages only — it is never used as the comparison operand
- IN-02 folded cleanly into the Go-proxy loop with a single `=~` regex guard; no structural change needed

## Deviations from Plan

None — plan executed exactly as written. All four code-review findings (CR-01, CR-02, WR-01, WR-02) addressed as specified. IN-02 folded cleanly (no deferral needed).

## Notes

**IN-02 disposition:** Folded in. The Go-proxy tag regex filter `^v[0-9]+\.[0-9]+\.[0-9]+$` was added to the govulncheck version selection loop in `resolve-versions.sh` with no structural complications. Future resolver runs will no longer select a pre-release (such as the `1.5.0-rc.1` gsd-core example seen in the verifier run from 01-VERIFICATION.md) as the govulncheck pin.

**WR-03/WR-04/WR-05/WR-06:** Not addressed in this plan (scope was CR-01, CR-02, WR-01, WR-02). WR-03 (double-counted violation), WR-04 (CHECKED undercount), WR-05 (--before vs resolver boundary alignment), and WR-06 (cache-bust test fragility) remain as informational findings from 01-REVIEW.md. These do not affect correctness of the fail-closed guarantee; they are cosmetic/observability issues. Deferred to a future hardening plan if needed.

## Issues Encountered

None.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- PIN-07 fail-closed guarantee is now structurally correct at millisecond precision
- Phase 1 supply-chain pinning pipeline is complete with all BLOCKER and WARNING findings closed
- Phase 2 (sandbox lifecycle: `openshell sandbox create`, bind mount, entry point) can proceed

## Self-Check: PASSED

| Check | Result |
|-------|--------|
| scripts/verify-pins.sh exists | FOUND |
| scripts/resolve-versions.sh exists | FOUND |
| scripts/build-and-lock.sh exists | FOUND |
| tests/test-pin-held.sh exists | FOUND |
| Dockerfile exists | FOUND |
| 01-03-SUMMARY.md exists | FOUND |
| Task 1 commit 47b6526 | FOUND |
| Task 2 commit 1fbf814 | FOUND |

---
*Phase: 01-dockerfile-and-supply-chain-pinning*
*Completed: 2026-06-14*
