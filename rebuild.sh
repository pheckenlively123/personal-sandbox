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
# openshell inference get exits 0 when the gateway is reachable (configured OR
# "Not configured"), but exits NON-ZERO on a transport error (gateway/podman down
# → "Connection refused"). Under `set -euo pipefail` the line-50 command
# substitution must tolerate that non-zero (|| rc=$?) or it aborts the whole
# script silently before the grep. Three states are distinguished: unreachable
# (rc!=0), not-configured, configured.
#
# `openshell inference get` prints TWO routes: "Gateway inference:" (the
# user-facing route that inference.local — and thus Claude Code — uses) and
# "System inference:" (the sandbox-system route, used only by platform/agent-harness
# functions and never by user code). We configure only the gateway route, so
# "System inference: Not configured" persists; checking it would falsely fail.
# Therefore inspect ONLY the Gateway inference section. (Confirmed against
# OpenShell source: run.rs prints both routes; --system selects sandbox-system.)
check_inference_provider() {
    local output rc=0
    output=$(openshell inference get 2>&1 | sed 's/\x1B\[[0-9;]*[mK]//g') || rc=$?

    if [[ ${rc} -ne 0 ]]; then
        log_error "Could not reach the OpenShell inference gateway (openshell inference get exited ${rc})."
        log_error "The podman/gateway backend may be down. Try: podman machine start"
        log_error "Detail: ${output}"
        exit 1
    fi

    # Isolate the Gateway inference block (lines after "Gateway inference:" up to
    # but not including "System inference:"); the system route is intentionally ignored.
    local gateway_block
    gateway_block=$(printf '%s\n' "${output}" | awk '
        /^Gateway inference:/ {cap=1; next}
        /^System inference:/  {cap=0}
        cap {print}
    ')
    if printf '%s\n' "${gateway_block}" | grep -qE "Not configured|Error:"; then
        log_error "Inference provider is not configured — sandbox create would hang ~290s."
        log_error "One-time setup (operator action, see README):"
        log_error "  openshell provider create --name claude-code --type claude-code --from-existing"
        log_error "  openshell inference set --provider claude-code --model <MODEL>"
        exit 1
    fi
    log_info "Inference provider configured — preflight passed"
}

# ---------------------------------------------------------------------------
# NET-04 live policy assertion (Step 5 / D-02)
# ---------------------------------------------------------------------------
# Query the live sandbox policy (not the static policy.yaml) and abort if any
# direct Anthropic endpoint is present. jq -e exits 0 on match (VIOLATION),
# non-zero on no match (PASS) — inverted sense per verify-pins.sh discipline.
# The '// {}' guard handles the absent network_policies field (correct deny-all
# state where the key does not appear in the JSON at all).
assert_no_anthropic_egress() {
    local sandbox_name="${1}"
    local policy_json
    policy_json=$(openshell policy get "${sandbox_name}" --full -o json 2>&1)

    # jq -e exits 0 if a matching entry is found (VIOLATION), non-zero if no match (PASS)
    if echo "${policy_json}" | jq -e \
        '.policy.network_policies // {} | to_entries[] | .value.endpoints[]? | select(.host | test("anthropic"; "i"))' \
        >/dev/null 2>&1; then
        log_error "NET-04 VIOLATION: Direct Anthropic endpoint found in effective policy!"
        log_error "Policy output: ${policy_json}"
        exit 1
    fi
    log_info "NET-04 PASS: No direct Anthropic endpoints in effective policy"
}

# ---------------------------------------------------------------------------
# NET-05 egress smoke test (Step 6 / D-05)
# ---------------------------------------------------------------------------
# Run curl from inside the running sandbox. PASS condition is curl exit != 0
# (proxy blocks the connection). Any exit 0 (connection succeeded) is a hard
# violation — zero-egress is broken. Tests two independent targets: a specific
# Anthropic endpoint and a generic endpoint to prove deny-all (T-03-02).
# Every openshell invocation below redirects stderr (2>/dev/null) to suppress
# the non-fatal ".bash_profile: Permission denied" noise (Pitfall 4 / RESEARCH.md).
run_egress_smoke_test() {
    local sandbox_name="${1}"
    local -a targets=("https://api.anthropic.com" "https://example.com")

    for target in "${targets[@]}"; do
        local rc=0
        openshell sandbox exec --name "${sandbox_name}" --no-tty -- curl --max-time 8 --silent "${target}" 2>/dev/null || rc=$?

        if [[ ${rc} -eq 0 ]]; then
            log_error "NET-05 VIOLATION: Egress to ${target} SUCCEEDED — zero-egress is broken!"
            exit 1
        fi
        log_info "NET-05 PASS: ${target} blocked (curl exit ${rc})"
    done
}

# ---------------------------------------------------------------------------
# D-06 inference round-trip (Step 7, non-fatal)
# ---------------------------------------------------------------------------
# Fires a single model round-trip through inference.local from inside the
# sandbox and reports PASS or WARN — never blocks the rebuild (non-fatal gate).
#
# Success is detected by parsing the JSON body (.content | length > 0), NOT
# the curl exit code (which is 0 even on a gateway error body — Pitfall 2
# from RESEARCH.md). The placeholder x-api-key is never a real credential;
# the OpenShell gateway injects the real subscription token host-side (NET-03).
#
# The URL is https://inference.local/v1/messages (single /v1 path). Do NOT
# use inference.local/v1/v1 — that double-path anti-pattern is listed in
# CLAUDE.md "What NOT to Use" and verified via acceptance check.
#
# Uses || rc=$? (not bare || true) so the exit code is available for branching.
# return 0 on every warn path — no exit, no set -e abort.
run_inference_round_trip() {
    local sandbox_name="${1}"
    local response rc=0

    response=$(openshell sandbox exec --name "${sandbox_name}" --no-tty \
        -- curl --max-time 30 --silent \
        -X POST https://inference.local/v1/messages \
        -H "Content-Type: application/json" \
        -H "x-api-key: placeholder" \
        -d '{"model":"any","max_tokens":10,"messages":[{"role":"user","content":"ping"}]}' \
        2>/dev/null) || rc=$?

    if [[ ${rc} -ne 0 ]]; then
        log_info "D-06 WARN: curl failed (rc=${rc}) — inference path unverified (non-fatal)"
        ROUND_TRIP_STATUS="WARN (curl exit ${rc})"
        return 0
    fi
    if echo "${response}" | jq -e '.content | length > 0' >/dev/null 2>&1; then
        log_info "D-06 PASS: inference.local returned a model response"
        ROUND_TRIP_STATUS="PASS"
    else
        local err
        err=$(echo "${response}" | jq -r '.error // "unknown"' 2>/dev/null || echo "${response}")
        log_info "D-06 WARN: inference.local error: ${err} (non-fatal — see README for provider setup)"
        ROUND_TRIP_STATUS="WARN (${err})"
    fi
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
ROUND_TRIP_STATUS="NOT RUN"

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

# ---------------------------------------------------------------------------
# Step 5: Assert no direct Anthropic egress in live policy (NET-04 / D-02)
# ---------------------------------------------------------------------------
log_step 5 "NET-04 — Assert no direct Anthropic egress in live policy"
assert_no_anthropic_egress "${SANDBOX_NAME}"

# ---------------------------------------------------------------------------
# Step 6: Egress smoke test — confirm outbound connections are blocked (NET-05 / D-05)
# ---------------------------------------------------------------------------
log_step 6 "NET-05 — Egress smoke test (in-sandbox curl)"
run_egress_smoke_test "${SANDBOX_NAME}"

# ---------------------------------------------------------------------------
# Step 7: D-06 — Inference round-trip through inference.local (non-fatal)
# ---------------------------------------------------------------------------
log_step 7 "D-06 — Inference round-trip (non-fatal)"
run_inference_round_trip "${SANDBOX_NAME}"

echo "" >&2
log_info "rebuild.sh complete — sandbox ${SANDBOX_NAME} is Ready"
log_info "  Image:          localhost/claude-sandbox:${BUILD_DATE}"
log_info "  Bind mount:     ${CLAUDESHARED_ABS} -> /claudeshared (read-write)"
log_info "  Policy:         ${PROJECT_ROOT}/policy.yaml"
log_info "  Egress audit:   ./rebuild.sh --audit (surfaces openshell logs)"
log_info "  NET-04:         PASS (no direct Anthropic endpoints in live policy)"
log_info "  NET-05:         PASS (outbound egress blocked — two targets confirmed)"
log_info "  Round-trip:     ${ROUND_TRIP_STATUS}"
