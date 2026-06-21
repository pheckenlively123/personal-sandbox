# Testing Guidelines

This repo's tests are **bash scripts that prove a guard fails on tampered input**. There is no test runner and no CI; tests are invoked directly (`bash tests/<name>.sh`) or via `rebuild.sh` verbs. Every rule below is grounded in the existing scripts under `tests/` and `scripts/`. Follow them when adding or modifying tests.

## Core philosophy: prove the guard, not the happy path

- A test exists to prove a **guarantee holds closed**, not that the tool runs. `tests/test-pin-held.sh` seeds a *violating* pin and asserts the verifier **rejects** it — "A verifier that fails OPEN (exits 0 on a violation) defeats the PIN-07 guarantee."
- The headline assertion is always **negative-path**: tamper the input, then assert the guard produces a non-zero exit (or the documented failure verdict). A guard that only passes clean input is untested.
- Tie each test to its requirement/criterion ID in the file header comment: `PIN-07 / ROADMAP Success Criterion #5`, `IMG-02 / Criterion #2`, `D-10`. The ID is load-bearing — it states what the test defends.

## Rule 1 — Assert exact exit codes, never just "it ran"

- Capture the exit code explicitly and assert on it. The idiom: run with `|| VAR=$?` so `set -e` does not abort, then test the captured value.
  ```bash
  VERIFIER_EXIT=0
  bash "${VERIFIER}" --lock "${SEEDED_LOCK}" ... 2>&1 || VERIFIER_EXIT=$?
  if [[ "${VERIFIER_EXIT}" -eq 0 ]]; then echo "FAIL: ..."; exit 1; fi
  ```
- Distinguish exit codes by meaning. In `audit-plugins.sh`: `exit 124` = timeout = **HANG = always FAIL** (no exception), `exit 0` is necessary-but-not-sufficient for `MUST_FAIL_CLEAN`, any other non-zero is `UNEXPECTED`.
- The guard under test must itself **fail closed**: `verify-pins.sh` exits non-zero on missing files, malformed JSON, *and* registry query failure — "NEVER exits 0 on uncertainty." Test that posture too where relevant.

## Rule 2 — Seed tampered input in a tempdir; never mutate real artifacts

- Never edit `versions.lock`, `versions-npm.json`, the live policy, or any production image. Build the tampered copy in a fresh `mktemp -d` and point the tool at it via flags (`--lock`, `--npm-snapshot`).
  ```bash
  TMPDIR_SEEDED=$(mktemp -d)
  SEEDED_LOCK="${TMPDIR_SEEDED}/versions.lock"
  jq '.packages["@opengsd/gsd-core"].version = "1.4.4"' "${LOCK_FILE}" > "${SEEDED_LOCK}"
  ```
- **Always** register cleanup before the first mutation so it runs on every exit path:
  ```bash
  cleanup() { rm -rf "${TMPDIR_SEEDED}"; }
  trap cleanup EXIT
  ```
- For tests that must build/exec, use **throwaway, namespaced tags** that cannot clobber production, and `rmi` them in cleanup. `test-cache-bust.sh` uses `claude-sandbox-cache-test-a:test` and `claude-sandbox-cache-test-b:test` and never touches `claude-sandbox:dev`/`:latest`.
- Prefer host-side verification over touching the live sandbox. `verify-pins.sh` re-queries registries from the host rather than running anything inside the sandbox; NET-05 asserts only **deny posture** via `curl` (host→sandbox exec) and defers reachability proof to `./rebuild.sh login`.

## Rule 3 — `set -euo pipefail` and fail-closed prerequisites

- Every test starts with `set -euo pipefail` and resolves its own paths from `BASH_SOURCE`:
  ```bash
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
  ```
- Check prerequisites up front and exit non-zero with a `SKIP:`/`FAIL:` reason if inputs are absent (`test-pin-held.sh` requires a real `versions.lock`/`versions-npm.json` and an executable verifier). Do not silently no-op.
- Under `set -e`, guard arithmetic and `grep -c`: `grep -c` exits 1 on zero matches, so use `|| true` and a `${x:-0}` default — `audit-plugins.sh` does exactly this to avoid a spurious abort and warns against the double-counting `|| echo 0` form.

## Rule 4 — Boundary & regression cases tied to a fix ID

