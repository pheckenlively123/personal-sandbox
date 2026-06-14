---
phase: 01-dockerfile-and-supply-chain-pinning
verified: 2026-06-14T00:00:00Z
status: gaps_found
score: 4/5 must-haves verified
overrides_applied: 0
gaps:
  - truth: "The build fails (exit non-zero) if any pinned package's publish date is after the cooldown date (PIN-07 pin-held verification)"
    status: failed
    reason: "CR-01 (from 01-REVIEW.md): verify-pins.sh uses bash lexicographic string comparison [[ pub_date > CUTOFF ]] where CUTOFF is '${COOLDOWN_DATE}T23:59:59Z' (no fractional seconds). npm registry timestamps carry millisecond precision (e.g. 2026-06-09T17:49:11.123Z). A package published within the window 23:59:59.000Z–23:59:59.999Z on the cutoff day lexicographically sorts BEFORE the cutoff string (dot 0x2E < Z 0x5A), so [[ pub_date > CUTOFF ]] evaluates false and the violation passes silently. The verifier fails OPEN at the cutoff boundary. The same bug exists in resolve-versions.sh (jq .value <= $cutoff is also lexicographic). test-pin-held.sh does not exercise this boundary because its seeded version (gsd-core 1.4.4 @ 2026-06-11T00:48Z) is far from the cutoff boundary. The existing lock's packages happen to be 6+ hours before the boundary, so the current versions.lock is not affected — but the verifier's correctness guarantee for future builds is broken."
    artifacts:
      - path: "scripts/verify-pins.sh"
        issue: "Line 110: [[ \"${pub_date}\" > \"${CUTOFF}\" ]] — lexicographic comparison with second-precision cutoff fails to catch millisecond-precision timestamps in window 23:59:59.000Z–23:59:59.999Z"
      - path: "scripts/resolve-versions.sh"
        issue: "Line 99: [[ PUB_TIME < CUTOFF ]] || [[ PUB_TIME == CUTOFF ]] and line 127 jq .value <= $cutoff — same lexicographic flaw; may select a version within boundary window or reject one that should be valid"
    missing:
      - "Replace lexicographic cutoff comparison in verify-pins.sh with an exclusive next-day-midnight bound (CUTOFF_EXCL = NEXT_DAY + T00:00:00.000Z) or with python3 datetime parsing"
      - "Apply the same fix to resolve-versions.sh Go proxy comparison (line 99) and jq selects (lines 127, 149)"
      - "Add a boundary-window test to test-pin-held.sh seeding a version published at T23:59:59.500Z on the cutoff day and asserting exit non-zero"
---

# Phase 01: Dockerfile and Supply-Chain Pinning Verification Report

**Phase Goal:** A `podman build` of the Dockerfile succeeds and produces an image with all required tooling installed at cooldown-pinned versions, with a `versions.lock` artifact capturing exact resolved versions.
**Verified:** 2026-06-14T00:00:00Z
**Status:** gaps_found
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `podman build` completes successfully from Fedora 44, installing Go toolchain, golangci-lint, govulncheck, gsd-core, Claude Code CLI, and claude-engineering-toolkit | VERIFIED | Dockerfile exists at `FROM fedora:44` with all six tools; versions.lock and versions-govulncheck.txt (govulncheck@v1.3.0) were produced from a completed build; SUMMARY confirms build succeeded |
| 2 | Build log shows no `CACHED` entry for `dnf update -y` when COOLDOWN_DATE changes between runs | VERIFIED | tests/test-cache-bust.sh exists, is executable, asserts no CACHED on dnf layer across differing dates; ARG COOLDOWN_DATE on Dockerfile line 6 precedes first `RUN dnf` on line 14 (cache-bust ordering confirmed by grep) |
| 3 | `govulncheck --version` inside the built image shows a release on or before the cooldown date | VERIFIED | versions-govulncheck.txt contains `Scanner: govulncheck@v1.3.0`; govulncheck v1.3.0 published 2026-04-22T22:03:04Z; cooldown date was 2026-06-09 — 48 days before build |
| 4 | A `versions.lock` file records the exact pinned versions of govulncheck, gsd-core, and Claude Code CLI with their cooldown-resolved timestamps | VERIFIED | versions.lock contains cooldown_date, build_date, cooldown_days, packages.govulncheck.{version,publish_date}, packages.@opengsd/gsd-core.{version,publish_date}, packages.@anthropic-ai/claude-code.{version,publish_date}, npm_transitive_snapshot |
| 5 | The build fails (exit non-zero) if any pinned package's publish date is after the cooldown date (PIN-07 pin-held verification) | FAILED | verify-pins.sh is wired as the final step of build-and-lock.sh and correctly exits non-zero for clearly post-cutoff packages. However, the lexicographic comparison [[ pub_date > CUTOFF ]] fails open for timestamps in the window 23:59:59.000Z–23:59:59.999Z on the cutoff day (CR-01 from 01-REVIEW.md). This is a structural correctness failure of the fail-closed guarantee, not merely a cosmetic warning. The test suite does not cover this boundary case. |

