#!/usr/bin/env bash
# test-pin-held.sh — PIN-07 / ROADMAP Success Criterion #5 (negative-path proof)
#
# Seeds a deliberately post-cooldown version into a temp copy of versions.lock
# and asserts that scripts/verify-pins.sh exits NON-ZERO (violation detected).
#
# This is the negative-path proof: a seeded violating pin MUST fail the pipeline.
# A verifier that fails OPEN (exits 0 on a violation) defeats the PIN-07 guarantee.
#
# Strategy: replace @opengsd/gsd-core version in a temp lock with a known
# post-cutoff version (1.4.4 — published 2026-06-11T00:48:28.454Z, after the
# 2026-06-09T23:59:59Z cutoff). The verifier re-queries the live registry for
# this version and MUST detect that it postdates the cooldown cutoff.
#
# Pass (test passes): verify-pins.sh exits NON-ZERO for the tampered lock
# Fail (test fails): verify-pins.sh exits 0 (fails open) — pipeline guarantee broken
#
# The real versions.lock is NEVER mutated: all edits go to a temp directory.
#
# Usage:
#   bash tests/test-pin-held.sh
#
# Requires: jq, curl, bash scripts/verify-pins.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOCK_FILE="${PROJECT_ROOT}/versions.lock"
NPM_SNAPSHOT="${PROJECT_ROOT}/versions-npm.json"
VERIFIER="${PROJECT_ROOT}/scripts/verify-pins.sh"

# A known post-cutoff version: gsd-core 1.4.4 published 2026-06-11T00:48:28.454Z
# which is after the cooldown cutoff 2026-06-09T23:59:59Z
POST_CUTOFF_PKG="@opengsd/gsd-core"
POST_CUTOFF_VER="1.4.4"

# Verify prerequisites
if [[ ! -f "${LOCK_FILE}" ]]; then
    echo "SKIP: ${LOCK_FILE} not found — run build-and-lock.sh first to generate it" >&2
    echo "      (This test requires a real versions.lock from a completed build)" >&2
    exit 1
fi

if [[ ! -f "${NPM_SNAPSHOT}" ]]; then
    echo "SKIP: ${NPM_SNAPSHOT} not found — run build-and-lock.sh first to generate it" >&2
    exit 1
fi

if [[ ! -x "${VERIFIER}" ]]; then
    echo "FAIL: ${VERIFIER} is not executable (Task 1 not complete?)" >&2
    exit 1
fi

# Temp directory for the seeded lock — never touches the real versions.lock
TMPDIR_SEEDED=$(mktemp -d)
SEEDED_LOCK="${TMPDIR_SEEDED}/versions.lock"

cleanup() {
    echo "INFO: Cleaning up temp directory ${TMPDIR_SEEDED}..." >&2
    rm -rf "${TMPDIR_SEEDED}"
}
trap cleanup EXIT

echo "=== Pin-Held Negative-Path Test: Criterion #5 / PIN-07 ===" >&2
echo "" >&2
echo "INFO: Strategy: seed ${POST_CUTOFF_PKG}@${POST_CUTOFF_VER} into temp lock" >&2
echo "      (published 2026-06-11T00:48:28Z — after cooldown 2026-06-09T23:59:59Z)" >&2
echo "" >&2

# Read current lock and inject the post-cutoff version
# The verifier re-queries the live registry for the version recorded in versions.lock,
# so changing the version field in the lock is what triggers the violation detection.
jq --arg pkg "${POST_CUTOFF_PKG}" \
   --arg ver "${POST_CUTOFF_VER}" \
   '.packages[$pkg].version = $ver' \
   "${LOCK_FILE}" > "${SEEDED_LOCK}"

echo "INFO: Seeded lock written to ${SEEDED_LOCK}" >&2
echo "INFO: Tampered ${POST_CUTOFF_PKG}: original=$(jq -r '.packages["@opengsd/gsd-core"].version' "${LOCK_FILE}") -> seeded=${POST_CUTOFF_VER}" >&2
echo "" >&2

# Run the verifier against the seeded lock (using the real npm snapshot so
# transitive deps are still checked, but the top-level pin violation fires first)
echo "INFO: Running verify-pins.sh against seeded (tampered) lock..." >&2
echo "" >&2

VERIFIER_EXIT=0
bash "${VERIFIER}" \
    --lock "${SEEDED_LOCK}" \
    --npm-snapshot "${NPM_SNAPSHOT}" \
    2>&1 || VERIFIER_EXIT=$?

echo "" >&2
echo "INFO: verify-pins.sh exited with code: ${VERIFIER_EXIT}" >&2
echo "" >&2

# Assertion: verifier MUST exit non-zero for the seeded violation
if [[ "${VERIFIER_EXIT}" -eq 0 ]]; then
    echo "FAIL: verify-pins.sh exited 0 (passed) despite a seeded post-cutoff pin" >&2
    echo "      PIN-07 is failing OPEN — the pipeline guarantee is broken!" >&2
    echo "      Seeded: ${POST_CUTOFF_PKG}@${POST_CUTOFF_VER}" >&2
    echo "      Expected: exit non-zero (violation detected)" >&2
    exit 1
fi

echo "PASS: verify-pins.sh correctly exited NON-ZERO (exit ${VERIFIER_EXIT})" >&2
echo "      Seeded post-cutoff pin ${POST_CUTOFF_PKG}@${POST_CUTOFF_VER} was caught" >&2
echo "      PIN-07 fails closed — the pipeline guarantee holds (Criterion #5)" >&2
exit 0