- For any off-by-one or comparison logic, add **three** cases like `test-pin-held.sh`: (1) far-from-boundary violation → REJECTED, (2) compliant pin at or before the cutoff → ALLOWED (proves the fix does not over-reject), (3) post-cutoff pin (next day or later) → REJECTED.
- Anchor regression cases to the bug's fix ID and explain the original defect in the header. CR-01: lexicographic compare against `T23:59:59Z` let `T23:59:59.500Z` sort *less* (`.` 0x2E < `Z` 0x5A) and pass silently; the fix compares against an **exclusive next-day-midnight** bound `CUTOFF_EXCL="${NEXT_DAY}T00:00:00.000Z"`. The test's job is to ensure that exact bug can never reappear.
- Comment *why* a value sits on the boundary, including the byte/precision reasoning when it is non-obvious — a future reader must not "simplify" the boundary back into the bug.
- In `test-pin-held.sh`, Case 2 seeds the real compliant gsd-core version from `versions.lock` and asserts the verifier allows it (confirming the fix does not over-reject legitimate pins). Case 3 reuses the Case 1 post-cutoff seeded lock (gsd-core 1.4.4, published 2026-06-11, which postdates the cooldown) and asserts rejection.

## Rule 5 — Expected-verdict framework with a hard-fail gate

For multi-case integration suites (`audit-plugins.sh`), use a static expected-verdict table and a violations counter:

- **Enumerate cases statically** with their expected verdict (`declare -A AGENTS`, `declare -A SKILLS`): 11 agents + 6 skills, each `MUST_SUCCEED` or `MUST_FAIL_CLEAN`. Static enumeration makes coverage auditable and missing cases visible.
- **Verdict semantics:**
  - `MUST_SUCCEED`: `exit 0` = PASS; any non-zero = `FAIL [UNEXPECTED]`.
  - `MUST_FAIL_CLEAN`: `exit 0` **alone is not a pass** — output must also match a network/MCP error pattern (`grep -qiE "40[13]|connection refused|...|mcp.*error"`). `exit 0` *without* the error = `FAIL [MISMATCH]`. A **non-zero** exit for `MUST_FAIL_CLEAN` is also `FAIL [UNEXPECTED]` — clean failure means `exit 0` with an error message, not a non-zero exit. There is **no WARN escape** (D-10).
  - `exit 124` (timeout) = `FAIL [HANG]` unconditionally.
  - Unknown expected value = `FAIL [CONFIG]` — fail closed on misconfiguration.
- **Hard-fail gate:** every FAIL increments `VIOLATIONS` and appends to `FAILED_PLUGINS`; the suite exits 1 iff `VIOLATIONS > 0`, listing every failed case. A "false PASS" from a swallowed error is itself a violation — `audit-plugins.sh` treats a failed `openshell logs` fetch as a telemetry violation rather than letting counts default to 0.
- Bound every external invocation with `--timeout 120` so a hang becomes a deterministic exit 124 rather than wedging the suite.

## Rule 6 — Output conventions

- Emit human progress/diagnostics to **stderr** (`>&2`); reserve stdout for the machine-readable result table where one exists (`audit-plugins.sh` prints the `| Plugin | ... |` markdown table to stdout).
- Use stable prefixes: `INFO:`, `PASS:`, `FAIL:`, `SKIP:`, and bracketed verdict tags (`PASS [OK]`, `FAIL [HANG]`, `FAIL [MISMATCH]`). On failure, print what was expected vs. observed and the seeded input so the failure is self-explanatory.
- On clean SIGINT/SIGTERM, exit with the conventional signal code and a clear message rather than a bare `set -e` abort (`trap '... exit 130' INT`, `... exit 143' TERM`).

## Rule 7 — Things tests must NOT do

- Do **not** evaluate or execute plugin/agent output — inspect exit codes and grep for error patterns only (`audit-plugins.sh`: "NEVER evals plugin output", T-04-07).
- Do **not** add a WARN/soft-pass tier; a mismatch is a hard failure.
- Do **not** widen egress or hit the open internet from a test beyond what the guard already permits (registry queries from the host are fine; in-sandbox network is deny-asserted only).
- Do **not** leave artifacts: temp dirs and throwaway image tags must be removed in a `trap cleanup EXIT`.

## Quick checklist for a new test

1. Header: name, requirement/fix ID, what failure mode it proves, "real artifacts NEVER mutated."
2. `set -euo pipefail`; resolve `SCRIPT_DIR`/`PROJECT_ROOT`; fail-closed prereq checks.
3. Seed tampered input in `mktemp -d`; `trap cleanup EXIT` before mutating.
4. Run the guard with `|| VAR=$?`; assert the **exact** expected exit code/verdict.
5. Add boundary + regression cases (compliant-pin allowed vs. post-cutoff rejected) tied to the relevant fix ID.
6. For suites: static expected-verdict table + `VIOLATIONS` hard-fail gate + `--timeout`/exit-124=HANG.
7. `PASS:`/`FAIL:` to stderr; non-zero exit on any failure.