**Score:** 4/5 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `scripts/resolve-versions.sh` | Host-side cooldown resolver; emits COOLDOWN_DATE + 3 version pins | VERIFIED | Exists, executable (755), 6300 bytes; emits exactly four KEY=VALUE lines; input validation exits non-zero on bad args; confirmed live: exits 0 and emits correct output for --cooldown-days 4 |
| `Dockerfile` | FROM fedora:44, ARG-pinned, all 6 tools, cache-bust ordering | VERIFIED | Exists; FROM fedora:44 on line 1; ARG COOLDOWN_DATE on line 6 (before RUN dnf on line 14); no @latest in npm installs; both npm installs carry --before="${COOLDOWN_DATE}T23:59:59Z"; toolkit cloned; npm ls -g --json --depth=Infinity emitted |
| `scripts/build-and-lock.sh` | End-to-end driver: resolve -> build -> extract -> versions.lock -> verify | VERIFIED | Exists, executable; evals resolver, runs podman build with 4 --build-args, extracts via podman create/cp/rm, assembles versions.lock via jq, calls verify-pins.sh as Step 5 |
| `scripts/verify-pins.sh` | PIN-07 fail-closed verifier; reads versions.lock + versions-npm.json; exits 1 on violation | PARTIAL — structural bug | Exists, executable; is wired in build-and-lock.sh; re-queries registries; iterates transitive deps; fails closed on missing inputs. However, lexicographic cutoff comparison (CR-01) fails open at boundary 23:59:59.NNNz |
| `tests/test-cache-bust.sh` | Asserts dnf layer not CACHED on COOLDOWN_DATE change | VERIFIED | Exists, executable; builds with two different dates (2026-06-08 / 2026-06-09); asserts no CACHED on dnf layer of second build |
| `tests/test-pin-held.sh` | Negative-path proof: seeded post-cutoff pin exits non-zero | VERIFIED (with caveat) | Exists, executable; seeds gsd-core@1.4.4 (published 2026-06-11T00:48:28.454Z) — far from boundary; verifier correctly catches it. Test does NOT cover the CR-01 boundary window |
| `.dockerignore` | Excludes .planning/, .git/, *.lock | VERIFIED | Excludes .planning/, .git/, *.lock, versions-npm.json, versions-govulncheck.txt |
| `versions.lock` (generated) | JSON with cooldown_date, build_date, cooldown_days, packages.*.{version,publish_date}, npm_transitive_snapshot | VERIFIED | Present at project root; all required fields confirmed; cooldown_date=2026-06-09, build_date=2026-06-13 |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `scripts/build-and-lock.sh` | `scripts/resolve-versions.sh` | eval $(...) on line 62 | WIRED | Resolver output eval'd to load COOLDOWN_DATE + version vars |
| `scripts/build-and-lock.sh` | `Dockerfile` | podman build --build-arg on lines 81-87 | WIRED | All 4 build-args passed: COOLDOWN_DATE, GOVULNCHECK_VERSION, GSD_CORE_VERSION, CLAUDE_CODE_VERSION |
| `scripts/build-and-lock.sh` | `scripts/verify-pins.sh` | bash ... verify-pins.sh on lines 205-207 | WIRED | Called as Step 5 (final step) with --lock and --npm-snapshot flags |
| `scripts/verify-pins.sh` | `versions.lock` | jq reads cooldown_date + package versions | WIRED | LOCK_FILE read on lines 84, 141, 160 |
| `scripts/verify-pins.sh` | `versions-npm.json` | jq recursive allpkgs flatten on lines 180-188 | WIRED | NPM_SNAPSHOT iterated for transitive deps (8 references to file) |
| `Dockerfile` | `/versions-npm.json` | npm ls -g --json --depth=Infinity > /versions-npm.json (line 54) | WIRED — with gap | npm ls exits non-zero on peer/extraneous deps; no `|| true` guard means build can fail at this step (WR-01) |

