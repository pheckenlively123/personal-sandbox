#!/usr/bin/env bash
# preflight-supervisor-pin.sh — RUN-06 fail-closed supervisor-image pin preflight
#
# Verifies that the host's OpenShell gateway config pins the in-sandbox
# supervisor image to a NON-floating tag BEFORE `openshell sandbox create` runs,
# so the gateway and supervisor stay in lockstep instead of failing cryptically
# mid-create with:
#     "Failed to delete network namespace" / "Invalid argument (os error 22)"
#     -> "sandbox is not ready" / "ssh exited with status 255"
#
# Root cause this defends against: the gateway's default supervisor reference is
# `ghcr.io/nvidia/openshell/supervisor:latest`, ensured with pull policy "newer".
# A freshly published `:latest` (newer than the pinned gateway, e.g. 0.0.62) gets
# pulled on the next create; its in-container network-namespace setup then fails
# with EINVAL and the sandbox never becomes ready. Pinning `supervisor_image` to
# a stable version tag under [openshell.drivers.podman] makes "newer" a no-op and
# keeps the gateway/supervisor versions aligned.
#
# Operator-LOCKED behavior (do NOT add an auto-fix/auto-restart path):
#   - READ-ONLY: this script never writes, creates, or modifies gateway.toml, and
#     never restarts the gateway. It only inspects the config.
#   - FAIL-CLOSED (D-03 posture): an absent file, an absent table/key, a `:latest`
#     (or untagged, which podman treats as `:latest`) value, or an awk failure all
#     exit 1 with the full remediation block on stderr. It NEVER exits 0 on
#     uncertainty.
#   - VERSION-AGNOSTIC: any tag other than `latest` passes. The check does NOT
#     hardcode 0.0.62, so it survives `brew upgrade openshell` + re-pin without a
#     code change.
#
# Usage:
#   bash scripts/preflight-supervisor-pin.sh [GATEWAY_TOML]
#
# Default GATEWAY_TOML: ${XDG_CONFIG_HOME:-$HOME/.config}/openshell/gateway.toml
# An optional positional arg overrides the path (used by the guard gauntlet).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PROJECT_ROOT  # referenced for parity with other delegated scripts

# ---------------------------------------------------------------------------
# Logging helpers (mirrors rebuild.sh — scripts are deliberately self-contained)
# ---------------------------------------------------------------------------
ts() { python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }
log_info()  { echo "INFO: $1" >&2; }
log_error() { echo "ERROR: $1" >&2; }

# ---------------------------------------------------------------------------
# Config path resolution (XDG-aware; never hard-code /Users/... — must work on
# Linux too, which is the entire point of this preflight)
# ---------------------------------------------------------------------------
CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
GATEWAY_TOML="${1:-${CONFIG_HOME}/openshell/gateway.toml}"

# ---------------------------------------------------------------------------
# Remediation — emitted to stderr on EVERY failure path so the message is
# consistent. By design (operator decision) rebuild.sh does NOT modify host
# config; the operator applies this themselves.
# ---------------------------------------------------------------------------
remediation() {
    {
        echo ""
        echo "RUN-06: the OpenShell gateway must pin the supervisor image to a stable"
        echo "tag matching the installed gateway. The default '...supervisor:latest' is"
        echo "re-pulled (policy \"newer\") on every create and can drift NEWER than the"
        echo "gateway, breaking the in-sandbox supervisor's netns setup (\"Invalid"
        echo "argument (os error 22)\" -> \"sandbox is not ready\"). rebuild.sh does NOT"
        echo "modify host config by design — apply this yourself:"
        echo ""
        echo "  1. Find the installed gateway version:"
        echo "       openshell --version        # e.g. 'openshell 0.0.62' -> tag 0.0.62"
        echo ""
        echo "  2. Ensure ${GATEWAY_TOML} contains (use YOUR version, not literally 0.0.62):"
        echo ""
        echo "       [openshell.drivers.podman]"
        echo "       supervisor_image = \"ghcr.io/nvidia/openshell/supervisor:<gateway-version>\""
        echo ""
        echo "  3. Restart the gateway so it reloads the config:"
        echo "       Linux:  systemctl --user restart openshell"
        echo "       macOS:  brew services restart openshell"
        echo ""
        echo "  4. Re-run ./rebuild.sh"
        echo ""
    } >&2
}

log_step_banner() { echo "" >&2; echo "=== [$(ts)] RUN-06 preflight: supervisor image pinned ===" >&2; }
log_step_banner

# ---------------------------------------------------------------------------
# File-absent case (fresh host: gateway.toml may not exist at all). Missing
# inputs are fatal (fail-closed).
# ---------------------------------------------------------------------------
if [[ ! -f "${GATEWAY_TOML}" ]]; then
    log_error "OpenShell gateway config not found: ${GATEWAY_TOML}"
    remediation
    exit 1
