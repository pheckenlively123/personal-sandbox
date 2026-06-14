---
status: partial
phase: 01-dockerfile-and-supply-chain-pinning
source: [01-VERIFICATION.md]
started: 2026-06-14T18:00:00Z
updated: 2026-06-14T19:30:00Z
---

## Current Test

(none — session paused with 1 blocker found)

## Tests

### 1. End-to-end podman build pipeline
expected: |
  `bash scripts/build-and-lock.sh --cooldown-days 4` completes, image
  `claude-sandbox:dev` created, all six tools installed at cooldown-pinned
  versions, versions.lock + versions-npm.json updated, verify-pins.sh exits 0.
result: issue
reported: "Ran on host (podman 5.0.2, arm64). Resolver + RPM installs + go install + npm installs + git clone all succeeded, but `podman build` FAILED at STEP 14/16 with `jq: command not found` (exit 127). The in-image snapshot step runs `jq empty /versions-npm.json` but jq is not in the dnf install list (golang, golangci-lint, nodejs, npm, git, ca-certificates). versions.lock/versions-npm.json were NOT regenerated because the build aborted before the host-side extract+assemble steps."
severity: blocker

### 2. Cache-bust guarantee on COOLDOWN_DATE change
expected: |
  Change --cooldown-days between two consecutive runs. The second podman build
  shows no CACHED marker on the `dnf update -y` step. `bash tests/test-cache-bust.sh`
  automates the assertion and passes.
result: blocked
blocked_by: prior-phase
reason: "Depends on a successful podman build (Test 1), which currently fails at STEP 14. Cannot assess cache-bust until the build completes end-to-end."

### 3. govulncheck version inside the built image
expected: |
  Inside the built image, `govulncheck --version` reports a version from
  versions-govulncheck.txt (e.g. govulncheck@v1.3.0, published 2026-04-22 — well
  before the cooldown date).
result: blocked
blocked_by: prior-phase
reason: "Requires the built image, which cannot be produced until Test 1 (the build) succeeds. Note: govulncheck installs at STEP 9 before the failure, so the tool itself is present — only the final snapshot/validation step fails."

## Summary

total: 3
passed: 0
issues: 1
pending: 0
skipped: 0
blocked: 2

## Gaps

- truth: "podman build completes end-to-end producing claude-sandbox:dev with versions.lock + versions-npm.json (Success Criterion 1)"
  status: failed
  reason: "Build fails at Dockerfile STEP 14 (`jq empty /versions-npm.json`) with `jq: command not found` (exit 127). The 01-03 WR-01 fix (commit 1fbf814) added a build-time `jq` invocation inside the image without adding `jq` to the `dnf install -y` package list. Regression: the pre-01-03 snapshot step used no jq and built successfully (versions.lock dated 2026-06-13)."
  severity: blocker
  test: 1
  artifacts:
    - "Dockerfile (line ~15: dnf install list; line ~59: jq empty guard)"
  missing:
    - "jq in the Dockerfile dnf install package list"
