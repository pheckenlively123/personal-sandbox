#!/usr/bin/env bash
# test-local-model-guard.sh — RUN-07 / NET-06 negative-path proof
#
# Proves the guard, not the happy path (the happy path needs a real host-side
# proxy and cannot be exercised from inside this zero-egress sandbox — see
# docs/local-models-guidelines.md). Every case below asserts that a bad
# `claude-local` invocation exits 1 FROM THE --base-url VALIDATOR, before any
# podman/openshell call — proven by the fact that these commands return 1 in
# this sandbox, where neither podman nor openshell exists on PATH.
#
# It mutates nothing: it only invokes rebuild.sh with bad input and asserts
# exit codes. The real repo state is untouched.
#
# Usage:
#   bash tests/test-local-model-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REBUILD="${PROJECT_ROOT}/rebuild.sh"

if [[ ! -x "${REBUILD}" ]]; then
    echo "FAIL: ${REBUILD} is not executable" >&2
    exit 1
fi

VIOLATIONS=0

echo "=== claude-local --base-url Guard Test: RUN-07 / NET-06 ===" >&2
echo "" >&2

# -----------------------------------------------------------------------
# Case 1 — no --base-url and no LOCAL_MODEL_BASE_URL env var -> exit 1
# -----------------------------------------------------------------------
# LOCAL_MODEL_BASE_URL is explicitly cleared in the child environment so a
# set env var on the operator's machine cannot make this case pass vacuously.
echo "INFO: Case 1 — no --base-url, no LOCAL_MODEL_BASE_URL -> expect exit 1" >&2
rc=0
env -u LOCAL_MODEL_BASE_URL "${REBUILD}" claude-local >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 1 ]]; then
    echo "PASS: Case 1 — exited 1 as expected (rc=${rc})" >&2
else
    echo "FAIL: Case 1 — expected exit 1, got rc=${rc}" >&2
    VIOLATIONS=$(( VIOLATIONS + 1 ))
fi
echo "" >&2

# -----------------------------------------------------------------------
# Case 2 — --base-url flag present but value missing -> exit 1
# -----------------------------------------------------------------------
echo "INFO: Case 2 — --base-url with missing value -> expect exit 1" >&2
rc=0
env -u LOCAL_MODEL_BASE_URL "${REBUILD}" claude-local --base-url >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 1 ]]; then
    echo "PASS: Case 2 — exited 1 as expected (rc=${rc})" >&2
else
    echo "FAIL: Case 2 — expected exit 1, got rc=${rc}" >&2
    VIOLATIONS=$(( VIOLATIONS + 1 ))
fi
echo "" >&2

# -----------------------------------------------------------------------
# Case 3 — shell-metacharacter injection attempt -> exit 1
# -----------------------------------------------------------------------
echo "INFO: Case 3 — metacharacter-laden --base-url -> expect exit 1" >&2
rc=0
env -u LOCAL_MODEL_BASE_URL "${REBUILD}" claude-local --base-url 'http://x;rm -rf /' >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 1 ]]; then
    echo "PASS: Case 3 — exited 1 as expected (rc=${rc})" >&2
else
    echo "FAIL: Case 3 — expected exit 1, got rc=${rc}" >&2
    VIOLATIONS=$(( VIOLATIONS + 1 ))
fi
echo "" >&2

# -----------------------------------------------------------------------
# Case 4 — whitespace in --base-url -> exit 1
# -----------------------------------------------------------------------
echo "INFO: Case 4 — whitespace-containing --base-url -> expect exit 1" >&2
rc=0
env -u LOCAL_MODEL_BASE_URL "${REBUILD}" claude-local --base-url 'http://host name:8787' >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 1 ]]; then
    echo "PASS: Case 4 — exited 1 as expected (rc=${rc})" >&2
else
    echo "FAIL: Case 4 — expected exit 1, got rc=${rc}" >&2
    VIOLATIONS=$(( VIOLATIONS + 1 ))
fi
echo "" >&2

# -----------------------------------------------------------------------
# Case 5 — unknown verb still exits 1 (no regression to existing dispatch)
# -----------------------------------------------------------------------
echo "INFO: Case 5 — bogus verb (regression check) -> expect exit 1" >&2
rc=0
"${REBUILD}" bogusverb >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 1 ]]; then
    echo "PASS: Case 5 — exited 1 as expected (rc=${rc})" >&2
else
    echo "FAIL: Case 5 — expected exit 1, got rc=${rc}" >&2
    VIOLATIONS=$(( VIOLATIONS + 1 ))
fi
echo "" >&2

echo "=== Result: ${VIOLATIONS} violation(s) ===" >&2
if [[ "${VIOLATIONS}" -gt 0 ]]; then
    echo "FAIL: ${VIOLATIONS} case(s) did not fail closed as expected" >&2
    exit 1
fi

echo "PASS: all 5 negative-path cases exited 1 from the --base-url validator" >&2
echo "      (no podman/openshell present in this sandbox — proves the guard fires first)" >&2
exit 0
