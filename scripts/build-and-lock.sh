#!/usr/bin/env bash
# build-and-lock.sh — End-to-end driver: resolve -> podman build -> extract -> versions.lock
#
# Usage:
#   bash scripts/build-and-lock.sh [--cooldown-days N]
#
# Steps:
#   1. Runs scripts/resolve-versions.sh to compute COOLDOWN_DATE + version pins
#   2. Runs `podman build` with those versions as --build-arg flags, tagging claude-sandbox:dev
#   3. Extracts /versions-npm.json and /versions-govulncheck.txt from the built image
#   4. Assembles versions.lock (JSON) with cooldown metadata + package publish dates
#
# This script is the Phase 2 hand-off seam (D-01): rebuild.sh will wrap this resolver+build block.
# Keep the resolver-call + build-arg block factored and reusable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Defaults ---
COOLDOWN_DAYS=4
IMAGE_TAG="claude-sandbox:dev"
BUILD_DATE="$(python3 -c 'from datetime import date; print(date.today().isoformat())')"

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cooldown-days)
            if [[ -z "${2-}" ]]; then
                echo "ERROR: --cooldown-days requires an argument" >&2
                exit 1
            fi
            COOLDOWN_DAYS="$2"
            shift 2
            ;;
        --cooldown-days=*)
            COOLDOWN_DAYS="${1#--cooldown-days=}"
            shift
            ;;
        --tag)
            if [[ -z "${2-}" ]]; then
                echo "ERROR: --tag requires an argument" >&2
                exit 1
            fi
            IMAGE_TAG="$2"
            shift 2
            ;;
        --build-date)
            if [[ -z "${2-}" ]]; then
                echo "ERROR: --build-date requires an argument" >&2
                exit 1
            fi
            BUILD_DATE="$2"
            shift 2
            ;;
        --build-date=*)
            BUILD_DATE="${1#--build-date=}"
            shift
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Usage: $0 [--cooldown-days N] [--tag IMAGE:TAG] [--build-date YYYY-MM-DD]" >&2
            exit 1
            ;;
    esac
done

