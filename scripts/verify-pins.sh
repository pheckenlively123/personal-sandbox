#!/usr/bin/env bash
# verify-pins.sh — Host-side PIN-07 verifier
#
# Reads versions.lock + versions-npm.json, re-queries each package's true publish
# date from its registry, and exits 1 (fails closed) if any date postdates the
# inclusive cooldown cutoff (COOLDOWN_DATE + T23:59:59Z).
#
# Fail-closed posture (D-03): missing input files, malformed JSON, or registry
# query failures all exit non-zero — the verifier NEVER exits 0 on uncertainty.
#
# Usage:
#   bash scripts/verify-pins.sh [--lock FILE] [--npm-snapshot FILE]
#
# Defaults:
#   --lock           ./versions.lock
#   --npm-snapshot   ./versions-npm.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOCK_FILE="${PROJECT_ROOT}/versions.lock"
NPM_SNAPSHOT="${PROJECT_ROOT}/versions-npm.json"

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --lock)
            if [[ -z "${2-}" ]]; then
                echo "ERROR: --lock requires an argument" >&2
                exit 1
            fi
            LOCK_FILE="$2"
            shift 2
            ;;
        --lock=*)
            LOCK_FILE="${1#--lock=}"
            shift
            ;;
        --npm-snapshot)
            if [[ -z "${2-}" ]]; then
                echo "ERROR: --npm-snapshot requires an argument" >&2
                exit 1
            fi
            NPM_SNAPSHOT="$2"
            shift 2
            ;;
        --npm-snapshot=*)
            NPM_SNAPSHOT="${1#--npm-snapshot=}"
            shift
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Usage: $0 [--lock FILE] [--npm-snapshot FILE]" >&2
            exit 1
            ;;
    esac
done

# --- Fail-closed input validation ---
if [[ ! -f "${LOCK_FILE}" ]]; then
    echo "FAIL: versions.lock not found at ${LOCK_FILE}" >&2
    exit 1
fi

if [[ ! -f "${NPM_SNAPSHOT}" ]]; then
    echo "FAIL: versions-npm.json not found at ${NPM_SNAPSHOT}" >&2
    exit 1
fi

# Validate JSON (fail closed on malformed input)
if ! jq empty "${LOCK_FILE}" 2>/dev/null; then
    echo "FAIL: versions.lock is not valid JSON" >&2
    exit 1
fi

if ! jq empty "${NPM_SNAPSHOT}" 2>/dev/null; then
    echo "FAIL: versions-npm.json is not valid JSON" >&2
    exit 1
fi

# --- Read cooldown date and form inclusive cutoff ---
COOLDOWN_DATE=$(jq -r '.cooldown_date // empty' "${LOCK_FILE}")
if [[ -z "${COOLDOWN_DATE}" ]]; then
    echo "FAIL: versions.lock missing cooldown_date field" >&2
    exit 1
fi

CUTOFF="${COOLDOWN_DATE}T23:59:59Z"
echo "INFO: Cooldown cutoff: ${CUTOFF}" >&2

VIOLATIONS=0
CHECKED=0

# --- Helper: check a publish date against the cutoff ---
# Returns 0 if clean, increments VIOLATIONS if not
check_date() {
    local pkg="$1"
    local ver="$2"
    local pub_date="$3"

    if [[ -z "${pub_date}" || "${pub_date}" == "null" ]]; then
        echo "FAIL: ${pkg}@${ver} has no publish date (empty registry response)" >&2
        VIOLATIONS=$(( VIOLATIONS + 1 ))
        return
    fi

    # ISO-8601 lexicographic comparison: if pub_date > CUTOFF, it violates
    if [[ "${pub_date}" > "${CUTOFF}" ]]; then
        echo "FAIL: ${pkg} ${ver} published ${pub_date} > cutoff ${CUTOFF}" >&2
        VIOLATIONS=$(( VIOLATIONS + 1 ))
    fi
    CHECKED=$(( CHECKED + 1 ))
}

# --- Helper: query npm registry for a package@version publish date ---
# Fails closed: exits 1 if curl fails or response is malformed
npm_publish_date() {
    local pkg="$1"
    local ver="$2"

    local response
    response=$(curl -sf "https://registry.npmjs.org/${pkg}" 2>/dev/null || true)
    if [[ -z "${response}" ]]; then
        echo "FAIL: Registry query failed for ${pkg} (network error or empty response)" >&2
        VIOLATIONS=$(( VIOLATIONS + 1 ))
        echo ""
        return
    fi

    local pub_date
    pub_date=$(echo "${response}" | jq -r --arg ver "${ver}" '.time[$ver] // empty' 2>/dev/null || true)
    echo "${pub_date}"
}

echo "" >&2
echo "=== Verifying top-level pins ===" >&2

