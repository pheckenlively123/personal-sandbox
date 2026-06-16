#!/usr/bin/env bash
# rebuild.sh — Idempotent top-level orchestrator for the claude-sandbox lifecycle.
#
# Usage:
#   ./rebuild.sh [--cooldown-days N]
#   ./rebuild.sh --audit
#
# Steps (normal mode):
#   1. Preflight — verify required tools are on PATH
#   2. Resolve cooldown versions and build container image (delegates to build-and-lock.sh)
#   3. Tag :latest alias
#   4. Teardown existing sandbox and images (tolerate-absent — idempotent)
#   5. Create sandbox with ~/claudeshared bind mount and policy.yaml
#
# Subcommands:
#   --audit   Surface openshell logs for claude-sandbox without rebuilding (BLD-05)
#
# Decisions:
#   D-01: Full clean rebuild every run (tear down existing sandbox + images before create)
#   D-02: Tolerate-absent teardown — absent sandbox/images are not errors
#   D-03: Tag :latest alias after date-pinned build
#   D-05: Subprocess delegation — rebuild.sh does not re-implement version resolution
#   D-06: Timestamped per-phase banners for phases this script controls
#   D-07: --audit is log-surfacing only; never asserts egress policy (Phase 3)

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Logging helpers (BLD-04 / D-06)
# ---------------------------------------------------------------------------
ts() { python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }

log_step() {
    echo "" >&2
    echo "=== [$(ts)] Step $1: $2 ===" >&2
}
log_info()  { echo "INFO: $1" >&2; }
log_error() { echo "ERROR: $1" >&2; }

# ---------------------------------------------------------------------------
# Provider existence preflight (D-03/NET-03)
# ---------------------------------------------------------------------------
# openshell inference get exits 0 in BOTH configured and unconfigured states.
# Detection MUST grep the ANSI-stripped output for "Not configured" — never
# branch on the exit code (Pitfall 1 from RESEARCH.md).
check_inference_provider() {
    local output
    output=$(openshell inference get 2>&1 | sed 's/\x1B\[[0-9;]*[mK]//g')
    if echo "${output}" | grep -q "Not configured"; then
        log_error "Inference provider is not configured — sandbox create would hang ~290s."
        log_error "One-time setup (operator action, see README):"
        log_error "  openshell provider create --name claude-code --type claude-code --from-existing"
        log_error "  openshell inference set --provider claude-code --model <MODEL>"
        exit 1
    fi
    log_info "Inference provider configured — preflight passed"
}

# ---------------------------------------------------------------------------
# Audit subcommand (BLD-05 / D-07 — log-surfacing only)
# ---------------------------------------------------------------------------
audit_sandbox() {
    local name="${1:-claude-sandbox}"
    local since="${2:-}"
    local since_arg=""
    [[ -n "$since" ]] && since_arg="--since ${since}"
    openshell logs "${name}" ${since_arg} --source all
}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
COOLDOWN_DAYS=4
SANDBOX_NAME="claude-sandbox"
AUDIT_MODE=false

# ---------------------------------------------------------------------------
# Argument parsing (mirror build-and-lock.sh two-form style)
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cooldown-days)
            if [[ -z "${2-}" ]]; then
                log_error "--cooldown-days requires an argument"
                exit 1
            fi
            COOLDOWN_DAYS="$2"
            shift 2
            ;;
        --cooldown-days=*)
            COOLDOWN_DAYS="${1#--cooldown-days=}"
            shift
            ;;
        --audit)
            AUDIT_MODE=true
            shift
            ;;
        *)
            log_error "Unknown argument: $1"
            echo "Usage: $0 [--cooldown-days N]" >&2
            echo "       $0 --audit" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# --audit subcommand: surface logs and exit without building (BLD-05)
# ---------------------------------------------------------------------------
if [[ "${AUDIT_MODE}" == "true" ]]; then
    log_info "Surfacing openshell logs for ${SANDBOX_NAME} (--audit mode — no build/teardown/create)"
    audit_sandbox "${SANDBOX_NAME}"
    exit 0
fi

# ---------------------------------------------------------------------------
# Preflight: verify required tools are on PATH (fail-closed)
# ---------------------------------------------------------------------------
for cmd in podman openshell python3 jq; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        log_error "Required tool not found on PATH: ${cmd}"
        exit 1
    fi
done
log_info "Preflight passed — all required tools found"

# Step 0 provider preflight: detect unconfigured inference gateway before the
# slow sandbox create (mitigates OpenShell #759 ~290s hang on missing provider).
check_inference_provider

# ---------------------------------------------------------------------------
# Compute BUILD_DATE once (used for image tag and passed to build-and-lock.sh)
# ---------------------------------------------------------------------------
BUILD_DATE="$(python3 -c 'from datetime import date; print(date.today().isoformat())')"
log_info "BUILD_DATE=${BUILD_DATE}"

# ---------------------------------------------------------------------------
# Step 1: Resolve cooldown versions and build container image
# ---------------------------------------------------------------------------
log_step 1 "Resolve cooldown versions and build container image"
bash "${PROJECT_ROOT}/scripts/build-and-lock.sh" \
    --cooldown-days "${COOLDOWN_DAYS}" \
    --tag "claude-sandbox:${BUILD_DATE}" \
    --build-date "${BUILD_DATE}"
