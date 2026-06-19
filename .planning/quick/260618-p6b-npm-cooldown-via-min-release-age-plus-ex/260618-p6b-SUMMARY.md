---
phase: quick-260618-p6b
plan: 01
subsystem: build-scripts
tags: [npm, cooldown, supply-chain, dockerfile, scripts]
requirements: [PIN-04, PIN-05]

dependency_graph:
  requires: []
  provides: [npm-cooldown-via-min-release-age, explicit-script-policy, registry-only-source-policy]
  affects: [Dockerfile, scripts/resolve-versions.sh, scripts/build-and-lock.sh, CLAUDE.md]

tech_stack:
  added: []
  patterns:
    - npm --min-release-age for native rolling cooldown (replaces --before + pre-resolved version pins)
    - --ignore-scripts for gsd-core (no install scripts; setup via explicit gsd-core --claude --global)
    - --allow-scripts @anthropic-ai/claude-code (first-party postinstall only)
    - --allow-git=none --allow-remote=none --allow-directory=none (registry-only source posture)
    - echo cache-bust reference in each RUN layer to invalidate on COOLDOWN_DATE change

key_files:
  modified:
    - Dockerfile
    - scripts/resolve-versions.sh
    - scripts/build-and-lock.sh
    - CLAUDE.md
  created: []

decisions:
  - npm cooldown uses --min-release-age=${COOLDOWN_DAYS} (native npm 11 flag) instead of --before + pre-resolved version pins
  - npm package versions are now known post-build (from versions-npm.json) not pre-build
  - gsd-core uses --ignore-scripts; claude-code uses --allow-scripts @anthropic-ai/claude-code
  - verify-pins.sh remains the absolute backstop (unchanged) for cooldown enforcement
  - resolve-versions.sh kept for govulncheck only (Go proxy, not npm)

metrics:
  duration: "~15min"
  completed: "2026-06-18"
  tasks_completed: 4
  tasks_total: 4
  files_modified: 4
---

# Quick Task 260618-p6b: npm Cooldown via --min-release-age + Explicit Script/Source Policy

**One-liner:** Replaced hand-rolled npm version selection and `--before` flag with npm 11 native `--min-release-age=${COOLDOWN_DAYS}`, added explicit `--ignore-scripts`/`--allow-scripts` policy, and enforced registry-only sources via `--allow-git/remote/directory=none`.

---

## What Was Done

### Task 1: Dockerfile
- Removed `ARG GSD_CORE_VERSION` and `ARG CLAUDE_CODE_VERSION`; added `ARG COOLDOWN_DAYS`
- Removed `gsd.core.version` and `claude.code.version` LABEL lines (values not known at build time)
- Step 4 (gsd-core): `npm install -g @opengsd/gsd-core --min-release-age=${COOLDOWN_DAYS} --ignore-scripts --allow-git=none --allow-remote=none --allow-directory=none` + leading `echo "cooldown=${COOLDOWN_DATE}"` cache-bust
- Step 5 (claude-code): `npm install -g @anthropic-ai/claude-code --min-release-age=${COOLDOWN_DAYS} --allow-scripts @anthropic-ai/claude-code --allow-git=none --allow-remote=none --allow-directory=none` + leading cache-bust
- Comments updated to describe new mechanism, script policy, and source policy rationale

### Task 2: scripts/resolve-versions.sh
- Removed `@opengsd/gsd-core` and `@anthropic-ai/claude-code` resolution blocks (~54 lines removed)
- Removed `GSD_CORE_VERSION` and `CLAUDE_CODE_VERSION` output echo lines
- Stdout now emits exactly two lines: `COOLDOWN_DATE=...` and `GOVULNCHECK_VERSION=...`
- Header doc comment updated to reflect reduced scope
- govulncheck resolution and `CUTOFF_EXCL` machinery completely unchanged

### Task 3: scripts/build-and-lock.sh
- Removed `GSD_CORE_VERSION`/`CLAUDE_CODE_VERSION` from init vars, case allowlist, required-vars loop
- Removed INFO log lines for those two vars
- Replaced `--build-arg "GSD_CORE_VERSION=..."` and `--build-arg "CLAUDE_CODE_VERSION=..."` with `--build-arg "COOLDOWN_DAYS=${COOLDOWN_DAYS}"`
- Added post-extraction block (after file-existence guards): derives `GSD_CORE_VERSION` and `CLAUDE_CODE_VERSION` via `jq` from `versions-npm.json`; fails closed with `ERROR: + exit 1` if either key is empty
- Lock assembly (jq -n), verify-pins.sh invocation, and INFO summary lines unchanged

