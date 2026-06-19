---
task: 260619-eow
title: Revert npm cooldown mechanism from --min-release-age to --before + explicit version pins
type: fix
date: 2026-06-19
commits:
  - 4607d36
  - e9b05a2
files_changed:
  - Dockerfile
  - scripts/resolve-versions.sh
  - scripts/build-and-lock.sh
  - CLAUDE.md
---

# Quick Task 260619-eow: Revert npm cooldown mechanism to --before + explicit version pins

## One-liner

Restored `--before=DATE + @VERSION` npm install pins after live build proved `--min-release-age` is silently ignored by Fedora 44's bundled npm.

## Problem

A live podman build using `--min-release-age=${COOLDOWN_DAYS}` installed `@opengsd/gsd-core@1.5.0` and `@anthropic-ai/claude-code@2.1.183` — both post-cooldown versions — instead of `1.4.0` and `2.1.169`. `verify-pins.sh` (PIN-07) correctly caught 9 violations. Root cause: Fedora 44 ships an older npm that silently ignores `--min-release-age` and falls back to `@latest`.

## Changes Made

### Dockerfile
- Removed `ARG COOLDOWN_DAYS`; added `ARG GSD_CORE_VERSION` and `ARG CLAUDE_CODE_VERSION`
- Step 4 (gsd-core): changed `@opengsd/gsd-core` (bare) to `@opengsd/gsd-core@${GSD_CORE_VERSION}`; replaced `--min-release-age=${COOLDOWN_DAYS}` with `--before="${COOLDOWN_DATE}T23:59:59Z"`; removed redundant `echo "cooldown=..." >/dev/null` cache-bust line (COOLDOWN_DATE is now embedded in the `--before` string itself — natural cache bust)
- Step 5 (claude-code): same pattern — explicit `@${CLAUDE_CODE_VERSION}` + `--before=...`; removed echo cache-bust line
- Restored `LABEL gsd.core.version="${GSD_CORE_VERSION}"` and `LABEL claude.code.version="${CLAUDE_CODE_VERSION}"`
- All Architecture B work, script/source policy flags (`--ignore-scripts`, `--allow-scripts`, `--allow-git/remote/directory=none`) preserved unchanged

### scripts/resolve-versions.sh
- Added `@opengsd/gsd-core` npm registry resolution block: queries `https://registry.npmjs.org/@opengsd/gsd-core`, uses same `jq .time | to_entries | select(release-form + < CUTOFF_EXCL) | sort_by(.value) | last` pattern as govulncheck
- Added `@anthropic-ai/claude-code` npm registry resolution block: same pattern
- Updated header comment to reflect all 4 resolved packages
- Updated stdout docstring to show all 4 emitted keys
- Now emits `GSD_CORE_VERSION=X.Y.Z` and `CLAUDE_CODE_VERSION=X.Y.Z` alongside `COOLDOWN_DATE` and `GOVULNCHECK_VERSION`

### scripts/build-and-lock.sh
- Added `GSD_CORE_VERSION` and `CLAUDE_CODE_VERSION` to the CR-02 allowlist `case` block (validation pattern `^[0-9][0-9A-Za-z._-]*$` — npm version without leading `v`)
- Added both to the IN-01 required-vars loop
- Added `--build-arg "GSD_CORE_VERSION=${GSD_CORE_VERSION}"` and `--build-arg "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}"` to podman build
- Removed `--build-arg "COOLDOWN_DAYS=${COOLDOWN_DAYS}"` from podman build
- Removed the post-build block that read versions from `versions-npm.json` via jq (those versions are now known pre-build from the resolver)
- Step 4 publish-date queries and `jq -n` versions.lock assembly now use `$GSD_CORE_VERSION` / `$CLAUDE_CODE_VERSION` set by the resolver (was already the pattern; variables just were sourced differently)
- Added INFO log lines for the two new resolver-provided variables

### CLAUDE.md
- Section 4 Install Mechanism: replaced `--min-release-age=${COOLDOWN_DAYS}` example with `--before="DATE T23:59:59Z"` + explicit `@VERSION`; updated description paragraph
- Section 4: retitled "npm --min-release-age: What It Actually Does" to "npm --before: What It Actually Does"; updated bullet points; added note explaining why `--min-release-age` is unreliable on older npm
- Section 5 Install Command: updated to explicit `@VERSION --before=DATE` pattern; updated all bullet explanations
- Alternatives Considered table: swapped Recommended/Alternative columns so `--before + @VERSION` is Recommended and `--min-release-age` is Alternative; updated Why Not to cite Fedora 44 failure
- What NOT to Use: updated the `npx` row's "Use Instead" text to `--before` pattern

## Deviations from Task Spec

None. All requested changes applied exactly as specified. KEEP items (Architecture B work, script/source policy flags) were verified preserved.

## Constraints Verification

- `bash -n scripts/resolve-versions.sh`: PASSED
- `bash -n scripts/build-and-lock.sh`: PASSED
- resolve-versions.sh stdout emits exactly 4 vars: `COOLDOWN_DATE`, `GOVULNCHECK_VERSION`, `GSD_CORE_VERSION`, `CLAUDE_CODE_VERSION` (verified via grep of echo lines at bottom of file)
- Full podman build + verify-pins.sh PASS requires operator run — flagged as operator task

## Commits

| Hash | Type | Files |
|------|------|-------|
| 4607d36 | fix | Dockerfile, scripts/resolve-versions.sh, scripts/build-and-lock.sh |
| e9b05a2 | docs | CLAUDE.md |
