---
phase: 01-dockerfile-and-supply-chain-pinning
reviewed: 2026-06-14T00:00:00Z
depth: standard
files_reviewed: 6
files_reviewed_list:
  - scripts/build-and-lock.sh
  - scripts/resolve-versions.sh
  - scripts/verify-pins.sh
  - tests/test-cache-bust.sh
  - tests/test-pin-held.sh
  - Dockerfile
findings:
  critical: 0
  warning: 4
  info: 3
  total: 7
status: issues_found
---

# Phase 01: Code Review Report

**Reviewed:** 2026-06-14T00:00:00Z
**Depth:** standard
**Status:** issues_found

## Summary

This is a re-review after gap-closure plan 01-03. All four prior findings claimed as
addressed are genuinely resolved:

- **CR-01 (lexicographic cutoff fail-open) — RESOLVED.** Both the resolver and the verifier
  now compute an exclusive next-day-midnight bound `CUTOFF_EXCL="${NEXT_DAY}T00:00:00.000Z"`
  via python3 and compare against it. I verified the boundary algebra against the actual
  `Z`-suffixed UTC timestamps that npm and the Go proxy emit: a cutoff-day last-sub-second
  value (`...T23:59:59.500Z`) sorts strictly below `CUTOFF_EXCL` (allowed), a next-day value
  (`...T00:00:00.500Z`) and an exact-midnight value both sort `>=` (rejected), and the no-ms
  next-day form `...T00:00:00Z` is also correctly rejected because `Z` (0x5A) > `.` (0x2E).
  The fix is correct for all timestamp shapes the two registries actually produce.

- **CR-02 (eval of registry-controlled output) — RESOLVED.** `eval` is gone. The resolver
  output is parsed with `IFS='=' read -r key val`, keys are checked against a closed
  allowlist (unknown keys are a hard error), values are validated against strict patterns,
  and assignment is via `printf -v` (no shell evaluation). I confirmed injection payloads
  like `1.0.0; rm -rf /` and `$(whoami)` are rejected by the version regex.

- **WR-01 (npm ls JSON guard) — RESOLVED.** `Dockerfile:59` now wraps `npm ls` in
  `{ ...; || true; }`, then validates with `jq empty` before writing the govulncheck snapshot.

- **WR-02 (missing/invalid transitive nodes surfaced) — PARTIALLY RESOLVED.** The flatten
  function now emits a `__MISSING__` sentinel for `missing == true or invalid == true`
  nodes and the verifier loop counts each as a violation. However the jq `if has("version")`
  branch is checked *before* the `invalid`/`missing` branch, so an `invalid: true` node that
  *also* carries a `version` field (npm's representation of a version that fails to satisfy
  its required range) takes the version branch and is verified by date only — its invalid
  status is never surfaced. The current real snapshot has zero such nodes, so this is latent,
  not active. See WR-01 below.

No new BLOCKER-class defects were introduced by the fixes. Four carry-over WARNINGs from the
prior review remain (they were out of the 01-03 gap-closure scope), plus one latent gap in
the WR-02 fix itself. None are fail-open in the current data.

## Warnings

### WR-01: WR-02 fix misses `invalid` nodes that also carry a `version`

**File:** `scripts/verify-pins.sh:218-222`
**Issue:** The flatten precedence is `if has("version") then ... elif (.missing == true or
.invalid == true) then "__MISSING__" else empty`. Because `has("version")` is tested first,
a node shaped `{ "invalid": true, "version": "9.9.9" }` emits `9.9.9` and is checked only for
publish date — the `invalid` flag is silently dropped. npm sets `invalid` (with the
installed version still present) when an installed dep does *not* satisfy its required
semver range, which is precisely a pin-integrity signal a fail-closed verifier should
surface. I confirmed with a synthetic snapshot that `invalid-pkg` with a version present
emits its version, not the sentinel. The current real `versions-npm.json` has no such nodes,
so this does not fail open today, but the WR-02 fix does not fully close the gap it targeted.
**Fix:** Test the invalid/missing condition before (or in addition to) the version branch:

```jq
(if (.missing == true or .invalid == true) then "\($pkg)\t__MISSING__"
 elif has("version") then "\($pkg)\t\(.version)"
 else empty end),
```

### WR-02: npm `--before` bound (Dockerfile) is inconsistent with the new CUTOFF_EXCL bound

**File:** `Dockerfile:37,42` vs `scripts/resolve-versions.sh:88` / `scripts/verify-pins.sh:115`
**Issue:** This is the prior WR-05, and the CR-01 fix widened the gap rather than closing it.
The resolver and verifier now treat the whole cutoff day inclusively, accepting publish
times up to `T23:59:59.999Z` (anything `< NEXT_DAY T00:00:00.000Z`). The Dockerfile still
pins transitive deps with `npm install --before="${COOLDOWN_DATE}T23:59:59Z"`, which selects
versions published strictly before `T23:59:59Z`. A top-level version the resolver selects in
the `(T23:59:59.000Z, T23:59:59.999Z]` window — now explicitly allowed by CUTOFF_EXCL — would
be refused at install time by `--before` ("no matching version"), producing a
non-deterministic build break near the day boundary. The resolver, Dockerfile, and verifier
should share one bound.
**Fix:** Use the exclusive next-day-midnight bound in the Dockerfile too. Pass `NEXT_DAY`
(or compute it from `COOLDOWN_DATE`) as a build arg and use
`--before="${NEXT_DAY}T00:00:00Z"`, matching `CUTOFF_EXCL`. Update the Step 4/5 comments,
which still describe the `T23:59:59Z` "inclusive end-of-day" rationale.

