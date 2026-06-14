---
status: complete
phase: 01-dockerfile-and-supply-chain-pinning
source: [01-VERIFICATION.md]
started: 2026-06-14T18:00:00Z
updated: 2026-06-14T20:00:00Z
---

## Current Test

[testing complete]

## Tests

### 1. End-to-end podman build pipeline
expected: |
  `bash scripts/build-and-lock.sh --cooldown-days 4` completes, image
  `claude-sandbox:dev` created, all six tools installed at cooldown-pinned
  versions, versions.lock + versions-npm.json updated, verify-pins.sh exits 0.
result: pass
note: |
  First run FAILED at Dockerfile STEP 14 with `jq: command not found` (blocker) —
  the 01-03 WR-01 fix added an in-image `jq empty` validation without adding jq to
  the dnf install list. Fixed in commit bab05b7 (add jq to dnf install). Re-run
  succeeded end-to-end on host (podman 5.0.2, arm64): image localhost/claude-sandbox:dev
  built, all six tools installed, versions.lock/versions-npm.json/versions-govulncheck.txt
  extracted, and the pipeline's final verify-pins.sh exited 0 (109 packages all within
  the 2026-06-10 cutoff). Resolver selected gsd-core 1.5.0-rc.1, claude-code 2.1.172,
  govulncheck v1.3.0.

### 2. Cache-bust guarantee on COOLDOWN_DATE change
expected: |
  Change --cooldown-days between two consecutive runs. The second podman build
  shows no CACHED marker on the `dnf update -y` step. `bash tests/test-cache-bust.sh`
  automates the assertion and passes.
result: pass
note: |
  `bash tests/test-cache-bust.sh` PASSED. Built with COOLDOWN_DATE 2026-06-08 then
  2026-06-09; build 2's dnf layer was NOT cached (the 4 CACHED layers were the ARG
  declarations, not the dnf RUN — build 2 genuinely re-downloaded golang/git/etc.,
  confirming a real cache miss rather than the WR-04 heuristic defaulting to PASS).

### 3. govulncheck version inside the built image
expected: |
  Inside the built image, `govulncheck --version` reports a version from
  versions-govulncheck.txt (e.g. govulncheck@v1.3.0, published 2026-04-22 — well
  before the cooldown date).
result: pass
note: |
  `podman run --rm claude-sandbox:dev govulncheck --version` reports
  `govulncheck@v1.3.0`, matching the extracted versions-govulncheck.txt. v1.3.0
  published 2026-04-22 — well before the 2026-06-10 cooldown cutoff.

## Summary

total: 3
passed: 3
issues: 0
pending: 0
skipped: 0
blocked: 0

## Gaps

[resolved — the one blocker (jq missing from image) was fixed in commit bab05b7 and re-verified by a successful end-to-end build]
