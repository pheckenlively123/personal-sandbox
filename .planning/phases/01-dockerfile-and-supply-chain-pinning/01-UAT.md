---
status: testing
phase: 01-dockerfile-and-supply-chain-pinning
source: [01-VERIFICATION.md]
started: 2026-06-14T18:00:00Z
updated: 2026-06-14T18:00:00Z
---

## Current Test

number: 1
name: End-to-end podman build pipeline
expected: |
  Run `bash scripts/build-and-lock.sh --cooldown-days 4` on a host with podman
  installed (Fedora 44 or equivalent). podman build completes without error, all
  six tools installed (Go, golangci-lint, govulncheck, gsd-core, Claude Code CLI,
  claude-engineering-toolkit), versions.lock and versions-npm.json written, and
  verify-pins.sh exits 0.
awaiting: user response

## Tests

### 1. End-to-end podman build pipeline
expected: |
  `bash scripts/build-and-lock.sh --cooldown-days 4` completes, image
  `claude-sandbox:dev` created, all six tools installed at cooldown-pinned
  versions, versions.lock + versions-npm.json updated, verify-pins.sh exits 0.
why_human: podman is not available in this host environment; static inspection confirms correct assembly but the build cannot be executed here.
result: [pending]

### 2. Cache-bust guarantee on COOLDOWN_DATE change
expected: |
  Change --cooldown-days between two consecutive runs. The second podman build
  shows no CACHED marker on the `dnf update -y` step. `bash tests/test-cache-bust.sh`
  automates the assertion and passes.
why_human: Requires live podman to exercise layer-cache behavior. (Note: re-review WR-04 flagged the cache-bust test's string-proximity heuristic as potentially PASS-defaulting — interpret a pass with that caveat.)
result: [pending]

### 3. govulncheck version inside the built image
expected: |
  Inside the built image, `govulncheck --version` reports a version from
  versions-govulncheck.txt (e.g. govulncheck@v1.3.0, published 2026-04-22 — well
  before the cooldown date 2026-06-09).
why_human: Requires the built image to be available.
result: [pending]

## Summary

total: 3
passed: 0
issues: 0
pending: 3
skipped: 0
blocked: 0

## Gaps
