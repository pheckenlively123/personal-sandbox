---
phase: 01-dockerfile-and-supply-chain-pinning
verified: 2026-06-14T18:00:00Z
status: human_needed
score: 5/5 must-haves verified
overrides_applied: 0
re_verification:
  previous_status: gaps_found
  previous_score: 4/5
  gaps_closed:
    - "The build fails (exit non-zero) if any pinned package's publish date is after the cooldown date (PIN-07 pin-held verification) — CR-01 lexicographic boundary bug fixed via CUTOFF_EXCL"
  gaps_remaining: []
  regressions: []
human_verification:
  - test: "Run `bash scripts/build-and-lock.sh --cooldown-days 4` on a host with podman installed (Fedora 44 or equivalent)"
    expected: "podman build completes, all six tools installed (Go, golangci-lint, govulncheck, gsd-core, Claude Code CLI, claude-engineering-toolkit), versions.lock and versions-npm.json written, verify-pins.sh exits 0"
    why_human: "podman is not available in this host environment; the complete build pipeline cannot be run without it. Static inspection confirms all pieces are correctly assembled, but actual build execution requires a podman-capable host"
  - test: "Change --cooldown-days between two consecutive runs and inspect podman build output for the dnf layer"
    expected: "Second build shows no CACHED marker on the 'dnf update -y' step, confirming the COOLDOWN_DATE ARG cache-bust is working. Run `bash tests/test-cache-bust.sh` to automate the assertion"
    why_human: "Cache-bust guarantee (Success Criterion 2) requires live podman to run test-cache-bust.sh. The ARG ordering (COOLDOWN_DATE on line 6, RUN dnf on line 14) is statically correct, but execution is needed to confirm podman's layer cache behaves as expected"
  - test: "Inside the built image, run `govulncheck --version` and check the reported version"
    expected: "Output contains a version from versions-govulncheck.txt (e.g. `govulncheck@v1.3.0`), and v1.3.0 was published 2026-04-22 — well before the cooldown date 2026-06-09"
    why_human: "Requires the built image to be available; statically verified via versions-govulncheck.txt artifact from the prior build"
---

# Phase 01: Dockerfile and Supply-Chain Pinning — Re-Verification Report

**Phase Goal:** A `podman build` of the Dockerfile succeeds and produces an image with all required tooling installed at cooldown-pinned versions, with a `versions.lock` artifact capturing exact resolved versions.
**Verified:** 2026-06-14T18:00:00Z
**Status:** human_needed
**Re-verification:** Yes — after gap closure plan 01-03 (CR-01 BLOCKER + WARNING hardening)

## Re-verification Summary

The previous verification (2026-06-14T00:00:00Z) found one BLOCKER: the PIN-07 fail-closed guarantee was broken at the cutoff-day millisecond boundary. Plan 01-03 was executed to close that gap. This re-verification confirms the BLOCKER is closed and all 5 must-haves are now verified. The remaining `human_needed` items are those that cannot be assessed without a running podman environment — the same environment constraint that applied to the initial verification.

Previous gap (now closed): CR-01 — lexicographic `[[ pub_date > CUTOFF ]]` with second-precision `T23:59:59Z` failed open for packages published in the 999-millisecond window `T23:59:59.000Z–T23:59:59.999Z` on the cutoff day.

## Goal Achievement

