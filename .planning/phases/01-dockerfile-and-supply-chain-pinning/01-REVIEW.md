---
phase: 01-dockerfile-and-supply-chain-pinning
reviewed: 2026-06-14T00:00:00Z
depth: standard
files_reviewed: 7
files_reviewed_list:
  - scripts/resolve-versions.sh
  - scripts/build-and-lock.sh
  - scripts/verify-pins.sh
  - Dockerfile
  - .dockerignore
  - tests/test-cache-bust.sh
  - tests/test-pin-held.sh
findings:
  critical: 2
  warning: 6
  info: 5
  total: 13
status: issues_found
---

# Phase 01: Code Review Report

**Reviewed:** 2026-06-14T00:00:00Z
**Depth:** standard
**Files Reviewed:** 7
**Status:** issues_found

## Summary

This phase implements a supply-chain version-pinning pipeline in bash + a Dockerfile:
a cooldown resolver, an end-to-end build/lock driver, a fail-closed pin verifier, and
two tests. The overall structure is sound and the fail-closed posture is mostly
well-implemented (input validation, `set -euo pipefail`, explicit `|| exit 1` guards).

However, the core correctness guarantee of the whole pipeline — "no package published
after the cooldown cutoff is ever accepted" — is undermined by a **lexicographic
timestamp comparison bug** that allows packages published in the last second of the
cutoff day to slip through both the resolver and the fail-closed verifier. Because the
verifier is the last line of defense (PIN-07) and this is a fail-OPEN condition, it is a
BLOCKER. A second BLOCKER concerns `eval` of registry-controlled data in a project whose
explicit threat model is supply-chain compromise.

There are also several robustness gaps: `npm ls` exit-code handling in the Dockerfile,
missing/unresolved transitive deps silently dropped by the verifier's flattening, and
double-counting in violation accounting.

## Critical Issues

### CR-01: Lexicographic timestamp comparison fails open at the cutoff boundary

**File:** `scripts/verify-pins.sh:90,110` and `scripts/resolve-versions.sh:70,99`
**Issue:** The cutoff is constructed as `${COOLDOWN_DATE}T23:59:59Z` (second precision, no
fractional seconds), and publish dates are compared against it with bash string operators
`<` / `>`. npm registry timestamps carry millisecond precision (e.g.
`2026-06-11T00:48:28.454Z`). Lexicographically, the `.` character (0x2E) sorts *before*
`Z` (0x5A), so any timestamp of the form `...T23:59:59.NNNZ` compares as **less than**
`...T23:59:59Z`:

```
[[ "2026-06-09T23:59:59.500Z" < "2026-06-09T23:59:59Z" ]]   # => TRUE
```

Consequence: a package published at any time in the half-open window
`(23:59:59.000Z, 23:59:59.999Z]` on the cutoff day is treated as **on or before** the
cutoff by both:
- the resolver (`resolve-versions.sh:99`, the `<=` selection logic), and
- the verifier (`verify-pins.sh:110`, the `pub_date > CUTOFF` violation test).

This is a genuine **fail-open** in the security-critical PIN-07 verifier: a post-cutoff
package within that 1-second window passes verification. The existing `test-pin-held.sh`
does not catch it because its seeded version (`1.4.4 @ 00:48Z`) is far from the boundary.

**Fix:** Compare on parsed instants, not raw strings. Make the cutoff inclusive of the
whole day at full precision, or normalize both sides. Example using a true end-of-day
upper bound that no `T23:59:59.NNNZ` value can exceed:

```bash
# Use a strict next-day-midnight exclusive bound instead of T23:59:59Z.
CUTOFF_EXCL="${NEXT_DAY}T00:00:00.000Z"   # NEXT_DAY = COOLDOWN_DATE + 1 day (compute in python3)
# violation when pub_date >= CUTOFF_EXCL
```

Or compare numerically via epoch seconds in python3/jq rather than lexicographically:

```bash
python3 - "$pub_date" "$CUTOFF" <<'PY'
import sys, datetime as d
p = d.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00"))
c = d.datetime.fromisoformat(sys.argv[2].replace("Z","+00:00"))
sys.exit(0 if p <= c else 1)
PY
```

The jq selects in `resolve-versions.sh:127,149` (`.value <= $cutoff`) have the identical
flaw and must be fixed the same way (jq string `<=` is also lexicographic).

### CR-02: `eval` of registry-controlled output in a supply-chain threat model