### Data-Flow Trace (Level 4)

Not applicable — this phase produces shell scripts and a Dockerfile, not data-rendering components. The relevant data flow is supply-chain metadata through the pipeline (resolver -> build-args -> image -> extraction -> versions.lock -> verifier), which was verified at the key-link level above.

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Resolver emits 4 KEY=VALUE lines with correct format | `bash scripts/resolve-versions.sh --cooldown-days 4 2>/dev/null` | COOLDOWN_DATE=2026-06-10, GOVULNCHECK_VERSION=v1.3.0, GSD_CORE_VERSION=1.5.0-rc.1, CLAUDE_CODE_VERSION=2.1.172 | PASS |
| Resolver rejects non-integer cooldown-days | `bash scripts/resolve-versions.sh --cooldown-days abc; echo $?` | "ERROR: --cooldown-days must be a positive integer" + exit 1 | PASS |
| Changing cooldown-days changes COOLDOWN_DATE | `--cooldown-days 4` vs `--cooldown-days 10` | 4-day: 2026-06-10; 10-day: 2026-06-04 (10-day is earlier, PIN-01/PIN-02 confirmed) | PASS |
| CR-01 boundary: package at T23:59:59.500Z on cutoff day passes verifier | `bash -c '[[ "2026-06-09T23:59:59.500Z" > "2026-06-09T23:59:59Z" ]]; echo $?'` | exit 1 (false) — meaning the violation is NOT caught | FAIL — confirms CR-01 |

Note: `gsd-core 1.5.0-rc.1` (a pre-release) was resolved today because it was the latest version before today's cutoff. This also surfaces IN-02 from the review: the resolver does not filter pre-releases or pseudo-versions from the Go proxy list or npm registry. For gsd-core, a release candidate was selected today where a stable release may have been intended.

### Probe Execution

