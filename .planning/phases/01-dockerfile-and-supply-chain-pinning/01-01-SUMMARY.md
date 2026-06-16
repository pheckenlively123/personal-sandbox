---
phase: 01-dockerfile-and-supply-chain-pinning
plan: "01"
subsystem: supply-chain-build
tags: [dockerfile, podman, supply-chain, cooldown-pinning, govulncheck, gsd-core, claude-code]
dependency_graph:
  requires: []
  provides:
    - scripts/resolve-versions.sh (host-side cooldown resolver, Phase 2 seam)
    - Dockerfile (fedora:44 image with all six tools at cooldown-pinned versions)
    - scripts/build-and-lock.sh (end-to-end driver: resolve -> build -> lock)
    - .dockerignore (build context exclusions)
    - .gitignore (generated artifact exclusions)
  affects:
    - Phase 2 rebuild.sh (wraps resolve-versions.sh and Dockerfile via this driver)
    - Plan 02 verifier (consumes versions.lock produced by build-and-lock.sh)
tech_stack:
  added:
    - bash resolver helper using curl + jq + python3 date arithmetic
    - podman build (fedora:44 base)
    - govulncheck v1.3.0 via go install (Go module proxy)
    - "@opengsd/gsd-core 1.4.3 via npm install -g --before"
    - "@anthropic-ai/claude-code 2.1.170 via npm install -g --before"
    - claude-engineering-toolkit (git clone at HEAD)
  patterns:
    - ARG-before-RUN cache-bust pattern (D-07)
    - eval $(resolver-script) -> --build-arg pass-through (D-01)
    - podman create/cp/rm extraction (versions-npm.json, versions-govulncheck.txt)
    - versions.lock JSON schema (Pattern 3 from RESEARCH)
key_files:
  created:
    - scripts/resolve-versions.sh
    - scripts/build-and-lock.sh
    - Dockerfile
    - .dockerignore
    - .gitignore
  modified: []
decisions:
  - "bash for resolver (not Go): simpler, no compile, natural eval/source composition for Phase 2"
  - "top-level pins only from resolver: npm --before handles transitive resolution at build time"
  - "versions.lock JSON format (not key=value): cleaner jq parsing in Plan 02 verifier"
  - "--before=${COOLDOWN_DATE}T23:59:59Z (end-of-day UTC): inclusive cutoff for packages published on cutoff day"
  - ".gitignore excludes generated artifacts (versions.lock, versions-npm.json, versions-govulncheck.txt): build outputs not source"
metrics:
  duration: "7m 7s"
  completed: "2026-06-13"
  tasks_completed: 3
  tasks_total: 3
  files_created: 5
  files_modified: 1
---

# Phase 01 Plan 01: Dockerfile and Supply-Chain Pinning Walking Skeleton Summary

**One-liner:** Fedora 44 Dockerfile with ARG-pinned govulncheck/gsd-core/claude-code at 4-day cooldown, driven by bash resolver + podman build + versions.lock extraction.

## What Was Built

Three artifacts implement the resolve -> build -> lock segment of the supply-chain pipeline:

1. **`scripts/resolve-versions.sh`** — Host-side bash resolver. Accepts `--cooldown-days N` (default 4), validates positive integer input, computes `COOLDOWN_DATE` via python3 date arithmetic (cross-platform, avoids macOS-incompatible `date -d`). Queries `proxy.golang.org` for govulncheck and `registry.npmjs.org` for gsd-core + claude-code, using inclusive end-of-day cutoff (`COOLDOWN_DATE T23:59:59Z`). Emits four sourceable `KEY=VALUE` lines to stdout; all diagnostics to stderr. Fails fast on bad input or registry failure (T-01-03, T-01-04 mitigations).

2. **`Dockerfile`** — `FROM fedora:44` (tag only, no digest per D-06). All four ARGs declared before the first `RUN dnf` for cache-bust ordering (D-07). Installs golang + golangci-lint via RPM, govulncheck via `go install`, gsd-core + claude-code via `npm install -g --before`, and the claude-engineering-toolkit via `git clone`. Emits `/versions-npm.json` (`--depth=Infinity`) and `/versions-govulncheck.txt` for host extraction. No PIN-07 gate inside the build (D-03/D-04).

3. **`scripts/build-and-lock.sh`** — End-to-end driver. Evals the resolver output, runs `podman build` with four `--build-arg` flags, extracts snapshots via `podman create`/`cp`/`rm`, queries publish timestamps for all three packages, and assembles `versions.lock` JSON (Pattern 3 schema: `cooldown_date`, `build_date`, `cooldown_days`, `packages.*.{version,publish_date,registry}`, `npm_transitive_snapshot`).