**File:** `scripts/build-and-lock.sh:62`
**Issue:** `eval "$(bash "${SCRIPT_DIR}/resolve-versions.sh" ...)"` executes the resolver's
stdout as shell code. That stdout consists of `KEY=VALUE` lines whose VALUEs are version
strings taken verbatim from `registry.npmjs.org` and `proxy.golang.org` responses
(`resolve-versions.sh:162-164`). The whole point of this project is to defend against a
compromised/poisoned upstream supply chain. If a registry returns a crafted version key
(e.g. a `.key` containing `$(...)`, backticks, or `; cmd`), `eval` runs it on the build
host. The values are never validated against a strict semver/tag allowlist before being
emitted or eval'd.

**Fix:** Do not `eval` untrusted output. Either (a) validate each emitted value against a
strict pattern in the resolver before printing, or (b) parse the KEY=VALUE pairs in the
consumer without `eval`:

```bash
while IFS='=' read -r key val; do
  case "$key" in
    COOLDOWN_DATE|GOVULNCHECK_VERSION|GSD_CORE_VERSION|CLAUDE_CODE_VERSION)
      [[ "$val" =~ ^[A-Za-z0-9._+@/-]+$ ]] || { echo "ERROR: bad $key" >&2; exit 1; }
      printf -v "$key" '%s' "$val" ;;
  esac
done < <(bash "${SCRIPT_DIR}/resolve-versions.sh" --cooldown-days "${COOLDOWN_DAYS}")
```

Also add a strict validation gate in the resolver itself (`resolve-versions.sh`) so a
hostile registry value can never be emitted.

## Warnings

### WR-01: `npm ls -g --json` exits non-zero on extraneous/peer/missing deps, failing the build

**File:** `Dockerfile:54`
**Issue:** `npm ls -g --json --depth=Infinity > /versions-npm.json && govulncheck --version ...`
`npm ls` returns a non-zero exit code whenever the global tree has any extraneous,
missing, invalid, or unmet-peer dependency — even though it still writes valid JSON to
stdout. Because each Dockerfile `RUN` runs under `sh -c` (errexit on the final command's
status), a non-zero `npm ls` fails the build, and the `&&` means `govulncheck --version`
never runs and the snapshot/govulncheck files may be incomplete. Global installs of
npm packages with peer deps frequently trip this.

**Fix:** Capture the JSON regardless of `npm ls` exit status, then validate it explicitly:

```dockerfile
RUN { npm ls -g --json --depth=Infinity > /versions-npm.json || true; } && \
    jq empty /versions-npm.json && \
    govulncheck --version > /versions-govulncheck.txt
```

### WR-02: Verifier silently drops missing/unresolved transitive deps

**File:** `scripts/verify-pins.sh:180-188`
**Issue:** The `allpkgs` flattening only emits a pair when a node `has("version")`. `npm ls`
marks unresolved deps with `"missing": true` / `"invalid": true` and no `version`. Those
nodes are silently skipped, so a dependency that npm could not pin is not reported as a
problem by the fail-closed verifier. For a tool whose contract is "verify what npm
ACTUALLY resolved" (comment at line 176), an unresolved dep is exactly the kind of
uncertainty that should fail closed.

**Fix:** Detect nodes that are dependencies but lack a version and treat them as
violations (or at least surface them), e.g. emit a sentinel for `has("missing") or
has("invalid")` branches and increment `VIOLATIONS` on encountering one.

### WR-03: Double-counted violation on top-level npm registry failure

**File:** `scripts/verify-pins.sh:119-135,167-168`
**Issue:** When `npm_publish_date` hits a network failure it increments `VIOLATIONS` itself
(line 127) and then echoes an empty string. The caller passes that empty result to
`check_date` (line 168), which sees an empty `pub_date` and increments `VIOLATIONS`
*again* (line 105). One failure counts as two violations. The pipeline still fails closed
(good), but the reported count and the "FAIL: N pin violation(s)" message are wrong, which
will confuse anyone triaging. It also asymmetrically does NOT increment `CHECKED` for the
same case, so totals are internally inconsistent.

**Fix:** Have `npm_publish_date` not mutate `VIOLATIONS`; let `check_date` be the single
place that classifies empty/missing dates. Or signal the network failure distinctly so it
is counted once.

### WR-04: `CHECKED` counter undercounts; reported totals are misleading

**File:** `scripts/verify-pins.sh:98-115,226`
**Issue:** `check_date` increments `CHECKED` only on the success path (line 114) and returns
early *before* incrementing it on the empty/missing-date path (line 103-107). The final
summary "Checked ${CHECKED} packages total ... + ${TRANSITIVE_COUNT} transitive"
therefore disagrees with `TRANSITIVE_COUNT` (which is incremented unconditionally at line
221) whenever any package had a missing date. This is a reporting/observability defect on
the audit output of a security gate.