# --- Verify govulncheck (Go proxy) ---
GOVULN_VER=$(jq -r '.packages.govulncheck.version // empty' "${LOCK_FILE}")
if [[ -z "${GOVULN_VER}" ]]; then
    echo "FAIL: versions.lock missing packages.govulncheck.version" >&2
    exit 1
fi

echo "INFO: Checking govulncheck ${GOVULN_VER}..." >&2
GOVULN_RESPONSE=$(curl -sf "https://proxy.golang.org/golang.org/x/vuln/@v/${GOVULN_VER}.info" 2>/dev/null || true)
if [[ -z "${GOVULN_RESPONSE}" ]]; then
    echo "FAIL: Registry query failed for govulncheck ${GOVULN_VER} (Go proxy unreachable or version not found)" >&2
    exit 1
fi

GOVULN_TIME=$(echo "${GOVULN_RESPONSE}" | jq -r '.Time // empty' 2>/dev/null || true)
check_date "govulncheck" "${GOVULN_VER}" "${GOVULN_TIME}"

# --- Verify top-level npm packages ---
for NPM_PKG in "@opengsd/gsd-core" "@anthropic-ai/claude-code"; do
    # Build the jq key for the packages object (uses bracket notation for @ packages)
    NPM_VER=$(jq -r --arg pkg "${NPM_PKG}" '.packages[$pkg].version // empty' "${LOCK_FILE}")
    if [[ -z "${NPM_VER}" ]]; then
        echo "FAIL: versions.lock missing packages[\"${NPM_PKG}\"].version" >&2
        exit 1
    fi

    echo "INFO: Checking ${NPM_PKG}@${NPM_VER} (top-level)..." >&2
    NPM_PUB=$(npm_publish_date "${NPM_PKG}" "${NPM_VER}")
    check_date "${NPM_PKG}" "${NPM_VER}" "${NPM_PUB}"
done

echo "" >&2
echo "=== Verifying transitive npm deps (D-04 coverage) ===" >&2

# --- Extract all transitive package+version pairs from versions-npm.json ---
# This is the core value of D-04: verify what npm --before ACTUALLY resolved,
# not just the top-level pins.
#
# versions-npm.json is a nested tree from `npm ls -g --json --depth=Infinity`.
# We flatten it recursively to get all {pkg, ver} pairs.
TRANSITIVE_PAIRS=$(jq -r '
  def allpkgs:
    to_entries[] |
    .key as $pkg |
    .value |
    (if has("version") then "\($pkg)\t\(.version)" else empty end),
    (if has("dependencies") then (.dependencies | allpkgs) else empty end);
  .dependencies | allpkgs
' "${NPM_SNAPSHOT}" | sort -u)

if [[ -z "${TRANSITIVE_PAIRS}" ]]; then
    echo "FAIL: versions-npm.json has no transitive deps (malformed or empty)" >&2
    exit 1
fi

# Fetch and cache full registry docs to avoid repeated requests for same package
declare -A REGISTRY_CACHE

TRANSITIVE_COUNT=0
while IFS=$'\t' read -r PKG VER; do
    # Skip empty lines
    [[ -z "${PKG}" || -z "${VER}" ]] && continue

    echo "INFO: Checking transitive ${PKG}@${VER}..." >&2

    # Use cached registry response if available
    if [[ -z "${REGISTRY_CACHE[${PKG}]+_}" ]]; then
        REGISTRY_RESP=$(curl -sf "https://registry.npmjs.org/${PKG}" 2>/dev/null || true)
        REGISTRY_CACHE["${PKG}"]="${REGISTRY_RESP}"
    else
        REGISTRY_RESP="${REGISTRY_CACHE[${PKG}]}"
    fi

    if [[ -z "${REGISTRY_RESP}" ]]; then
        echo "FAIL: Registry query failed for transitive dep ${PKG} (network error)" >&2
        VIOLATIONS=$(( VIOLATIONS + 1 ))
        continue
    fi

    PUB_DATE=$(echo "${REGISTRY_RESP}" | jq -r --arg ver "${VER}" '.time[$ver] // empty' 2>/dev/null || true)
    check_date "${PKG}" "${VER}" "${PUB_DATE}"
    TRANSITIVE_COUNT=$(( TRANSITIVE_COUNT + 1 ))
done <<< "${TRANSITIVE_PAIRS}"

echo "" >&2
echo "=== Verification Complete ===" >&2
echo "INFO: Checked ${CHECKED} packages total (1 govulncheck + top-level npm + ${TRANSITIVE_COUNT} transitive)" >&2

if [[ "${VIOLATIONS}" -gt 0 ]]; then
    echo "FAIL: ${VIOLATIONS} pin violation(s) found — pipeline fails closed (PIN-07)" >&2
    exit 1
fi

echo "PASS: All pins verified — every package published on or before ${CUTOFF}" >&2
exit 0