### WR-03: Top-level npm registry failure is counted as two violations and skips CHECKED

**File:** `scripts/verify-pins.sh:155-160,128-136,197-198`
**Issue:** Carry-over from prior WR-03/WR-04 (not in 01-03 scope). On a network failure for a
top-level npm package, `npm_publish_date` increments `VIOLATIONS` and returns an empty
string; `check_date` then sees the empty `pub_date`, increments `VIOLATIONS` again, and
returns early *before* incrementing `CHECKED`. One failure is reported as two violations, and
the `CHECKED` total disagrees with `TRANSITIVE_COUNT` whenever any date was missing. The
pipeline still fails closed (correct), but the audit count printed by a security gate is
wrong, which will mislead triage.
**Fix:** Make `check_date` the single place that classifies empty/missing dates (remove the
`VIOLATIONS` increment from `npm_publish_date`), and move the `CHECKED` increment to the top
of `check_date` so every examined package is counted regardless of outcome.

### WR-04: Cache-bust test defaults to PASS when it cannot locate the dnf layer marker

**File:** `tests/test-cache-bust.sh:105-132`
**Issue:** Carry-over from prior WR-06 (not in 01-03 scope). The failure condition is only
triggered when a `CACHED`/`Using cache` marker appears within two lines of a line matching
`dnf update` (`grep -A2 -iE 'dnf update'`). If podman's output places the cache marker
elsewhere, reworded the step header, or used BuildKit-style output, control falls through to
the `else` branch and the script unconditionally prints `PASS` at line 130 without ever
confirming the dnf layer ran fresh. The test asserts a negative via a fragile string-
proximity heuristic and defaults to PASS on no-match, so a genuinely broken cache-bust can
go undetected.
**Fix:** Make the assertion deterministic — emit a unique build-time marker
(`RUN echo "$COOLDOWN_DATE" > /cooldown-marker`) or capture the dnf layer image ID from each
build and assert they differ, defaulting to FAIL when cache state cannot be determined.

## Info

### IN-01: Resolver exit status is not propagated through process substitution

**File:** `scripts/build-and-lock.sh:71-95`
**Issue:** The new (CR-02) parse loop consumes the resolver via
`done < <(bash "${SCRIPT_DIR}/resolve-versions.sh" ...)`. Process substitution exit codes are
not captured by the `while` loop and are not caught by `set -euo pipefail`, so a resolver
that exits non-zero after emitting partial output would be invisible to the caller. In
practice the resolver emits all four KEY=VALUE lines only at the very end (lines 190-193,
after all network work), so a mid-run failure leaves the variables unset and the post-loop
empty-var check (lines 99-104) catches it. The guard is adequate today but depends on that
emit-at-end ordering; a future refactor that interleaves emission with work would reintroduce
a silent partial-success path.
**Fix:** Capture resolver output to a variable first and check `$?` explicitly, then parse:
`resolver_out=$(bash .../resolve-versions.sh ...) || { echo "ERROR: resolver failed" >&2; exit 1; }`
and feed `resolver_out` into the parse loop via a here-string.

### IN-02: Theoretical timezone-offset timestamp would break the lexicographic compare

**File:** `scripts/verify-pins.sh:140` / `scripts/resolve-versions.sh:126,155,178`
**Issue:** The CUTOFF_EXCL comparison relies on all timestamps being `Z`-suffixed UTC. A
publish time expressed with a numeric offset (e.g. `2026-06-10T00:00:00.000+00:00`) would
mis-sort because `+` (0x2B) < `.` (0x2E), causing a next-day value to compare below
CUTOFF_EXCL (fail-open). Both registries (npm, proxy.golang.org) emit `Z` exclusively, so
this is not reachable with the current data sources; noting it because the correctness of the
whole PIN-07 guarantee rests on the `Z`-only assumption being permanent. A one-line guard
that rejects any publish date not matching `...Z$` would make the assumption explicit and
fail-closed.

### IN-03: Test prerequisite failures print `SKIP:` but exit 1

**File:** `tests/test-pin-held.sh:49-58`
**Issue:** Carry-over from prior IN-05. When `versions.lock`/`versions-npm.json` are absent,
the messages say `SKIP:` but the script `exit 1`s. A CI harness keying on exit code treats a
missing lock as a hard failure, not a skip. Either adopt a skip convention (exit 77) or
reword to "FAIL" to match the exit code. (Note: for this test, treating a missing lock as a
hard failure may be the intended posture — in which case only the wording needs fixing.)

---

_Reviewed: 2026-06-14T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