**Fix:** Increment `CHECKED` once at function entry for every package examined, regardless
of outcome.

### WR-05: npm `--before` (strictly-before) vs resolver `<=` (inclusive) can disagree on the boundary

**File:** `Dockerfile:37,42` vs `scripts/resolve-versions.sh:70`
**Issue:** The resolver selects the latest version with `publish <= COOLDOWN_DATE T23:59:59Z`
(inclusive). The Dockerfile pins transitive deps with `npm install --before="...T23:59:59Z"`.
npm's `--before` is documented as selecting versions published *strictly before* the given
time. For a top-level package published *exactly at or within* the cutoff boundary, the
resolver may pick a version that `--before` then refuses to install (npm errors "no
matching version"), breaking the build non-deterministically near the boundary. This is
the same class of boundary ambiguity as CR-01 and should be reconciled to a single,
clearly-defined inclusive/exclusive rule across resolver, Dockerfile, and verifier.

**Fix:** Standardize on one bound. If "inclusive of the whole cutoff day" is intended, use
`--before="${NEXT_DAY}T00:00:00Z"` (exclusive next-day-midnight) everywhere, and apply the
same bound in the resolver and verifier comparisons.

### WR-06: Cache-bust test can produce a false PASS

**File:** `tests/test-cache-bust.sh:105-127`
**Issue:** The assertion logic only fails if a CACHED marker appears within 2 lines after a
line matching `dnf update` (`grep -A2 -iE 'dnf update'`). If podman's output format places
the `CACHED`/`Using cache` marker more than 2 lines away, on a differently-worded step
header, or interleaves BuildKit-style output, the test falls through to the `else` branch
and then unconditionally prints `PASS` at line 130 — even though it never actually
confirmed the dnf layer ran fresh. The test asserts a negative ("not cached") by a fragile
string-proximity heuristic and defaults to PASS on no-match. A broken cache-bust could go
undetected.

**Fix:** Make the test deterministic: capture the dnf layer's image/layer ID (or a unique
build-time marker such as `RUN echo "$COOLDOWN_DATE" > /cooldown-marker`) from each build
and assert the layer hashes differ, rather than grepping human-readable build logs. Default
to FAIL on inability to determine cache state.

## Info

### IN-01: `eval`-sourced vars assumed set but only checked after use in logging

**File:** `scripts/build-and-lock.sh:62-75`
**Issue:** Lines 64-67 echo `${COOLDOWN_DATE}` etc. *before* the non-empty validation loop at
lines 70-75. With `set -u`, if `eval` produced nothing, line 64 aborts with an unbound
variable error before the friendly validation message can fire. Order the validation before
the logging for a clearer failure.

### IN-02: Resolver does not filter Go pseudo-versions / pre-releases

**File:** `scripts/resolve-versions.sh:85-106`
**Issue:** The Go proxy `@v/list` can include pseudo-versions and pre-release tags. The
resolver selects purely by latest publish time `<= CUTOFF` with no filter, so a pre-release
or pseudo-version could be selected as the govulncheck pin if it happens to be the
newest-before-cutoff. Consider restricting to `^v[0-9]+\.[0-9]+\.[0-9]+$` release tags.

### IN-03: Per-tag `.info` fetch is unbounded and uncached

**File:** `scripts/resolve-versions.sh:85-106`
**Issue:** The loop issues one network request per Go tag with no cap and no caching. Not a
correctness bug, but on a large tag list it is slow and brittle to transient network
errors (each `WARNING` is swallowed). Acceptable for now; noted for robustness.

### IN-04: `.dockerignore` `*.lock` excludes intent is fine but masks a foot-gun

**File:** `.dockerignore:8`
**Issue:** `*.lock` excludes `versions.lock` from build context (correct — it's an output).
Worth a one-line comment that this also excludes any future legitimately-needed `*.lock`
inputs (e.g. a committed `package-lock.json`) should the install strategy change, per the
CLAUDE.md "Committing package-lock.json" alternative.

### IN-05: Test prerequisite failures use `exit 1` but message says `SKIP`

**File:** `tests/test-pin-held.sh:40-49`
**Issue:** The messages say `SKIP:` but the script `exit 1`s (a failure, not a skip). A CI
harness keying on exit code will treat a missing `versions.lock` as a test failure rather
than a skip. Either use a skip exit convention (e.g. exit 77 for autotools-style skip) or
change the wording to reflect that absence of the lock is a hard failure.

---

_Reviewed: 2026-06-14T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