log_info "build-and-lock.sh completed successfully"

# ---------------------------------------------------------------------------
# Step 2: Tag :latest alias (D-03)
# ---------------------------------------------------------------------------
log_step 2 "Tag :latest alias"
podman tag "localhost/claude-sandbox:${BUILD_DATE}" "localhost/claude-sandbox:latest"
log_info "Tagged localhost/claude-sandbox:latest"

# ---------------------------------------------------------------------------
# Step 3: Teardown existing sandbox and images (D-01/D-02 idempotent)
# ---------------------------------------------------------------------------
log_step 3 "Teardown existing sandbox and images"

# Teardown sandbox — tolerate "sandbox not found"; any other error is fatal
DELETE_OUT=$(openshell sandbox delete "${SANDBOX_NAME}" 2>&1) && true
DELETE_RC=$?
if [[ $DELETE_RC -ne 0 ]]; then
    if echo "${DELETE_OUT}" | grep -q "sandbox not found"; then
        log_info "Sandbox ${SANDBOX_NAME} not found — nothing to tear down"
    else
        log_error "openshell sandbox delete failed: ${DELETE_OUT}"
        exit 1
    fi
else
    log_info "Sandbox ${SANDBOX_NAME} deleted"
fi

# Remove old date-tagged claude-sandbox images (handles accumulation from prior runs)
# T-02-06: only target localhost/claude-sandbox:* — never rmi -a or untargeted prune
# Skip the image just built this run so Step 4 can find it locally (D-01/D-02: idempotent
# teardown of PRIOR images only; current build tags are preserved for sandbox create).
KEEP_DATE="localhost/claude-sandbox:${BUILD_DATE}"
KEEP_LATEST="localhost/claude-sandbox:latest"
OLD_IMAGES=$(podman images --filter reference='localhost/claude-sandbox:*' \
    --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
if [[ -n "${OLD_IMAGES}" ]]; then
    while IFS= read -r img; do
        [[ -z "${img}" ]] && continue
        if [[ "${img}" == "${KEEP_DATE}" || "${img}" == "${KEEP_LATEST}" ]]; then
            log_info "Keeping current build image: ${img}"
            continue
        fi
        log_info "Removing image: ${img}"
        podman rmi --force --ignore "${img}" >/dev/null 2>&1 || true
    done <<< "${OLD_IMAGES}"
fi
# Prune dangling layers only (safe — does not remove named images)
podman image prune --force >/dev/null 2>&1 || true
log_info "Image teardown complete"

# ---------------------------------------------------------------------------
# Step 4: Create sandbox with bind mount and policy (RUN-03/RUN-04, BLD-06)
# ---------------------------------------------------------------------------
log_step 4 "Create sandbox"

CLAUDESHARED_ABS="${HOME}/claudeshared"
mkdir -p "${CLAUDESHARED_ABS}"

# T-02-04 mitigation: validate CLAUDESHARED_ABS is an absolute path with no
# JSON special characters (quote, backslash) before JSON interpolation.
# No shell-level command substitution of CLI output anywhere in this script.
if ! [[ "${CLAUDESHARED_ABS}" =~ ^/[^\"\'\\]+ ]]; then
    log_error "CLAUDESHARED_ABS is not a safe absolute path: ${CLAUDESHARED_ABS}"
    exit 1
fi
log_info "Bind source: ${CLAUDESHARED_ABS}"

# BLD-06: always use the full local image ref (localhost/claude-sandbox:<date>)
# CLAUDE.md: source must be an absolute path (never ~); bind mount schema uses type/source/target/read_only
openshell sandbox create \
    --name "${SANDBOX_NAME}" \
    --from "localhost/claude-sandbox:${BUILD_DATE}" \
    --policy "${PROJECT_ROOT}/policy.yaml" \
    --driver-config-json "{\"podman\":{\"mounts\":[{\"type\":\"bind\",\"source\":\"${CLAUDESHARED_ABS}\",\"target\":\"/claudeshared\",\"read_only\":false}]}}" \
    --no-tty \
    -- /bin/true

log_info "Sandbox ${SANDBOX_NAME} created"

# Ready check
log_info "Verifying sandbox is in Ready state..."
if openshell sandbox list --names 2>/dev/null | grep -q "^${SANDBOX_NAME}$"; then
    log_info "Sandbox ${SANDBOX_NAME} is running"
else
    log_error "Sandbox ${SANDBOX_NAME} not found after create — check openshell logs for details"
    exit 1
fi

echo "" >&2
log_info "rebuild.sh complete — sandbox ${SANDBOX_NAME} is Ready"
log_info "  Image:          localhost/claude-sandbox:${BUILD_DATE}"
log_info "  Bind mount:     ${CLAUDESHARED_ABS} -> /claudeshared (read-write)"
log_info "  Policy:         ${PROJECT_ROOT}/policy.yaml"
log_info "  Egress audit:   ./rebuild.sh --audit (surfaces openshell logs)"