No `probe-*.sh` scripts declared or found. Step 7c: SKIPPED (no conventional probes).

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| IMG-01 | 01-01-PLAN | FROM fedora:44 base | SATISFIED | Dockerfile line 1: `FROM fedora:44`; no digest (per D-06) |
| IMG-02 | 01-01-PLAN, 01-02-PLAN | dnf update -y with cache-bust per rebuild | SATISFIED | ARG COOLDOWN_DATE (line 6) before RUN dnf (line 14); test-cache-bust.sh tests the guarantee |
| IMG-03 | 01-01-PLAN | Go via RPM (`golang`) | SATISFIED | `golang` in dnf install list, Dockerfile line 16 |
| IMG-04 | 01-01-PLAN | golangci-lint via RPM | SATISFIED | `golangci-lint` in dnf install list, Dockerfile line 17 |
| IMG-05 | 01-01-PLAN | claude-engineering-toolkit cloned at build time | SATISFIED | `RUN git clone https://github.com/pheckenlWork/claude-engineering-toolkit.git /opt/claude-engineering-toolkit` on Dockerfile lines 47-48 |
| PIN-01 | 01-01-PLAN | Cooldown date computed as build date minus N days (rolling) | SATISFIED | resolve-versions.sh uses python3 date arithmetic: `date.today() - timedelta(days=N)` |
| PIN-02 | 01-01-PLAN | Cooldown window overridable via --cooldown-days N | SATISFIED | resolve-versions.sh and build-and-lock.sh both accept --cooldown-days; confirmed via spot-check |
| PIN-03 | 01-01-PLAN | govulncheck pinned to latest version as of cooldown date | SATISFIED | Dockerfile: `go install golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}`; resolver queries Go proxy per-tag |
| PIN-04 | 01-01-PLAN | gsd-core pinned with transitive deps via npm --before | SATISFIED | `npm install -g @opengsd/gsd-core@${GSD_CORE_VERSION} --before="${COOLDOWN_DATE}T23:59:59Z"` |
| PIN-05 | 01-01-PLAN | Claude Code pinned to latest version as of cooldown date | SATISFIED | `npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} --before="${COOLDOWN_DATE}T23:59:59Z"` |
| PIN-06 | 01-01-PLAN | versions.lock capturing exact versions with timestamps | SATISFIED | versions.lock produced with all required fields; npm_transitive_snapshot linked to versions-npm.json |
| PIN-07 | 01-02-PLAN | Pin-held verification fails build if any package postdates cooldown | FAILED — BLOCKER | verify-pins.sh is wired and correctly fails for clearly post-cutoff packages, but CR-01 lexicographic comparison bug allows packages published in the window 23:59:59.000Z–23:59:59.999Z on the cutoff day to pass silently. The fail-closed guarantee is structurally broken at the boundary. |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| scripts/verify-pins.sh | 110 | `[[ "${pub_date}" > "${CUTOFF}" ]]` with second-precision CUTOFF vs millisecond pub_date | BLOCKER | Verifier fails open at cutoff boundary; CR-01 |
| scripts/resolve-versions.sh | 99 | `[[ "$PUB_TIME" < "$CUTOFF" ]]` — same flaw in resolver selection | BLOCKER | May select or reject versions incorrectly at boundary; CR-01 |
| scripts/resolve-versions.sh | 127, 149 | jq `.value <= $cutoff` — jq string `<=` is also lexicographic | BLOCKER | Same flaw in npm registry version selection; CR-01 |
| scripts/build-and-lock.sh | 62 | `eval "$(bash ... resolve-versions.sh ...)"` — eval of registry-controlled output | WARNING | CR-02: registry-returned version strings not validated against allowlist before eval; potential code injection if registry is compromised |
| Dockerfile | 54 | `npm ls -g --json --depth=Infinity > /versions-npm.json && govulncheck --version` | WARNING | WR-01: npm ls exits non-zero on peer/missing deps; no `|| true`; build fails without capturing JSON |
| scripts/verify-pins.sh | 185 | `if has("version") then ... else empty end` — silently drops unresolved/missing deps | WARNING | WR-02: nodes with `"missing": true` skipped; fail-closed contract incomplete |

No TBD/FIXME/XXX debt markers found in any phase file.

### Human Verification Required

None — all remaining verification items can be assessed programmatically or by code inspection. The cache-bust guarantee (Success Criterion #2) requires a live podman environment to run test-cache-bust.sh, but the script design and the ARG ordering in the Dockerfile can be verified statically. The code review (01-REVIEW.md) by a human reviewer already assessed these issues.

### Gaps Summary

**One blocker** prevents the PIN-07 supply-chain guarantee from being genuine:

**CR-01 — Lexicographic timestamp comparison fails open at cutoff boundary.** Both `scripts/verify-pins.sh` (line 110) and `scripts/resolve-versions.sh` (lines 99, 127, 149) use bash/jq string comparison against the cutoff `${COOLDOWN_DATE}T23:59:59Z`. npm registry timestamps carry millisecond precision. Because ASCII dot (`.`, 0x2E) sorts before `Z` (0x5A), any timestamp in the window `23:59:59.000Z`–`23:59:59.999Z` on the cutoff day compares lexicographically as **less than** the cutoff string, making the verifier pass the package as compliant when it is not.

The bug was identified in 01-REVIEW.md (CR-01) but was not fixed before the phase was submitted. The existing `test-pin-held.sh` does not exercise this case — its seeded violation is published 2026-06-11 (far from the boundary). The lock file produced from the actual build is not affected (all packages were published 6+ hours before the cutoff boundary), but the verifier's structural guarantee for future builds is broken.

**Fix required:** Use exclusive next-day-midnight bound `${NEXT_DAY}T00:00:00.000Z` (computed via python3), or convert timestamps to epoch seconds via python3 before comparing. Apply consistently in resolver, jq selects, and verifier. Add a boundary-window test case.

**Additional non-blocking issues noted:** CR-02 (eval of registry output without allowlist validation), WR-01 (npm ls non-zero exit breaks Dockerfile build), WR-02 (unresolved transitive deps silently dropped by verifier). These are WARNINGS from the code review; they degrade robustness and security posture but the primary blocker is CR-01.

---

_Verified: 2026-06-14T00:00:00Z_
_Verifier: Claude (gsd-verifier)_