### Task 4: CLAUDE.md
- Updated gsd-core Install Mechanism: `--min-release-age` + `--ignore-scripts` + source policy flags
- Updated Claude Code Install Command section: `--min-release-age` + `--allow-scripts @anthropic-ai/claude-code` + source policy flags
- Renamed "npm --before: What It Actually Does" section to "npm --min-release-age: What It Actually Does" with updated semantics and reproducibility trade-off note
- Updated Alternatives Considered table: `--min-release-age` is now recommended for npm packages; `--before` noted as equivalent alternative
- Updated What NOT to Use table: replaced old npx/--before row; added rows for missing `--ignore-scripts`, missing `--allow-scripts`, missing `--allow-git/remote/directory=none`

---

## Commits

| Task | Commit | Message |
|------|--------|---------|
| 1 - Dockerfile | e9626d6 | feat(quick-260618-p6b-01): Dockerfile -- min-release-age npm cooldown + explicit script/source policy |
| 2 - resolve-versions.sh | 09cc082 | feat(quick-260618-p6b-01): resolve-versions.sh -- drop npm resolution, keep COOLDOWN_DATE + govulncheck |
| 3 - build-and-lock.sh | e1bc260 | feat(quick-260618-p6b-01): build-and-lock.sh -- read npm versions post-build from versions-npm.json |
| 4 - CLAUDE.md | a930856 | docs(quick-260618-p6b-01): CLAUDE.md -- sync install commands to --min-release-age, add script/source policy guidance |

---

## Verification Results

**Static checks (Claude-run):**
- `bash -n scripts/resolve-versions.sh` PASS
- `bash -n scripts/build-and-lock.sh` PASS
- `shellcheck` not available on host
- `scripts/resolve-versions.sh` stdout emits exactly two lines: `COOLDOWN_DATE=...` and `GOVULNCHECK_VERSION=...` (static echo-line inspection; network required for live run)
- `git diff --stat` confirms only `Dockerfile`, `scripts/resolve-versions.sh`, `scripts/build-and-lock.sh`, `CLAUDE.md` changed; `scripts/verify-pins.sh` and `rebuild.sh` are byte-for-byte unchanged

**Operator-run checks (require podman + egress):**
- Full `./rebuild.sh` build: confirm `versions.lock` has correct npm versions from `versions-npm.json`
- `verify-pins.sh` Step 5 PASS (every resolved package <= COOLDOWN_DATE)
- `claude --version` works in built image (allow-scripts postinstall ran)
- `gsd-core`/`gsd-tools` resolve in built image (--ignore-scripts safe)
- `npm ls -g --depth=Infinity` snapshot has no missing/invalid nodes (registry-only source policy)

---

## Deviations from Plan

**1. [Rule 1 - Bug] Comment wording adjusted to avoid verify grep false-positive**

- **Found during:** Task 1 verification
- **Issue:** The Step 4 comment contained `--min-release-age=${COOLDOWN_DAYS}` literally; `grep -c` returned 3 (2 RUN lines + 1 comment) instead of the expected 2
- **Fix:** Reworded the comment to `--min-release-age selects the latest dist-tag version older than COOLDOWN_DAYS days` (no literal `${COOLDOWN_DAYS}` in the comment)
- **Files modified:** Dockerfile

**2. [Rule 1 - Bug] Header comment in resolve-versions.sh reworded to avoid npm-ref grep false-positive**

- **Found during:** Task 2 verification
- **Issue:** The explanatory comment `# npm packages (gsd-core, claude-code) are no longer pre-resolved` contained `gsd-core` and `claude-code` substrings that the verify grep `! grep -q 'gsd-core\|claude-code'` flagged
- **Fix:** Rewrote comment as `# npm packages are NOT resolved here` (no package name substrings)
- **Files modified:** scripts/resolve-versions.sh

---

## Known Stubs

None. All changes are wiring/configuration — no placeholder data or TODO stubs.

---

## Threat Flags

None. No new network endpoints, auth paths, file access patterns, or schema changes introduced.

---

## Self-Check

**Commits exist:**
- e9626d6: FOUND
- 09cc082: FOUND
- e1bc260: FOUND
- a930856: FOUND

**Files modified as stated:** Confirmed via `git diff --stat HEAD~4 HEAD`

## Self-Check: PASSED
