#!/usr/bin/env bash
# resolve-versions.sh — Host-side cooldown version resolver.
#
# Computes the rolling cooldown date and resolves top-level version pins for:
#   - govulncheck (from proxy.golang.org)
#   - @opengsd/gsd-core (from registry.npmjs.org)
#   - @anthropic-ai/claude-code (from registry.npmjs.org)
#
# Usage:
#   bash scripts/resolve-versions.sh [--cooldown-days N]
#
# Outputs (one per line, KEY=VALUE, sourceable by bash):
#   COOLDOWN_DATE=YYYY-MM-DD
#   GOVULNCHECK_VERSION=vX.Y.Z
#   GSD_CORE_VERSION=X.Y.Z
#   CLAUDE_CODE_VERSION=X.Y.Z
#
# All diagnostics go to stderr so `eval $(...)` stays clean.
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

# Inclusive end-of-day cutoff per RESEARCH Pitfall 2:
# "latest as of COOLDOWN_DATE" means on or before end-of-day UTC (T23:59:59Z)
CUTOFF="${COOLDOWN_DATE}T23:59:59Z"

# --- Resolve govulncheck from Go proxy ---
echo "INFO: Querying proxy.golang.org for govulncheck versions..." >&2

VULN_LIST=$(curl -sf "https://proxy.golang.org/golang.org/x/vuln/@v/list" 2>/dev/null || true)
if [[ -z "$VULN_LIST" ]]; then
    echo "ERROR: Failed to fetch govulncheck version list from proxy.golang.org" >&2
    exit 1
fi

GOVULNCHECK_VERSION=""
GOVULNCHECK_PUBDATE=""

# For each version tag, fetch .info to get publish time, find latest <= CUTOFF
while IFS= read -r TAG; do
    [[ -z "$TAG" ]] && continue
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
    # Lexicographic ISO-8601 comparison: PUB_TIME <= CUTOFF
    # Note: [[ <= ]] is not a valid bash string operator; use < and == combined
    if [[ "$PUB_TIME" < "$CUTOFF" ]] || [[ "$PUB_TIME" == "$CUTOFF" ]]; then
        # Track latest (tags are generally in order but we pick latest PUB_TIME)
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

# --- Resolve @opengsd/gsd-core from npm registry ---
echo "INFO: Querying registry.npmjs.org for @opengsd/gsd-core..." >&2

GSD_CORE_DOC=$(curl -sf "https://registry.npmjs.org/@opengsd/gsd-core" 2>/dev/null || true)
if [[ -z "$GSD_CORE_DOC" ]]; then
    echo "ERROR: Failed to fetch @opengsd/gsd-core from registry.npmjs.org" >&2
    exit 1
fi

# jq pattern from RESEARCH Pattern 2: find latest version with .time[version] <= CUTOFF
# Filter out "created" and "modified" metadata keys, compare timestamps
GSD_CORE_VERSION=$(echo "$GSD_CORE_DOC" | jq -r \
    --arg cutoff "$CUTOFF" \
    '.time | to_entries | map(select(.key != "created" and .key != "modified" and (.value <= $cutoff))) | sort_by(.value) | last | .key' \
    2>/dev/null || true)

if [[ -z "$GSD_CORE_VERSION" ]] || [[ "$GSD_CORE_VERSION" == "null" ]]; then
    echo "ERROR: No @opengsd/gsd-core version found on or before ${CUTOFF}" >&2
    exit 1
fi

GSD_CORE_PUBDATE=$(echo "$GSD_CORE_DOC" | jq -r --arg ver "$GSD_CORE_VERSION" '.time[$ver]' 2>/dev/null || true)
echo "INFO: Resolved @opengsd/gsd-core=${GSD_CORE_VERSION} (published ${GSD_CORE_PUBDATE})" >&2

# --- Resolve @anthropic-ai/claude-code from npm registry ---
echo "INFO: Querying registry.npmjs.org for @anthropic-ai/claude-code..." >&2

CLAUDE_CODE_DOC=$(curl -sf "https://registry.npmjs.org/@anthropic-ai/claude-code" 2>/dev/null || true)
if [[ -z "$CLAUDE_CODE_DOC" ]]; then
    echo "ERROR: Failed to fetch @anthropic-ai/claude-code from registry.npmjs.org" >&2
    exit 1
fi

CLAUDE_CODE_VERSION=$(echo "$CLAUDE_CODE_DOC" | jq -r \
    --arg cutoff "$CUTOFF" \
    '.time | to_entries | map(select(.key != "created" and .key != "modified" and (.value <= $cutoff))) | sort_by(.value) | last | .key' \
    2>/dev/null || true)

if [[ -z "$CLAUDE_CODE_VERSION" ]] || [[ "$CLAUDE_CODE_VERSION" == "null" ]]; then
    echo "ERROR: No @anthropic-ai/claude-code version found on or before ${CUTOFF}" >&2
    exit 1
fi

CLAUDE_CODE_PUBDATE=$(echo "$CLAUDE_CODE_DOC" | jq -r --arg ver "$CLAUDE_CODE_VERSION" '.time[$ver]' 2>/dev/null || true)
echo "INFO: Resolved @anthropic-ai/claude-code=${CLAUDE_CODE_VERSION} (published ${CLAUDE_CODE_PUBDATE})" >&2

# --- Emit sourceable KEY=VALUE lines to stdout (NO extra stdout noise) ---
echo "COOLDOWN_DATE=${COOLDOWN_DATE}"
echo "GOVULNCHECK_VERSION=${GOVULNCHECK_VERSION}"
echo "GSD_CORE_VERSION=${GSD_CORE_VERSION}"
echo "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}"