Also created `.dockerignore` (excludes `.planning/`, `.git/`, `*.lock` from build context) and `.gitignore` (excludes generated artifacts from version control).

## Commits

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Host-side resolver (resolve-versions.sh) | eb1afcb | scripts/resolve-versions.sh |
| 2 | Dockerfile + .dockerignore | 44c01f6 | Dockerfile, .dockerignore |
| 3 | build-and-lock.sh + bug fix + .gitignore | baa6421 | scripts/build-and-lock.sh, Dockerfile (fix), .gitignore |

## Verification Results

All must-have truths confirmed:

- `bash scripts/resolve-versions.sh --cooldown-days 4` exits 0 and emits exactly four sourceable KEY=VALUE lines: `COOLDOWN_DATE=2026-06-09`, `GOVULNCHECK_VERSION=v1.3.0`, `GSD_CORE_VERSION=1.4.3`, `CLAUDE_CODE_VERSION=2.1.170`
- `bash scripts/build-and-lock.sh --cooldown-days 4` exits 0; `claude-sandbox:dev` image built successfully (all six tools installed)
- `podman run --rm claude-sandbox:dev govulncheck --version` reports `govulncheck@v1.3.0` (published 2026-04-22, before cooldown 2026-06-09)
- `versions.lock` exists with all required fields; `ws` appears in `versions-npm.json` confirming `--depth=Infinity` transitive capture
- `--cooldown-days abc` exits non-zero with clear error (input validation)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed npm --before date format to include end-of-day time component**
- **Found during:** Task 3 (first build attempt)
- **Issue:** Dockerfile used `--before=${COOLDOWN_DATE}` where `COOLDOWN_DATE` is a bare `YYYY-MM-DD` date. npm interprets `--before=2026-06-09` as midnight start-of-day (UTC), which excluded gsd-core 1.4.3 (published 17:49 UTC) and claude-code 2.1.170 (published 16:15 UTC) — both published on the cutoff day itself.
- **Fix:** Changed to `--before="${COOLDOWN_DATE}T23:59:59Z"` in both npm install steps. The RESEARCH documented the inclusive end-of-day cutoff (Pitfall 2: `COOLDOWN_DATE + T23:59:59Z`) for registry queries; the same cutoff must apply to npm's `--before` flag for the Dockerfile to install the correct versions.
- **Files modified:** `Dockerfile`
- **Commit:** baa6421 (included in Task 3 commit)

**2. [Rule 2 - Missing Critical Functionality] Added .gitignore for generated artifacts**
- **Found during:** Task 3 (post-build artifact check)
- **Issue:** `versions.lock`, `versions-npm.json`, and `versions-govulncheck.txt` appeared as untracked files after the build. These are build outputs, not source files, and should not be committed.
- **Fix:** Created `.gitignore` excluding all three generated artifacts.
- **Files modified:** `.gitignore` (new)
- **Commit:** baa6421

## Known Stubs

None — all artifacts are fully functional. The resolver queries live registries, the Dockerfile installs real packages, and the driver produces a complete `versions.lock`.

## Decisions Made

| Decision | Rationale |
|----------|-----------|
| bash for resolver | Simpler, no compile step, natural `eval $(...)` composition for Phase 2's `rebuild.sh` |
| Top-level pins only from resolver | `npm --before` handles transitive resolution at build time; duplicating Arborist logic host-side adds complexity without accuracy benefit |
| JSON for versions.lock | Cleaner `jq` parsing in Plan 02 pin-held verifier; structured fields make timestamp comparison straightforward |
| `--before="${COOLDOWN_DATE}T23:59:59Z"` | End-of-day UTC cutoff to include packages published on the cutoff day (inclusive per RESEARCH Pitfall 2) |
| `.gitignore` for generated artifacts | Build outputs regenerated on each run; committing them would create noise and conflicts |

## Self-Check: PASSED

All files created:
- FOUND: scripts/resolve-versions.sh
- FOUND: scripts/build-and-lock.sh
- FOUND: Dockerfile
- FOUND: .dockerignore
- FOUND: .gitignore

All commits exist:
- FOUND: eb1afcb (feat(01-01): add host-side resolver helper)
- FOUND: 44c01f6 (feat(01-01): add Dockerfile and .dockerignore)
- FOUND: baa6421 (feat(01-01): add build-and-lock.sh driver + fix --before datetime format)
