---
phase: 01-dockerfile-and-supply-chain-pinning
plan: "02"
subsystem: supply-chain-verification
tags: [pin-held, supply-chain, verifier, cache-bust, govulncheck, gsd-core, tests]
dependency_graph:
  requires:
    - scripts/build-and-lock.sh (Plan 01 — driver that produces versions.lock)
    - versions.lock (Plan 01 — lock file the verifier reads)
    - versions-npm.json (Plan 01 — transitive dep snapshot verifier iterates)
  provides:
    - scripts/verify-pins.sh (host PIN-07 verifier; fail-closed gate for the pipeline)
    - tests/test-cache-bust.sh (IMG-02 / Criterion #2 assurance: dnf cache busts on date change)
    - tests/test-pin-held.sh (PIN-07 / Criterion #5 negative-path: violation caught non-zero)
  affects:
    - scripts/build-and-lock.sh (modified: verify-pins.sh wired as final Step 5)
    - Phase 2 rebuild.sh (will wrap build-and-lock.sh which now carries the PIN-07 gate)
tech_stack:
  added:
    - bash verifier using curl + jq for registry timestamp re-querying
    - jq recursive flatten pattern for transitive dep extraction from npm ls JSON
    - declare -A associative array for per-package registry response caching
  patterns:
    - ISO-8601 lexicographic string comparison for publish-date vs cutoff ([[ "$DATE" > "$CUTOFF" ]])
    - Fail-closed posture with set -euo pipefail + explicit missing-file exits
    - Temp directory isolation in tests (mktemp -d + trap EXIT cleanup)
    - jq recursive def allpkgs for deep-flattening npm ls --depth=Infinity tree
key_files:
  created:
    - scripts/verify-pins.sh
    - tests/test-cache-bust.sh
    - tests/test-pin-held.sh
  modified:
    - scripts/build-and-lock.sh (appended Step 5: verify-pins.sh call)
decisions:
  - "keep-id registry cache per-package to avoid N*M curl calls (106 transitive deps)"
  - "use live registry re-query for negative test: seed a real post-cutoff version (gsd-core 1.4.4) rather than mocking timestamps"
  - "test-pin-held seeds top-level version field in temp lock; verifier re-queries live registry and catches the violation"
metrics:
  duration: "4m 14s"
  completed: "2026-06-13"
  tasks_completed: 2
  tasks_total: 2
  files_created: 3
  files_modified: 1
---

# Phase 01 Plan 02: Pin-Held Verifier and Guarantee Tests Summary

**One-liner:** Host-side PIN-07 verifier (fail-closed, 109 packages checked including all transitive) wired as final pipeline step, plus cache-bust and negative-path guarantee tests.

## What Was Built

Two tasks implement the PIN-07 safety gate and its guarantee tests:

1. **`scripts/verify-pins.sh`** — Fail-closed host-side verifier (PIN-07). Reads `versions.lock` to get `cooldown_date` and forms `CUTOFF="${cooldown_date}T23:59:59Z"` (inclusive end-of-day, Pitfall 2). Checks three top-level packages: govulncheck via `proxy.golang.org/.info/.Time`, and `@opengsd/gsd-core` / `@anthropic-ai/claude-code` via `registry.npmjs.org/.time[version]`. Then flattens the entire `versions-npm.json` tree using a recursive jq `allpkgs` pattern and re-queries every transitive dep's publish date (106 packages, 109 total). Uses an associative array to cache registry responses per package (avoiding redundant curl calls). On any violation: prints `FAIL: <pkg> <ver> published <date> > cutoff <CUTOFF>` to stderr and exits 1. Missing input files, malformed JSON, or registry failures all exit non-zero (fail-closed, D-03). All clean: prints a PASS summary and exits 0.

2. **`scripts/build-and-lock.sh`** (modified) — Step 5 appended: `bash "${SCRIPT_DIR}/verify-pins.sh"` as the terminal step. The driver now propagates the PIN-07 exit code, so the overall pipeline exits non-zero whenever the verifier finds a violation.

3. **`tests/test-cache-bust.sh`** — IMG-02 / Criterion #2 guarantee. Runs `podman build` twice with different `COOLDOWN_DATE` values (`2026-06-08` and `2026-06-09`) using throwaway image tags that don't clobber `claude-sandbox:dev`. Greps Build 2's output for `CACHED` or `Using cache` markers; if the dnf update layer shows as cached despite the date change, the test fails. The build may fail after the dnf/rpm layer (if downstream npm/go steps lack network); the test captures those expected failures and still evaluates the dnf layer's cache behavior.

4. **`tests/test-pin-held.sh`** — PIN-07 / Criterion #5 negative-path proof. Creates a temp directory, writes a copy of `versions.lock` with `@opengsd/gsd-core` bumped to `1.4.4` (published `2026-06-11T00:48:28.454Z` — after the `2026-06-09T23:59:59Z` cutoff), runs `verify-pins.sh --lock <temp>`, and asserts the verifier exits non-zero. The real `versions.lock` is never modified. Cleanup via `trap EXIT`. Verified: exits 0 (test passes) when `verify-pins.sh` correctly exits 1 for the seeded violation.

## Commits

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | PIN-07 verifier + build-and-lock wiring | 58f114b | scripts/verify-pins.sh, scripts/build-and-lock.sh |
| 2 | Cache-bust and pin-held guarantee tests | e31e4e0 | tests/test-cache-bust.sh, tests/test-pin-held.sh |

## Verification Results

All must-have truths confirmed:

- `bash scripts/verify-pins.sh` exits 0 against the real `versions.lock` + `versions-npm.json` — 109 packages checked, PASS
- `bash scripts/verify-pins.sh --lock /nonexistent/versions.lock` exits 1 (fail-closed, D-03)
- `grep 'versions-npm.json' scripts/verify-pins.sh` confirms transitive dep iteration (8 references, D-04)
- `grep 'verify-pins.sh' scripts/build-and-lock.sh` confirms Step 5 wiring (2 references)
- `bash tests/test-pin-held.sh` exits 0 — seeded `@opengsd/gsd-core@1.4.4` (published 2026-06-11) caught by live registry re-query, verifier exits 1, test passes (Criterion #5)
- No PIN-07 date comparison in Dockerfile — `T23:59:59Z` in Dockerfile appears only in `npm --before` install arguments, not in pin-held verification logic (D-03/D-04 preserved)

## Deviations from Plan

None — plan executed exactly as written.

The `T23:59:59Z` in Dockerfile's `npm --before` args is expected (not a deviation): it was added in Plan 01 to fix the inclusive cutoff bug. The plan's acceptance criterion "no pin-held comparison inside Dockerfile RUN" refers to the verifier's publish-date comparison, which correctly lives only in `verify-pins.sh`.

## Known Stubs

None — all artifacts are fully functional. The verifier queries live registries, the negative test uses a real post-cutoff version, and both test scripts are immediately runnable.

## Threat Flags

No new threat surface introduced by this plan. The files are host-side scripts only; they do not add network endpoints, auth paths, or schema changes. The trust boundary `versions.lock → verifier` (T-01-07) and `verifier → registries` (T-01-08) were modeled in the plan's threat register and are fully mitigated by the fail-closed implementation.

## Self-Check: PASSED

All files created:
- FOUND: scripts/verify-pins.sh
- FOUND: tests/test-cache-bust.sh
- FOUND: tests/test-pin-held.sh

All commits exist:
- FOUND: 58f114b (feat(01-02): add PIN-07 verifier and wire into pipeline)
- FOUND: e31e4e0 (feat(01-02): add cache-bust and pin-held guarantee tests)