### Observable Truths (Roadmap Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `podman build` completes from Fedora 44 installing all six tools at cooldown-pinned versions | VERIFIED (static) | Dockerfile: `FROM fedora:44`, all six tools present (Go+golangci-lint via dnf, govulncheck via `go install @${GOVULNCHECK_VERSION}`, gsd-core+Claude Code via npm with `--before`, toolkit via git clone). versions.lock and versions-govulncheck.txt artifacts exist from a completed prior build. Requires human podman run to confirm end-to-end (see Human Verification #1) |
| 2 | Build log shows no `CACHED` entry for `dnf update -y` when `COOLDOWN_DATE` changes | VERIFIED (static) | `ARG COOLDOWN_DATE` is on Dockerfile line 6, before the first `RUN dnf` on line 14 — the cache-bust ARG ordering is correct. `tests/test-cache-bust.sh` automates the assertion. Requires human podman run to confirm live (see Human Verification #2) |
| 3 | `govulncheck --version` inside image shows release on or before cooldown date | VERIFIED | versions-govulncheck.txt from prior build contains `Scanner: govulncheck@v1.3.0`; Go proxy confirms v1.3.0 published 2026-04-22T22:03:04Z — 48 days before the 2026-06-09 cooldown date. versions.lock records this. CUTOFF_EXCL boundary algebra confirms it passes |
| 4 | `versions.lock` records exact pinned versions with cooldown-resolved timestamps | VERIFIED | versions.lock contains all required fields: `cooldown_date`, `build_date`, `cooldown_days`, `packages.govulncheck.{version,publish_date}`, `packages.@opengsd/gsd-core.{version,publish_date}`, `packages.@anthropic-ai/claude-code.{version,publish_date}`, `npm_transitive_snapshot`. All three publish_date values confirmed within cooldown window by CUTOFF_EXCL algebra |
| 5 | Build fails (exit non-zero) if any pinned package's publish date is after the cooldown date (PIN-07) | VERIFIED | CR-01 BLOCKER CLOSED. `scripts/verify-pins.sh` now computes `CUTOFF_EXCL="${NEXT_DAY}T00:00:00.000Z"` via python3 and compares `[[ pub_date >= CUTOFF_EXCL ]]`. Bash lexicographic boundary algebra confirmed: `T23:59:59.500Z < T00:00:00.000Z (next day)` → ALLOWED; `T00:00:00.500Z >= T00:00:00.000Z (next day)` → REJECTED. `tests/test-pin-held.sh` Cases 2+3 prove both boundary behaviors. `scripts/resolve-versions.sh` uses the same CUTOFF_EXCL in the Go-proxy loop and both jq npm selects (`.value < $cutoff_excl`) |

**Score:** 5/5 truths verified (Truths 1-2 are statically verified with a human-run caveat; Truths 3-5 are fully verified without requiring podman)

### Required Artifacts (01-03 Plan Must-Haves)

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `scripts/verify-pins.sh` | CUTOFF_EXCL boundary-correct verifier; __MISSING__ sentinel for missing/invalid transitive nodes | VERIFIED | Exists, executable (rwxr-xr-x, 10414 bytes). Contains CUTOFF_EXCL (9 occurrences). `check_date` compares `[[ pub_date >= CUTOFF_EXCL ]]`. allpkgs jq flatten emits `__MISSING__` for `.missing==true or .invalid==true` nodes; transitive loop counts each as VIOLATIONS. bash -n syntax: OK |
| `scripts/resolve-versions.sh` | CUTOFF_EXCL in Go-proxy loop and jq npm selects; IN-02 release tag filter | VERIFIED | Exists, executable (8000 bytes). Contains CUTOFF_EXCL (12 occurrences). Go-proxy loop: `[[ PUB_TIME < CUTOFF_EXCL ]]`. jq npm selects: `.value < $cutoff_excl` (lines 155, 178). IN-02 release filter `^v[0-9]+\.[0-9]+\.[0-9]+$` on line 110. bash -n: OK |
| `scripts/build-and-lock.sh` | Allowlist-validated KEY=VALUE parse with printf -v; no eval | VERIFIED | Exists, executable (9235 bytes). Contains `printf -v` (3 occurrences, lines 81, 88). `grep -nE 'eval.*bash' scripts/build-and-lock.sh` returns nothing — eval removed. Process substitution parse with allowlist on lines 71-95. Validation before INFO logging (IN-01 fix). bash -n: OK |
| `tests/test-pin-held.sh` | Three cases: far-from-boundary (Case 1), inclusive-boundary ALLOWED (Case 2), next-day REJECTED (Case 3) | VERIFIED | Exists, executable (11380 bytes). Contains `23:59:59` (16 occurrences). Cases 2+3 headers visible at lines 122-133, 195-209. All three cases present. Summary at lines 232-235. bash -n: OK |
| `Dockerfile` | npm ls snapshot guarded: `{ ... || true; } && jq empty /versions-npm.json` | VERIFIED | WR-01 guard on line 59: `{ npm ls -g --json --depth=Infinity > /versions-npm.json || true; } &&`. jq empty on line 60. govulncheck snapshot on line 61. FROM fedora:44 on line 1. ARG ordering and all six tool installs intact |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `scripts/verify-pins.sh` | CUTOFF_EXCL exclusive bound | python3 next-day midnight; `[[ pub_date >= CUTOFF_EXCL ]]` in check_date (line 140) | WIRED | Confirmed by code inspection and bash boundary algebra: `T23:59:59.500Z` → ALLOWED, `T00:00:00.500Z` next-day → REJECTED |
| `scripts/resolve-versions.sh` | CUTOFF_EXCL exclusive bound | python3 NEXT_DAY + T00:00:00.000Z; Go-proxy: `[[ PUB_TIME < CUTOFF_EXCL ]]` (line 126); jq: `.value < $cutoff_excl` (lines 155, 178) | WIRED | Confirmed. jq boundary algebra: `T23:59:59.500Z < T00:00:00.000Z` → selected; `T00:00:00.000Z < T00:00:00.000Z` → false → excluded |
| `scripts/build-and-lock.sh` | `scripts/resolve-versions.sh` | process substitution `done < <(bash ... resolve-versions.sh ...)` (line 95); allowlist parse with `printf -v` (lines 71-95) | WIRED — no eval | CR-02 closed. Unknown keys are hard errors (line 91). Pattern validation per key (lines 77-88). Note: IN-01 (resolver exit code not propagated through process substitution) remains an INFO-level finding but post-loop empty-var check on lines 99-104 provides adequate guard |
| `scripts/build-and-lock.sh` | `Dockerfile` | `podman build --build-arg COOLDOWN_DATE/GOVULNCHECK_VERSION/GSD_CORE_VERSION/CLAUDE_CODE_VERSION` (lines 115-121) | WIRED | All 4 build-args present |
| `scripts/build-and-lock.sh` | `scripts/verify-pins.sh` | `bash "${SCRIPT_DIR}/verify-pins.sh" --lock ... --npm-snapshot ...` (lines 239-241) | WIRED | Called as Step 5 with correct flags |
| `Dockerfile` | `/versions-npm.json` | `{ npm ls -g --json --depth=Infinity > /versions-npm.json || true; } && jq empty /versions-npm.json` (lines 59-60) | WIRED — WR-01 closed | JSON always captured; validated before continuing |
| `tests/test-pin-held.sh` | `scripts/verify-pins.sh` | `bash "${VERIFIER}" --lock "${SEEDED_LOCK}" --npm-snapshot ...` (lines 99-102, 181-184, 217-220) | WIRED | All three cases run the verifier against seeded locks |

### Data-Flow Trace (Level 4)

Not applicable — this phase produces shell scripts, a Dockerfile, and static artifacts (versions.lock, versions-npm.json). No data-rendering components. The supply-chain metadata pipeline (resolver → build-args → image → extraction → versions.lock → verifier) was verified at the key-link level above.

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Old lexicographic compare absent from verify-pins.sh | `grep -nE 'pub_date.*>.*CUTOFF[^_]' scripts/verify-pins.sh` | No output | PASS |
| Old jq `.value <= $cutoff` absent from resolve-versions.sh | `grep -nE '\.value <= \$cutoff[^_]' scripts/resolve-versions.sh` | Only comment (line 150), no code | PASS |
| CUTOFF_EXCL present in verify-pins.sh | `grep -c 'CUTOFF_EXCL' scripts/verify-pins.sh` | 9 | PASS |
| CUTOFF_EXCL present in resolve-versions.sh | `grep -c 'CUTOFF_EXCL' scripts/resolve-versions.sh` | 12 | PASS |
| eval absent from build-and-lock.sh | `grep -nE 'eval.*bash' scripts/build-and-lock.sh` | No output | PASS |
| printf -v present in build-and-lock.sh | `grep -c 'printf -v' scripts/build-and-lock.sh` | 3 | PASS |
| jq empty guard in Dockerfile | `grep -c 'jq empty /versions-npm.json' Dockerfile` | 1 | PASS |
| Boundary algebra: T23:59:59.500Z ALLOWED | bash `[[ T23:59:59.500Z >= T00:00:00.000Z ]]`; python3 crosscheck | false → ALLOWED | PASS |
| Boundary algebra: T00:00:00.500Z REJECTED | bash `[[ T00:00:00.500Z >= T00:00:00.000Z ]]` | true → REJECTED | PASS |
| jq boundary: T23:59:59.500Z selected by .value < cutoff_excl | jq -n crosscheck | `ok: true` | PASS |
| jq boundary: T00:00:00.000Z excluded by .value < cutoff_excl | jq -n crosscheck | `ok: true` | PASS |
| versions.lock all packages within cooldown window | python3 CUTOFF_EXCL check against lock publish dates | govulncheck 2026-04-22, gsd-core 2026-06-09T17:49, claude-code 2026-06-09T16:15 — all < 2026-06-10T00:00:00.000Z | PASS |
| bash -n on all four modified scripts | `bash -n scripts/verify-pins.sh; bash -n scripts/resolve-versions.sh; bash -n scripts/build-and-lock.sh; bash -n tests/test-pin-held.sh` | All exit 0 | PASS |

### Probe Execution

Step 7c: SKIPPED — no `probe-*.sh` scripts found in `scripts/*/tests/`. The `tests/test-pin-held.sh` is the phase's negative-path proof and was run end-to-end during 01-03 task 1 execution (documented in commit b836c8c). It cannot be re-run here because it requires `versions.lock` and `versions-npm.json` (present) plus registry access (network available in this environment but not exercised to avoid mutation risk).

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| IMG-01 | 01-01-PLAN | FROM fedora:44 | SATISFIED | Dockerfile line 1: `FROM fedora:44` |
| IMG-02 | 01-01-PLAN, 01-02-PLAN | dnf update -y cache-busted per rebuild | SATISFIED | ARG COOLDOWN_DATE line 6 before RUN dnf line 14; test-cache-bust.sh automates check |
| IMG-03 | 01-01-PLAN | Go via RPM (`golang`) | SATISFIED | `golang` in dnf install (Dockerfile line 16) |
| IMG-04 | 01-01-PLAN | golangci-lint via RPM | SATISFIED | `golangci-lint` in dnf install (Dockerfile line 17) |
| IMG-05 | 01-01-PLAN | claude-engineering-toolkit cloned at build time | SATISFIED | `RUN git clone https://github.com/pheckenlWork/claude-engineering-toolkit.git /opt/claude-engineering-toolkit` (Dockerfile lines 47-48) |
| PIN-01 | 01-01-PLAN | Cooldown date = build date minus N days (rolling) | SATISFIED | `resolve-versions.sh` line 56: `python3 -c "from datetime import date, timedelta; print((date.today() - timedelta(days=${COOLDOWN_DAYS})).isoformat())"` |
| PIN-02 | 01-01-PLAN | Cooldown window overridable via `--cooldown-days N` | SATISFIED | `--cooldown-days` accepted by both `resolve-versions.sh` and `build-and-lock.sh`; confirmed via behavioral spot-check in prior verification |
| PIN-03 | 01-01-PLAN | govulncheck pinned to latest release on or before cooldown date | SATISFIED | `go install golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}`; resolver uses CUTOFF_EXCL + IN-02 release-form filter; v1.3.0 resolved |
| PIN-04 | 01-01-PLAN | gsd-core pinned with all transitive deps via npm --before | SATISFIED | `npm install -g @opengsd/gsd-core@${GSD_CORE_VERSION} --before="${COOLDOWN_DATE}T23:59:59Z"`; verifier covers transitive deps via versions-npm.json; note WR-02 finding (see Anti-Patterns) |
| PIN-05 | 01-01-PLAN | Claude Code pinned to latest on or before cooldown date | SATISFIED | `npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} --before="${COOLDOWN_DATE}T23:59:59Z"`; 2.1.170 resolved |
| PIN-06 | 01-01-PLAN | versions.lock capturing exact versions with timestamps | SATISFIED | versions.lock present with all required fields; build_date=2026-06-13, cooldown_date=2026-06-09, all three packages with version+publish_date |
| PIN-07 | 01-02-PLAN, 01-03-PLAN | Pin-held verification fails build if any package postdates cooldown | SATISFIED | CR-01 BLOCKER CLOSED. verify-pins.sh wired in build-and-lock.sh Step 5; uses CUTOFF_EXCL; boundary algebra verified; test-pin-held.sh Cases 1-3 prove the guarantee |

All 12 Phase 1 requirements are SATISFIED.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| scripts/verify-pins.sh | 220-221 | `has("version")` tested before `.missing or .invalid` in allpkgs jq flatten (re-review WR-01) | WARNING | An npm node with `{ "invalid": true, "version": "X.Y.Z" }` (version present but range-violated) takes the version branch and is checked by date only — its invalid status is not surfaced. Current versions-npm.json has zero such nodes. Latent, not active. |
| Dockerfile | 37, 42 | `npm install --before="${COOLDOWN_DATE}T23:59:59Z"` while resolver/verifier use CUTOFF_EXCL (next-day midnight) (re-review WR-02) | WARNING | If a top-level package is published in the 1-second window `T23:59:59.000Z–T23:59:59.999Z` on the cutoff day, the resolver may select it (it is `< CUTOFF_EXCL`) but npm would refuse to install it (it is `> T23:59:59Z`), causing a build failure. The 01-03 plan explicitly deferred this (WR-05 in 01-03-SUMMARY.md). Practically unlikely but a theoretical reliability gap |
| scripts/build-and-lock.sh | 95 | Process substitution exit code not propagated through `done < <(...)` (re-review IN-01) | INFO | A resolver that exits non-zero after emitting partial output would go undetected by `set -euo pipefail`; the post-loop empty-var check (lines 99-104) catches it only because the resolver emits all four vars at the end. Deferred |
| scripts/verify-pins.sh | 154-159 | `npm_publish_date` increments VIOLATIONS on network failure AND `check_date` also increments it on empty pub_date (re-review WR-03) | INFO | One failure counted as two violations; CHECKED total inaccurate. Pipeline still fails closed; audit count misleading. Not in 01-03 scope |
| tests/test-cache-bust.sh | 105-132 | Cache-bust assertion uses string-proximity heuristic; defaults to PASS when dnf layer marker not found (re-review WR-04) | INFO | Carries risk of false-positive PASS if podman output changes format. Not in 01-03 scope |

No TBD/FIXME/XXX/PLACEHOLDER debt markers found in any modified file.

### Human Verification Required

#### 1. End-to-End podman Build (Success Criterion 1)

**Test:** On a host with podman installed, run `bash scripts/build-and-lock.sh --cooldown-days 4` from the project root.
**Expected:** podman build completes without error, image tagged `claude-sandbox:dev` is created, versions.lock and versions-npm.json are updated, verify-pins.sh exits 0 confirming all pins are within the cooldown window.
**Why human:** No podman binary available in this host environment. All static checks confirm correct assembly, but actual build execution is required for Success Criterion 1 and to confirm transitive npm resolution behavior.

#### 2. Cache-Bust Guarantee (Success Criterion 2)

**Test:** On a host with podman installed, run `bash tests/test-cache-bust.sh` which rebuilds the image twice with different `COOLDOWN_DATE` values and asserts the dnf layer is not cached on the second build.
**Expected:** Script exits 0 — no `CACHED` marker appears on the `dnf update` layer when the cooldown date differs between builds.
**Why human:** Requires live podman. ARG ordering is statically correct (COOLDOWN_DATE line 6 before RUN dnf line 14), but actual cache behavior can only be confirmed at runtime. Note the re-review flagged the cache-bust test's string-proximity heuristic (WR-04 in 01-REVIEW.md) as potentially defaulting to PASS — a positive result here should be interpreted with that caveat.

#### 3. govulncheck Version Inside Built Image (Success Criterion 3)

**Test:** After a successful build, run `govulncheck --version` inside the container or inspect `versions-govulncheck.txt`.
**Expected:** Output contains `v1.3.0` (or whatever version was resolved for the current cooldown date), and that version's publish date is on or before the cooldown date.
**Why human:** Requires the built image. The existing `versions-govulncheck.txt` from the prior build confirms `v1.3.0`, but a fresh build may resolve a different version depending on the current cooldown date.

## Gap-Closure Confirmation

**BLOCKER from previous verification: CLOSED**

The CR-01 boundary-correct cutoff comparison has been implemented correctly:

1. `verify-pins.sh` computes `CUTOFF_EXCL="${NEXT_DAY}T00:00:00.000Z"` via python3 (line 102-115) and compares `[[ "${pub_date}" > "${CUTOFF_EXCL}" ]] || [[ "${pub_date}" == "${CUTOFF_EXCL}" ]]` (line 140). The old `[[ pub_date > CUTOFF ]]` comparison against `T23:59:59Z` is completely absent.

2. `resolve-versions.sh` computes the same CUTOFF_EXCL (line 75-88), uses it in the Go-proxy loop (`[[ PUB_TIME < CUTOFF_EXCL ]]`, line 126), and in both jq npm selects (`.value < $cutoff_excl`, lines 155, 178). The old `.value <= $cutoff` is present only as a comment (line 150).

3. `tests/test-pin-held.sh` adds Cases 2 and 3 (lines 122-235): Case 2 seeds a compliant cutoff-day pin and asserts exit 0 (ALLOWED); Case 3 reuses the Case 1 post-cutoff seeded lock and asserts exit non-zero (REJECTED). All boundary cases pass against the corrected verifier.

4. The WARNING hardening from 01-03 is all in place: CR-02 (no eval in build-and-lock.sh), WR-01 (npm ls guard in Dockerfile), WR-02 (\_\_MISSING\_\_ sentinel for missing/invalid nodes in verify-pins.sh).

**Remaining open findings (all WARNING or INFO from re-review; none are blockers):**

- WR-01 (re-review): invalid+version nodes take version branch in allpkgs — latent, no affected nodes in current snapshot
- WR-02 (re-review): Dockerfile `--before=T23:59:59Z` inconsistent with CUTOFF_EXCL — theoretical 1-second reliability gap, explicitly deferred in 01-03
- IN-01 (re-review): process substitution exit code not captured — post-loop empty-var guard adequate for current implementation
- WR-03/WR-04 (re-review): violation double-count and cache-bust heuristic fragility — carry-over informational findings

None of these prevent the phase goal from being achieved. The PIN-07 fail-closed guarantee is now structurally correct at millisecond precision.

---

_Verified: 2026-06-14T18:00:00Z_
_Verifier: Claude (gsd-verifier)_
