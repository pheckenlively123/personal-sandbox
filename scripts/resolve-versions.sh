#!/usr/bin/env bash
# resolve-versions.sh — Host-side cooldown version resolver.
#
# Computes the rolling cooldown date and resolves top-level version pins for:
#   - govulncheck (from proxy.golang.org)
#
# npm packages are NOT resolved here; their versions are determined at build time by
# npm --min-release-age and read post-build from versions-npm.json by build-and-lock.sh.
#
# Usage:
#   bash scripts/resolve-versions.sh [--cooldown-days N]
#
# Outputs (one per line, KEY=VALUE, sourceable by bash):
#   COOLDOWN_DATE=YYYY-MM-DD
#   GOVULNCHECK_VERSION=vX.Y.Z
#
# All diagnostics go to stderr so stdout stays clean for KEY=VALUE parsing.
# Exits non-zero on bad input or registry failure.

set -euo pipefail

# --- Defaults ---
COOLDOWN_DAYS=4

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
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Usage: $0 [--cooldown-days N]" >&2
            exit 1
            ;;
    esac
done

# --- Input validation (RESEARCH V5: positive integer) ---
if ! [[ "$COOLDOWN_DAYS" =~ ^[0-9]+$ ]] || [[ "$COOLDOWN_DAYS" -le 0 ]]; then
    echo "ERROR: --cooldown-days must be a positive integer, got: '$COOLDOWN_DAYS'" >&2
    exit 1
fi

# --- Compute COOLDOWN_DATE via python3 (cross-platform, not date -d which is GNU-only) ---
COOLDOWN_DATE=$(python3 -c "
from datetime import date, timedelta
print((date.today() - timedelta(days=${COOLDOWN_DAYS})).isoformat())
")

if [[ -z "$COOLDOWN_DATE" ]]; then
    echo "ERROR: Failed to compute COOLDOWN_DATE" >&2
    exit 1
fi

echo "INFO: Resolving versions for cooldown date: ${COOLDOWN_DATE} (--cooldown-days ${COOLDOWN_DAYS})" >&2

# CR-01 fix: use an EXCLUSIVE next-day-midnight bound (CUTOFF_EXCL) instead of
# the second-precision T23:59:59Z string.
# Semantics: "latest as of COOLDOWN_DATE" = published strictly before next-day midnight UTC.
# This correctly handles millisecond-precision npm timestamps: no T23:59:59.NNNZ value
# reaches T00:00:00.000Z of the next day, while every next-day timestamp does.
# CUTOFF (display) kept for log messages; CUTOFF_EXCL is the comparison operand.
CUTOFF="${COOLDOWN_DATE}T23:59:59Z"  # human-readable display only — NOT used for comparison
NEXT_DAY=$(python3 -c "
from datetime import date, timedelta
import re
m = re.match(r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$', '${COOLDOWN_DATE}')
if not m:
    raise SystemExit('ERROR: COOLDOWN_DATE format invalid')
d = date(int(m.group(1)), int(m.group(2)), int(m.group(3))) + timedelta(days=1)
print(d.isoformat())
")
if [[ -z "${NEXT_DAY}" ]]; then
    echo "ERROR: Could not compute next-day from COOLDOWN_DATE=${COOLDOWN_DATE}" >&2
    exit 1
fi
CUTOFF_EXCL="${NEXT_DAY}T00:00:00.000Z"  # exclusive upper bound — the comparison operand
echo "INFO: CUTOFF_EXCL (exclusive next-day midnight): ${CUTOFF_EXCL}" >&2

# --- Resolve govulncheck from Go proxy ---
echo "INFO: Querying proxy.golang.org for govulncheck versions..." >&2

VULN_LIST=$(curl -sf "https://proxy.golang.org/golang.org/x/vuln/@v/list" 2>/dev/null || true)
if [[ -z "$VULN_LIST" ]]; then
    echo "ERROR: Failed to fetch govulncheck version list from proxy.golang.org" >&2
    exit 1
fi

GOVULNCHECK_VERSION=""
GOVULNCHECK_PUBDATE=""

# For each version tag, fetch .info to get publish time, find latest before CUTOFF_EXCL.
# CR-01 fix: compare against CUTOFF_EXCL (exclusive next-day midnight) not T23:59:59Z.
# IN-02: restrict to release tags matching ^v[0-9]+\.[0-9]+\.[0-9]+$ to exclude
# pseudo-versions and pre-releases from the govulncheck pin selection.
while IFS= read -r TAG; do
    [[ -z "$TAG" ]] && continue
    # IN-02: skip pseudo-versions and pre-release tags; only accept release form vX.Y.Z
    if ! [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "INFO: Skipping non-release govulncheck tag: ${TAG}" >&2
        continue
    fi
    INFO=$(curl -sf "https://proxy.golang.org/golang.org/x/vuln/@v/${TAG}.info" 2>/dev/null || true)
    if [[ -z "$INFO" ]]; then
        echo "WARNING: Could not fetch info for govulncheck ${TAG}" >&2
        continue
    fi
    PUB_TIME=$(echo "$INFO" | jq -r '.Time // empty' 2>/dev/null || true)
    if [[ -z "$PUB_TIME" ]]; then
        echo "WARNING: No .Time in info for govulncheck ${TAG}" >&2
        continue
    fi
    # CR-01 fix: a tag is eligible when its publish time is strictly before CUTOFF_EXCL
    # (i.e. published on or before the inclusive cutoff day, any millisecond precision).
    if [[ "$PUB_TIME" < "$CUTOFF_EXCL" ]]; then
        # Track latest eligible (pick the one with the most recent PUB_TIME)
        if [[ -z "$GOVULNCHECK_PUBDATE" ]] || [[ "$PUB_TIME" > "$GOVULNCHECK_PUBDATE" ]]; then
            GOVULNCHECK_VERSION="$TAG"
            GOVULNCHECK_PUBDATE="$PUB_TIME"
        fi
    fi
done <<< "$VULN_LIST"

if [[ -z "$GOVULNCHECK_VERSION" ]]; then
    echo "ERROR: No govulncheck version found on or before ${CUTOFF}" >&2
    exit 1
fi
echo "INFO: Resolved govulncheck=${GOVULNCHECK_VERSION} (published ${GOVULNCHECK_PUBDATE})" >&2

# --- Emit sourceable KEY=VALUE lines to stdout (NO extra stdout noise) ---
echo "COOLDOWN_DATE=${COOLDOWN_DATE}"
echo "GOVULNCHECK_VERSION=${GOVULNCHECK_VERSION}"