fi

# ---------------------------------------------------------------------------
# Section-aware TOML parse. A naive `grep supervisor_image` is insufficient:
# it would also match the key under a different table or a commented-out line.
# The awk program:
#   - tracks the current [section] header (whitespace-trimmed);
#   - strips full-line and inline `#` comments (best-effort: assumes `#` is not
#     used inside the image reference, which holds for an OCI image:tag string);
#   - within [openshell.drivers.podman] ONLY, captures the value of a key whose
#     trimmed name is exactly `supervisor_image`, with surrounding single/double
#     quotes stripped;
#   - prints `VALUE=<image-ref>` for the LAST such assignment (TOML last-wins),
#     nothing if the key never appears in the table.
# Capture without aborting under set -e (if-capture form); an awk failure is
# itself fatal, never a silent pass.
# ---------------------------------------------------------------------------
read -r -d '' AWK_PROG <<'AWK' || true
{
    line = $0
    # Strip inline/full-line comments (everything from the first # onward).
    h = index(line, "#")
    if (h > 0) line = substr(line, 1, h - 1)
    # Trim surrounding whitespace.
    gsub(/^[ \t]+|[ \t]+$/, "", line)
    if (line == "") next

    # Section header: [ ... ]
    if (line ~ /^\[.*\]$/) {
        sect = line
        gsub(/^\[[ \t]*|[ \t]*\]$/, "", sect)
        in_podman = (sect == "openshell.drivers.podman")
        next
    }

    if (!in_podman) next

    # key = value
    eq = index(line, "=")
    if (eq == 0) next
    key = substr(line, 1, eq - 1)
    val = substr(line, eq + 1)
    gsub(/^[ \t]+|[ \t]+$/, "", key)
    gsub(/^[ \t]+|[ \t]+$/, "", val)
    if (key != "supervisor_image") next
    # Strip a single pair of surrounding quotes (single or double).
    if (val ~ /^".*"$/ || val ~ /^'.*'$/) val = substr(val, 2, length(val) - 2)
    found = val           # last-wins
}
END { if (found != "") print "VALUE=" found }
AWK

if ! RESULT=$(awk "${AWK_PROG}" "${GATEWAY_TOML}"); then
    log_error "Failed to parse ${GATEWAY_TOML} (awk error) — cannot verify supervisor pin"
    remediation
    exit 1
fi

# ---------------------------------------------------------------------------
# Key-absent: supervisor_image never set under [openshell.drivers.podman] means
# the gateway falls back to its built-in '...supervisor:latest' default — which
# is exactly the drift we fail closed on.
# ---------------------------------------------------------------------------
if [[ "${RESULT}" != VALUE=* ]]; then
    if grep -Eq '^[[:space:]]*\[[[:space:]]*openshell\.drivers\.podman[[:space:]]*\][[:space:]]*$' "${GATEWAY_TOML}"; then
        log_error "supervisor_image is not set under [openshell.drivers.podman] in ${GATEWAY_TOML} — gateway will use the floating '...supervisor:latest' default"
    else
        log_error "[openshell.drivers.podman] table absent from ${GATEWAY_TOML} — supervisor_image cannot be pinned"
    fi
    remediation
    exit 1
fi

IMAGE_REF="${RESULT#VALUE=}"

# Empty assignment (supervisor_image = "") is as bad as absent.
if [[ -z "${IMAGE_REF}" ]]; then
    log_error "supervisor_image is set but empty in ${GATEWAY_TOML}"
    remediation
    exit 1
fi

# ---------------------------------------------------------------------------
# Extract the tag. Split on the LAST ':' so a registry host:port prefix
# (e.g. registry.example.com:5000/img:tag) is not mistaken for the tag. If the
# segment after that ':' contains a '/', there was no tag at all (the ':' was a
# port) — podman then defaults to ':latest', which we reject.
# ---------------------------------------------------------------------------
last_segment="${IMAGE_REF##*:}"
if [[ "${IMAGE_REF}" != *:* || "${last_segment}" == */* ]]; then
    TAG=""   # no tag present → podman implies :latest
else
    TAG="${last_segment}"
fi

if [[ -z "${TAG}" ]]; then
    log_error "supervisor_image '${IMAGE_REF}' has no tag — podman treats this as ':latest' (floating); pin an explicit version tag"
    remediation
    exit 1
fi

if [[ "${TAG}" == "latest" ]]; then
    log_error "supervisor_image '${IMAGE_REF}' is pinned to the floating ':latest' tag — it re-pulls and can drift past the gateway version"
    remediation
    exit 1
fi

log_info "RUN-06 PASS — supervisor_image pinned to '${IMAGE_REF}' (tag '${TAG}') under [openshell.drivers.podman] in ${GATEWAY_TOML}"
exit 0