# T-02-01: Allowlist-validate BUILD_DATE — it flows into a --build-arg and must never
# carry shell or JSON metacharacters. Match YYYY-MM-DD only; reject everything else.
if ! [[ "${BUILD_DATE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "ERROR: --build-date must be YYYY-MM-DD, got: '${BUILD_DATE}'" >&2
    exit 1
fi

echo "=== Step 1: Resolve cooldown versions ===" >&2
echo "INFO: Running resolve-versions.sh --cooldown-days ${COOLDOWN_DAYS}" >&2

# CR-02 fix: parse resolver KEY=VALUE output through an allowlist instead of eval.
# The resolver emits KEY=VALUE pairs whose values come from npm/Go registry responses.
# eval of registry-controlled output is a code-injection risk (T-01-11).
# Validation rules:
#   COOLDOWN_DATE  — must match YYYY-MM-DD (date format)
#   *_VERSION      — must match ^v?[0-9][0-9A-Za-z._-]*$ (semver or vX.Y.Z form)
# Unknown keys are rejected. Valid pairs are assigned via printf -v (no eval).
COOLDOWN_DATE=""
GOVULNCHECK_VERSION=""
GSD_CORE_VERSION=""
CLAUDE_CODE_VERSION=""

while IFS='=' read -r key val; do
    # Skip blank lines and comment lines
    [[ -z "${key}" ]] && continue
    [[ "${key}" == \#* ]] && continue
    case "${key}" in
        COOLDOWN_DATE)
            if ! [[ "${val}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                echo "ERROR: Resolver emitted invalid COOLDOWN_DATE value: '${val}'" >&2
                exit 1
            fi
            printf -v COOLDOWN_DATE '%s' "${val}"
            ;;
        GOVULNCHECK_VERSION)
            if ! [[ "${val}" =~ ^v?[0-9][0-9A-Za-z._-]*$ ]]; then
                echo "ERROR: Resolver emitted invalid ${key} value: '${val}'" >&2
                exit 1
            fi
            printf -v "${key}" '%s' "${val}"
            ;;
        GSD_CORE_VERSION|CLAUDE_CODE_VERSION)
            if ! [[ "${val}" =~ ^[0-9][0-9A-Za-z._-]*$ ]]; then
                echo "ERROR: Resolver emitted invalid ${key} value: '${val}'" >&2
                exit 1
            fi
            printf -v "${key}" '%s' "${val}"
            ;;
        *)
            echo "ERROR: Resolver emitted unrecognised key: '${key}'" >&2
            exit 1
            ;;
    esac
done < <(bash "${SCRIPT_DIR}/resolve-versions.sh" --cooldown-days "${COOLDOWN_DAYS}")

# IN-01 fix: validate non-empty BEFORE logging, so set -u cannot abort with an
# unbound-variable error before the friendly validation message fires.
for VAR in COOLDOWN_DATE GOVULNCHECK_VERSION GSD_CORE_VERSION CLAUDE_CODE_VERSION; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: Resolver did not emit ${VAR}" >&2
        exit 1
    fi
done

echo "INFO: COOLDOWN_DATE=${COOLDOWN_DATE}" >&2
echo "INFO: GOVULNCHECK_VERSION=${GOVULNCHECK_VERSION}" >&2
echo "INFO: GSD_CORE_VERSION=${GSD_CORE_VERSION}" >&2
echo "INFO: CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}" >&2

echo "" >&2
echo "=== Step 2: Build container image ===" >&2
echo "INFO: Building image ${IMAGE_TAG} with podman..." >&2

podman build \
    --build-arg "COOLDOWN_DATE=${COOLDOWN_DATE}" \
    --build-arg "GOVULNCHECK_VERSION=${GOVULNCHECK_VERSION}" \
    --build-arg "GSD_CORE_VERSION=${GSD_CORE_VERSION}" \
    --build-arg "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}" \
    --build-arg "BUILD_DATE=${BUILD_DATE}" \
    --tag "${IMAGE_TAG}" \
    "${PROJECT_ROOT}"

echo "INFO: Image ${IMAGE_TAG} built successfully" >&2

echo "" >&2
echo "=== Step 3: Extract in-image version snapshots ===" >&2
echo "INFO: Creating stopped container to extract version files..." >&2

CID=$(podman create "${IMAGE_TAG}")
echo "INFO: Container ID: ${CID}" >&2

cleanup_container() {
    if [[ -n "${CID:-}" ]]; then
        echo "INFO: Removing container ${CID}" >&2
        podman rm "${CID}" >/dev/null 2>&1 || true
    fi
}
trap cleanup_container EXIT

podman cp "${CID}:/versions-npm.json" "${PROJECT_ROOT}/versions-npm.json"
echo "INFO: Extracted /versions-npm.json -> ${PROJECT_ROOT}/versions-npm.json" >&2

podman cp "${CID}:/versions-govulncheck.txt" "${PROJECT_ROOT}/versions-govulncheck.txt"
echo "INFO: Extracted /versions-govulncheck.txt -> ${PROJECT_ROOT}/versions-govulncheck.txt" >&2

podman rm "${CID}" >/dev/null
CID=""  # Clear so the trap doesn't try to remove again

# Verify both files were extracted
if [[ ! -f "${PROJECT_ROOT}/versions-npm.json" ]]; then
    echo "ERROR: versions-npm.json was not extracted from image" >&2
    exit 1
fi
if [[ ! -f "${PROJECT_ROOT}/versions-govulncheck.txt" ]]; then
    echo "ERROR: versions-govulncheck.txt was not extracted from image" >&2
    exit 1
fi

echo "" >&2
echo "=== Step 4: Assemble versions.lock ===" >&2

# Query publish dates for the top-level packages from registries
# (same registries the resolver queried, but now for exact version publish timestamps)
echo "INFO: Querying publish dates for lock file..." >&2

GOVULN_PUBLISH=$(curl -sf \
    "https://proxy.golang.org/golang.org/x/vuln/@v/${GOVULNCHECK_VERSION}.info" 2>/dev/null \
    | jq -r '.Time // empty' || true)

if [[ -z "$GOVULN_PUBLISH" ]]; then
    echo "ERROR: Could not fetch publish timestamp for govulncheck ${GOVULNCHECK_VERSION}" >&2
    exit 1
fi

GSD_CORE_PUBLISH=$(curl -sf "https://registry.npmjs.org/@opengsd/gsd-core" 2>/dev/null \
    | jq -r --arg ver "${GSD_CORE_VERSION}" '.time[$ver] // empty' || true)

if [[ -z "$GSD_CORE_PUBLISH" ]]; then
    echo "ERROR: Could not fetch publish timestamp for @opengsd/gsd-core ${GSD_CORE_VERSION}" >&2
    exit 1
fi

CLAUDE_CODE_PUBLISH=$(curl -sf "https://registry.npmjs.org/@anthropic-ai/claude-code" 2>/dev/null \
    | jq -r --arg ver "${CLAUDE_CODE_VERSION}" '.time[$ver] // empty' || true)

if [[ -z "$CLAUDE_CODE_PUBLISH" ]]; then
    echo "ERROR: Could not fetch publish timestamp for @anthropic-ai/claude-code ${CLAUDE_CODE_VERSION}" >&2
    exit 1
fi

BUILD_DATE=$(python3 -c "from datetime import date; print(date.today().isoformat())")

# Assemble versions.lock JSON via jq (Pattern 3 schema from RESEARCH)
jq -n \
    --arg cooldown_date "${COOLDOWN_DATE}" \
    --arg build_date "${BUILD_DATE}" \
    --argjson cooldown_days "${COOLDOWN_DAYS}" \
    --arg govuln_ver "${GOVULNCHECK_VERSION}" \
    --arg govuln_pub "${GOVULN_PUBLISH}" \
    --arg gsd_ver "${GSD_CORE_VERSION}" \
    --arg gsd_pub "${GSD_CORE_PUBLISH}" \
    --arg claude_ver "${CLAUDE_CODE_VERSION}" \
    --arg claude_pub "${CLAUDE_CODE_PUBLISH}" \
    --arg npm_snapshot "./versions-npm.json" \
    '{
      cooldown_date: $cooldown_date,
      build_date: $build_date,
      cooldown_days: $cooldown_days,
      packages: {
        govulncheck: {
          version: $govuln_ver,
          publish_date: $govuln_pub,
          registry: "https://proxy.golang.org/golang.org/x/vuln"
        },
        "@opengsd/gsd-core": {
          version: $gsd_ver,
          publish_date: $gsd_pub,
          registry: "https://registry.npmjs.org"
        },
        "@anthropic-ai/claude-code": {
          version: $claude_ver,
          publish_date: $claude_pub,
          registry: "https://registry.npmjs.org"
        }
      },
      npm_transitive_snapshot: $npm_snapshot
    }' > "${PROJECT_ROOT}/versions.lock"

echo "INFO: versions.lock written to ${PROJECT_ROOT}/versions.lock" >&2

# Verify versions.lock has expected structure
jq -e '.cooldown_date and .build_date and .packages.govulncheck.version and .packages["@opengsd/gsd-core"].version and .packages["@anthropic-ai/claude-code"].version' \
    "${PROJECT_ROOT}/versions.lock" > /dev/null

echo "" >&2
echo "=== Step 5: Verify pin-held guarantee (PIN-07) ===" >&2
echo "INFO: Running verify-pins.sh against versions.lock + versions-npm.json..." >&2

bash "${SCRIPT_DIR}/verify-pins.sh" \
    --lock "${PROJECT_ROOT}/versions.lock" \
    --npm-snapshot "${PROJECT_ROOT}/versions-npm.json"

echo "" >&2
echo "=== Build and Lock Complete ===" >&2
echo "INFO: Image: ${IMAGE_TAG}" >&2
echo "INFO: Cooldown date: ${COOLDOWN_DATE}" >&2
echo "INFO: govulncheck: ${GOVULNCHECK_VERSION}" >&2
echo "INFO: @opengsd/gsd-core: ${GSD_CORE_VERSION}" >&2
echo "INFO: @anthropic-ai/claude-code: ${CLAUDE_CODE_VERSION}" >&2
echo "INFO: Artifacts: versions.lock, versions-npm.json, versions-govulncheck.txt" >&2
