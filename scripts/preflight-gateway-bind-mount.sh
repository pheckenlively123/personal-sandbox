#!/usr/bin/env bash
# preflight-gateway-bind-mount.sh — RUN-05 fail-closed gateway bind-mount preflight
#
# Verifies that the host's OpenShell gateway config enables bind mounts BEFORE
# `openshell sandbox create` runs, so a fresh host (e.g. Fedora) gets a clear
# remediation message instead of a cryptic mid-build podman error:
#     "podman bind mounts require enable_bind_mounts = true in [openshell.drivers.podman]"
#
# The ~/claudeshared bind mount (RUN-03/RUN-04) is unusable unless the gateway
# config sets `enable_bind_mounts = true` under the `[openshell.drivers.podman]`
# table. The repo previously assumed this was "already set on this host"; this
# preflight makes the precondition explicit and self-documenting.
#
# Operator-LOCKED behavior (do NOT add an auto-fix/auto-restart path):
#   - READ-ONLY: this script never writes, creates, or modifies gateway.toml, and
#     never restarts the gateway. It only inspects the config.
#   - FAIL-CLOSED (D-03 posture): an absent file, an absent table/key, or an awk
#     failure all exit 1 with the full remediation block on stderr. It NEVER
#     exits 0 on uncertainty.
#
# Usage:
#   bash scripts/preflight-gateway-bind-mount.sh [GATEWAY_TOML]
#
# Default GATEWAY_TOML: ${XDG_CONFIG_HOME:-$HOME/.config}/openshell/gateway.toml
# An optional positional arg overrides the path (used by the test harness).

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
        echo "RUN-05: ~/claudeshared cannot be bind-mounted into the sandbox until the"
        echo "OpenShell gateway enables bind mounts. rebuild.sh does NOT modify host"
        echo "config by design — apply this yourself:"
        echo ""
        echo "  1. Ensure ${GATEWAY_TOML} contains:"
        echo ""
        echo "       [openshell.drivers.podman]"
        echo "       enable_bind_mounts = true"
        echo ""
        echo "  2. Restart the gateway so it reloads the config:"
        echo "       Linux:  systemctl --user restart openshell"
        echo "       macOS:  brew services restart openshell"
        echo ""
        echo "  3. Re-run ./rebuild.sh"
        echo ""
    } >&2
}

log_step_banner() { echo "" >&2; echo "=== [$(ts)] RUN-05 preflight: gateway bind-mount enabled ===" >&2; }
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
# Section-aware TOML parse. A naive `grep enable_bind_mounts` is insufficient:
# it would also match the key under a different table or a commented-out line.
# The awk program:
#   - tracks the current [section] header (whitespace-trimmed);
#   - strips full-line and inline `#` comments (best-effort: assumes `#` is not
#     used inside the boolean value, which holds for `enable_bind_mounts = true`);
#   - within [openshell.drivers.podman] ONLY, matches a key whose trimmed name is
#     exactly `enable_bind_mounts` and whose trimmed value is exactly `true`;
#   - prints the sentinel FOUND on a genuine match, nothing otherwise.
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
    if (key == "enable_bind_mounts" && val == "true") { print "FOUND"; exit 0 }
}
AWK

if ! RESULT=$(awk "${AWK_PROG}" "${GATEWAY_TOML}"); then
    log_error "Failed to parse ${GATEWAY_TOML} (awk error) — cannot verify bind-mount config"
    remediation
    exit 1
fi

if [[ "${RESULT}" == *FOUND* ]]; then
    log_info "RUN-05 PASS — enable_bind_mounts = true under [openshell.drivers.podman] in ${GATEWAY_TOML}"
    exit 0
fi

# Distinguish table-absent vs key-absent for a clearer diagnostic (cheap).
if grep -Eq '^[[:space:]]*\[[[:space:]]*openshell\.drivers\.podman[[:space:]]*\][[:space:]]*$' "${GATEWAY_TOML}"; then
    log_error "[openshell.drivers.podman] table present in ${GATEWAY_TOML} but enable_bind_mounts is not set to true"
else
    log_error "[openshell.drivers.podman] table absent from ${GATEWAY_TOML}"
fi
remediation
exit 1
