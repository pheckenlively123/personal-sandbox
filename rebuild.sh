#!/usr/bin/env bash
# rebuild.sh — Idempotent top-level orchestrator for the claude-sandbox lifecycle.
#
# Usage:
#   ./rebuild.sh [rebuild] [--cooldown-days N]   # Full clean rebuild (default)
#   ./rebuild.sh status                           # Status summary (read-only)
#   ./rebuild.sh connect                          # Attach to running sandbox shell
#   ./rebuild.sh login                            # Connect + launch Claude OAuth login flow
#   ./rebuild.sh claude                           # Launch autonomous Claude session (--dangerously-skip-permissions + --plugin-dir)
#   ./rebuild.sh down                             # Delete sandbox (idempotent)
#   ./rebuild.sh audit [--since <ts>]             # Surface openshell logs
#   ./rebuild.sh audit-plugins                    # Strict headless plugin audit (hard-fails on mismatch)
#
# Architecture B — hardened to claude-egress-allowlist direct egress:
#   - Claude Code runs INSIDE the sandbox and connects DIRECTLY to the three Claude hosts:
#     api.anthropic.com (inference), platform.claude.com (Console auth), claude.ai (auth)
#   - Subscription OAuth login: `./rebuild.sh login` → open URL in browser OUTSIDE the
#     sandbox → paste the returned code into the in-sandbox prompt. One-time per session.
#   - No inference.local gateway. No ANTHROPIC_API_KEY. No host-side provider setup.
#   - The sandbox policy allows the three Claude auth/API hosts (TLS passthrough,
#     binary-scoped to /usr/bin/claude and /usr/local/bin/claude) AND, via a separate
#     go_egress policy, three Go-toolchain hosts (proxy.golang.org, sum.golang.org,
#     vuln.go.dev) binary-scoped to /usr/bin/go, /usr/bin/golangci-lint, and
#     /usr/local/bin/govulncheck. All other egress denied.
#   - CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 keeps statsig/sentry/downloads unused.
#   - On-the-fly model selection via Claude's native /model command (Opus/Sonnet/Haiku).
#
# Steps (rebuild verb):
#   1. Preflight — verify required tools are on PATH
#   2. Resolve cooldown versions and build container image (delegates to build-and-lock.sh)
#   3. Tag :latest alias
#   4. Teardown existing sandbox and images (tolerate-absent — idempotent)
#   4.5 RUN-05 — Preflight: verify host gateway enables bind mounts (fail-closed,
#       read-only; delegates to scripts/preflight-gateway-bind-mount.sh)
#   5. Create sandbox with ~/claudeshared bind mount and policy.yaml
#   6. NET-04: Assert effective live policy = all 3 claude-egress hosts present, passthrough,
#      claude-scoped, no statsig.anthropic.com, no sentry.io (FATAL)
#   7. NET-05: In-sandbox curl — assert deny posture ONLY (statsig/sentry/google BLOCKED);
#      claude-host reachability validated functionally by ./rebuild.sh login (FATAL)
#
# Decisions:
#   D-01: Full clean rebuild every run (tear down existing sandbox + images before create)
#   D-02: Tolerate-absent teardown — absent sandbox/images are not errors
#   D-03: Tag :latest alias after date-pinned build
#   D-05: Subprocess delegation — rebuild.sh does not re-implement version resolution
#   D-07: audit verb is log-surfacing only; never asserts policy

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Logging helpers (BLD-04 / D-07)
# ---------------------------------------------------------------------------
ts() { python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }

log_step() {
    echo "" >&2
    echo "=== [$(ts)] Step $1: $2 ===" >&2
}
log_info()  { echo "INFO: $1" >&2; }
log_error() { echo "ERROR: $1" >&2; }

# ---------------------------------------------------------------------------
# Portable podman readiness (Finding 8 — machine-detect + systemctl fallback)
# ---------------------------------------------------------------------------
# Detects whether we are on a machine-based host (macOS) or a native Linux host.
# macOS: podman machine inspect/start path.
# Linux/Fedora: systemctl --user start podman.socket (best effort).
# Either way, `podman info` is the final readiness gate.
ensure_podman_ready() {
    local machine_list
    machine_list=$(podman machine list --format '{{.Name}}' 2>/dev/null || true)

    if [[ -n "${machine_list}" ]]; then
        # macOS / machine-based host
        local podman_state rc_inspect=0
        podman_state=$(podman machine inspect --format '{{.State}}' 2>/dev/null) || rc_inspect=$?
        if [[ ${rc_inspect} -ne 0 || "${podman_state}" != "running" ]]; then
            log_info "Podman machine not running (state=${podman_state:-unknown}); starting..."
            podman machine start
            local rc_recheck=0
            podman_state=$(podman machine inspect --format '{{.State}}' 2>/dev/null) || rc_recheck=$?
            if [[ ${rc_recheck} -ne 0 || "${podman_state}" != "running" ]]; then
                log_error "Podman machine failed to start (state=${podman_state:-unknown})."
                log_error "Try: podman machine start"
                exit 1
            fi
        fi
        log_info "Podman machine is running"
    else
        # Native Linux / Fedora host — start the user socket (best effort; may already be active)
        systemctl --user start podman.socket 2>/dev/null || true
        log_info "Podman socket start attempted (Linux native host)"
    fi

    # Final gate regardless of platform
    if ! podman info >/dev/null 2>&1; then
        log_error "Podman is not ready (podman info failed)."
        log_error "On Linux: systemctl --user start podman.socket (may need: loginctl enable-linger \$USER)"
        log_error "On macOS: podman machine start"
        exit 1
    fi
    log_info "Podman is ready"
}

# ---------------------------------------------------------------------------
# NET-04 live policy assertion — claude_egress + go_egress allowlists, passthrough, scoped
# ---------------------------------------------------------------------------
# Asserts the live effective sandbox policy:
#   PASS requires: api.anthropic.com:443, platform.claude.com:443, claude.ai:443 (claude-scoped)
#                  AND proxy.golang.org:443, sum.golang.org:443, vuln.go.dev:443 (go-scoped),
#                  all with no `protocol` field (passthrough); statsig.anthropic.com ABSENT,
#                  sentry.io ABSENT.
#   FAIL on any violation — fatal (exit 1).
assert_claude_egress_allowlist() {
    local sandbox_name="${1}"
    local policy_json
    # Guard the fetch: a failed or non-JSON `openshell policy get` must report itself, not
    # silently feed garbage to the jq checks below (which would misfire as "host NOT found").
    if ! policy_json=$(openshell policy get "${sandbox_name}" --full -o json 2>&1); then
        log_error "NET-04: 'openshell policy get ${sandbox_name} --full -o json' failed — cannot assert policy"
        log_error "Output: ${policy_json}"
        exit 1
    fi
    if ! echo "${policy_json}" | jq empty >/dev/null 2>&1; then
        log_error "NET-04: policy output is not valid JSON — sandbox may not be running or the policy endpoint errored"
        log_error "Raw output: ${policy_json}"
        exit 1
    fi

    # --- Require all three Claude auth/API hosts to be present ---
    local -a required_hosts=("api.anthropic.com" "platform.claude.com" "claude.ai")
    for req_host in "${required_hosts[@]}"; do
        if ! echo "${policy_json}" | jq -e \
            --arg h "${req_host}" \
            '.policy.network_policies // {} | to_entries[] | .value.endpoints[]? | select(.host == $h and .port == 443)' \
            >/dev/null 2>&1; then
            log_error "NET-04 VIOLATION: ${req_host}:443 NOT found in effective policy — passthrough allow missing!"
            log_error "Policy output: ${policy_json}"
            exit 1
        fi
        log_info "NET-04: ${req_host}:443 present in policy"

        # --- Require NO protocol field on this host (passthrough = omit protocol) ---
        if echo "${policy_json}" | jq -e \
            --arg h "${req_host}" \
            '.policy.network_policies // {} | to_entries[] | .value.endpoints[]? | select(.host == $h) | select(.protocol != null)' \
            >/dev/null 2>&1; then
            log_error "NET-04 VIOLATION: ${req_host} endpoint has a 'protocol' field — must be omitted for TLS passthrough!"
            log_error "Policy output: ${policy_json}"
            exit 1
        fi
        log_info "NET-04: ${req_host} endpoint has no 'protocol' field (opaque passthrough confirmed)"
    done

    # --- Require at least one binary scoped to */claude (check via api.anthropic.com policy entry) ---
    if ! echo "${policy_json}" | jq -e \
        '.policy.network_policies // {} | to_entries[] | .value | select(.endpoints[]? | .host == "api.anthropic.com") | .binaries[]? | select(.path | test(".*/claude$"))' \
        >/dev/null 2>&1; then
        log_error "NET-04 VIOLATION: claude-egress policy has no binary entry matching */claude!"
        log_error "Policy output: ${policy_json}"
        exit 1
    fi
    log_info "NET-04: Binary-scoped to claude confirmed"

    # --- Require statsig.anthropic.com ABSENT ---
    if echo "${policy_json}" | jq -e \
        '.policy.network_policies // {} | to_entries[] | .value.endpoints[]? | select(.host | test("statsig"; "i"))' \
        >/dev/null 2>&1; then
        log_error "NET-04 VIOLATION: statsig.anthropic.com found in effective policy — must be absent!"
        log_error "Policy output: ${policy_json}"
        exit 1
    fi
    log_info "NET-04: statsig.anthropic.com absent (telemetry blocked)"

    # --- Require sentry.io ABSENT ---
    if echo "${policy_json}" | jq -e \
        '.policy.network_policies // {} | to_entries[] | .value.endpoints[]? | select(.host | test("sentry"; "i"))' \
        >/dev/null 2>&1; then
        log_error "NET-04 VIOLATION: sentry.io found in effective policy — must be absent!"
        log_error "Policy output: ${policy_json}"
        exit 1
    fi
    log_info "NET-04: sentry.io absent (error-reporting blocked)"

    # --- Require the Go-toolchain egress hosts present, passthrough, go-scoped (Phase 4) ---
    local -a required_go_hosts=("proxy.golang.org" "sum.golang.org" "vuln.go.dev")
    for go_host in "${required_go_hosts[@]}"; do
        if ! echo "${policy_json}" | jq -e \
            --arg h "${go_host}" \
            '.policy.network_policies // {} | to_entries[] | .value.endpoints[]? | select(.host == $h and .port == 443)' \
            >/dev/null 2>&1; then
            log_error "NET-04 VIOLATION: ${go_host}:443 NOT found in effective policy — go_egress allow missing!"
            log_error "Policy output: ${policy_json}"
            exit 1
        fi
        if echo "${policy_json}" | jq -e \
            --arg h "${go_host}" \
            '.policy.network_policies // {} | to_entries[] | .value.endpoints[]? | select(.host == $h) | select(.protocol != null)' \
            >/dev/null 2>&1; then
            log_error "NET-04 VIOLATION: ${go_host} endpoint has a 'protocol' field — must be omitted for TLS passthrough!"
            log_error "Policy output: ${policy_json}"
            exit 1
        fi
        log_info "NET-04: ${go_host}:443 present, no 'protocol' field (opaque passthrough confirmed)"
    done

    # --- Require the go_egress policy scoped to the Go toolchain (NOT the claude binary) ---
    if ! echo "${policy_json}" | jq -e \
        '.policy.network_policies // {} | to_entries[] | .value | select(.endpoints[]? | .host == "proxy.golang.org") | .binaries[]? | select(.path | test("/(go|golangci-lint|govulncheck)$"))' \
        >/dev/null 2>&1; then
        log_error "NET-04 VIOLATION: go_egress policy has no binary entry scoped to the Go toolchain!"
        log_error "Policy output: ${policy_json}"
        exit 1
    fi
    log_info "NET-04: Go hosts binary-scoped to the Go toolchain confirmed"

    # --- Enforce OAuth-token isolation (CLAUDE.md security model): no cross-scoping. ---
    # The policy containing the Claude hosts must NOT list a Go-toolchain binary, and the
    # policy containing the Go hosts must NOT list a */claude binary. Without these negative
    # assertions the isolation claim is assumed, not enforced (a stray binary would still PASS).
    if echo "${policy_json}" | jq -e \
        '.policy.network_policies // {} | to_entries[] | .value | select(.endpoints[]? | .host == "api.anthropic.com") | .binaries[]? | select(.path | test("/(go|golangci-lint|govulncheck)$"))' \
        >/dev/null 2>&1; then
        log_error "NET-04 VIOLATION: a Go-toolchain binary is scoped to the Claude (api.anthropic.com) egress policy — OAuth-token isolation broken!"
        log_error "Policy output: ${policy_json}"
        exit 1
    fi
    if echo "${policy_json}" | jq -e \
        '.policy.network_policies // {} | to_entries[] | .value | select(.endpoints[]? | .host == "proxy.golang.org") | .binaries[]? | select(.path | test(".*/claude$"))' \
        >/dev/null 2>&1; then
        log_error "NET-04 VIOLATION: the claude binary is scoped to the go_egress policy — egress separation broken!"
        log_error "Policy output: ${policy_json}"
        exit 1
    fi
    log_info "NET-04: cross-scoping isolation confirmed (claude hosts not go-scoped; go hosts not claude-scoped)"

    log_info "NET-04 PASS: claude_egress (api.anthropic.com, platform.claude.com, claude.ai — claude-scoped) + go_egress (proxy.golang.org, sum.golang.org, vuln.go.dev — go-scoped); all :443 passthrough; statsig+sentry absent"
}

# ---------------------------------------------------------------------------
# NET-05 egress smoke test — deny posture only (Finding 5; redesigned post-login-debugging)
# ---------------------------------------------------------------------------
# Asserts that non-allowlisted hosts are BLOCKED from inside the sandbox.
# curl is NOT the claude binary — binary-scoping prevents curl from reaching ANY host,
# including api.anthropic.com. Reachability of the Claude auth/API hosts is validated
# functionally by `./rebuild.sh login` (the claude binary), NOT by curl.
#
# Blocked targets (each must fail to connect):
#   statsig.anthropic.com → BLOCKED (telemetry — intentionally absent from allowlist)
#   sentry.io             → BLOCKED (error-reporting — intentionally absent)
#   www.google.com        → BLOCKED (open internet — proves deny-all-except-allowlist)
#
# curl exit != 0 OR status 000/empty = proxy denied = PASS.
# curl exit 0  AND non-000 status    = proxy allowed = FAIL (deny-all is broken).
run_egress_smoke_test() {
    local sandbox_name="${1}"

    log_info "NET-05: Anthropic auth/API host reachability is validated by './rebuild.sh login' (claude binary)."
    log_info "NET-05: curl is not the claude binary — binary-scoping blocks curl from reaching ANY host."
    log_info "NET-05: Asserting deny posture only (non-allowlisted hosts must be blocked)..."

    # --- Blocked targets: each must fail to connect ---
    local -a blocked_targets=("https://statsig.anthropic.com" "https://sentry.io" "https://www.google.com")
    for target in "${blocked_targets[@]}"; do
        local rc=0 status=""
        status=$(openshell sandbox exec --name "${sandbox_name}" --no-tty \
            -- curl -sS -o /dev/null -w '%{http_code}' --max-time 8 \
            "${target}" 2>/dev/null) || rc=$?

        if [[ ${rc} -eq 0 && -n "${status}" && "${status}" != "000" ]]; then
            log_error "NET-05 VIOLATION: Egress to ${target} SUCCEEDED (HTTP ${status}) — deny-all is broken!"
            exit 1
        fi
        log_info "NET-05 PASS: ${target} blocked (curl exit ${rc}, status='${status}')"
    done

    log_info "NET-05 PASS: All non-allowlisted targets confirmed denied"
}

# ---------------------------------------------------------------------------
# Audit verb (D-07 — log-surfacing only)
# ---------------------------------------------------------------------------
audit_sandbox() {
    local name="${1:-claude-sandbox}"
    local since="${2:-}"
    local since_arg=""
    [[ -n "${since}" ]] && since_arg="--since ${since}"
    # shellcheck disable=SC2086
    openshell logs "${name}" ${since_arg} --source all
}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
COOLDOWN_DAYS=4
SANDBOX_NAME="claude-sandbox"
SHARED_DIR="/claudeshared"   # in-sandbox mount target for the host bind mount; default cwd
                             # for connect/login (clone + work on repos here)
VERB="rebuild"    # default verb

# ---------------------------------------------------------------------------
# Verb-first argument parsing
# ---------------------------------------------------------------------------
# Accept positional verb as first argument; flags follow.
if [[ $# -gt 0 ]]; then
    case "$1" in
        rebuild|status|connect|login|claude|down|audit|audit-plugins)
            VERB="$1"
            shift
            ;;
        --cooldown-days|--cooldown-days=*|--audit)
            # Backward-compat: flag-first form with no explicit verb → verb=rebuild
            VERB="rebuild"
            ;;
        *)
            log_error "Unknown verb or argument: $1"
            echo "Usage: $0 [rebuild|status|connect|login|claude|down|audit|audit-plugins] [--cooldown-days N]" >&2
            echo "       $0 [--cooldown-days N]   (shorthand for rebuild)" >&2
            echo "       $0 --audit               (shorthand for audit verb)" >&2
            exit 1
            ;;
    esac
fi

AUDIT_SINCE=""
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
            # Backward-compat alias: treat as the audit verb redirect
            VERB="audit"
            shift
            ;;
        --since)
            if [[ -z "${2-}" ]]; then
                log_error "--since requires an argument"
                exit 1
            fi
            AUDIT_SINCE="$2"
            shift 2
            ;;
        --since=*)
            AUDIT_SINCE="${1#--since=}"
            shift
            ;;
        *)
            log_error "Unknown argument: $1"
            echo "Usage: $0 [rebuild|status|connect|login|claude|down|audit|audit-plugins] [--cooldown-days N]" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight: verify required tools are on PATH (fail-closed; skip for connect/login/down)
# ---------------------------------------------------------------------------
preflight_tools() {
    for cmd in podman openshell python3 jq; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            log_error "Required tool not found on PATH: ${cmd}"
            exit 1
        fi
    done
    log_info "Preflight passed — all required tools found"
}

# ---------------------------------------------------------------------------
# Verb dispatch
# ---------------------------------------------------------------------------

case "${VERB}" in

    # -----------------------------------------------------------------------
    # status — read-only summary (podman + openshell + sandbox + effective policy)
    # -----------------------------------------------------------------------
    status)
        preflight_tools
        log_info "=== Status summary (read-only) ==="
        log_info "Checking podman..."
        podman info --format 'Host: {{.Host.OS}}/{{.Host.Arch}}, Store: {{.Store.GraphDriver}}' 2>/dev/null \
            || log_info "  podman not ready"
        log_info "Checking sandbox ${SANDBOX_NAME}..."
        openshell sandbox list --names 2>/dev/null | grep "^${SANDBOX_NAME}$" \
            && log_info "  Sandbox ${SANDBOX_NAME}: EXISTS" \
            || log_info "  Sandbox ${SANDBOX_NAME}: not found"
        log_info "Checking effective policy (if sandbox exists)..."
        openshell policy get "${SANDBOX_NAME}" --full -o json 2>/dev/null \
            | jq '.policy.network_policies // {} | keys' 2>/dev/null \
            || log_info "  (policy unavailable — sandbox may not exist)"
        exit 0
        ;;

    # -----------------------------------------------------------------------
    # connect — attach to running sandbox interactive shell
    # -----------------------------------------------------------------------
    connect)
        # `openshell sandbox connect` has no working-directory flag and drops you at /,
        # which is not in the Landlock allowlist (can't even `ls`). Use `exec --tty
        # --workdir` instead to land in the host-shared dir, where the operator clones
        # and works on repos. /claudeshared is the bind mount (read_write in policy.yaml).
        log_info "Connecting to sandbox ${SANDBOX_NAME} (cwd: ${SHARED_DIR})..."
        openshell sandbox exec --name "${SANDBOX_NAME}" --tty --workdir "${SHARED_DIR}" -- /bin/bash
        exit 0
        ;;

    # -----------------------------------------------------------------------
    # login — connect + guide operator through in-sandbox OAuth login
    # -----------------------------------------------------------------------
    login)
        ensure_podman_ready
        log_info "Launching Claude OAuth login inside ${SANDBOX_NAME}."
        log_info "When Claude prints a login URL:"
        log_info "  1. Open the URL in a browser OUTSIDE the sandbox"
        log_info "  2. Authenticate with your Claude subscription"
        log_info "  3. Copy and paste the returned code into the in-sandbox prompt"
        log_info "The token is stored at ~/.claude/.credentials.json INSIDE the sandbox."
        log_info "Connecting to sandbox (cwd: ${SHARED_DIR}) — run 'claude' inside to begin OAuth flow..."
        openshell sandbox exec --name "${SANDBOX_NAME}" --tty --workdir "${SHARED_DIR}" -- /bin/bash
        exit 0
        ;;

    # -----------------------------------------------------------------------
    # claude — launch autonomous Claude session (D-01/D-02, RUN-01/RUN-02)
    # -----------------------------------------------------------------------
    # Execs claude --dangerously-skip-permissions --plugin-dir /opt/claude-engineering-toolkit
    # inside the running sandbox via openshell sandbox exec --tty --workdir /claudeshared.
    # Mirrors the connect/login exec pattern (D-01). No OAuth precondition check (D-02) —
    # claude handles the unauthenticated case itself (prints its own login prompt).
    # Prerequisites: sandbox created (./rebuild.sh) + OAuth login (./rebuild.sh login).
    claude)
        ensure_podman_ready
        log_info "Launching Claude Code autonomously in sandbox ${SANDBOX_NAME} (cwd: ${SHARED_DIR})..."
        log_info "Plugin dir: /opt/claude-engineering-toolkit"
        log_info "Prerequisites: sandbox created (./rebuild.sh) + OAuth login (./rebuild.sh login)"
        # Interactive TTY session: preserve claude's real exit code (normal /exit -> 0,
        # Ctrl-C -> 130) instead of forcing exit 1. Only emit the sandbox-health hint for a
        # genuine failure — not a routine user interrupt.
        set +e
        openshell sandbox exec \
            --name "${SANDBOX_NAME}" \
            --tty \
            --workdir "${SHARED_DIR}" \
            -- claude \
                --dangerously-skip-permissions \
                --plugin-dir /opt/claude-engineering-toolkit
        exec_rc=$?
        set -e
        if [[ ${exec_rc} -ne 0 && ${exec_rc} -ne 130 ]]; then
            log_error "'openshell sandbox exec' for sandbox '${SANDBOX_NAME}' exited ${exec_rc} — if the session didn't start, check './rebuild.sh status' / './rebuild.sh login'."
        fi
        exit "${exec_rc}"
        ;;

    # -----------------------------------------------------------------------
    # down — idempotent sandbox delete (no native stop; down = delete)
    # -----------------------------------------------------------------------
    down)
        log_info "Deleting sandbox ${SANDBOX_NAME} (idempotent)..."
        DELETE_OUT=$(openshell sandbox delete "${SANDBOX_NAME}" 2>&1) && true
        DELETE_RC=$?
        if [[ ${DELETE_RC} -ne 0 ]]; then
            # openshell wraps long error text across lines with box-drawing chars, so
            # "sandbox not found" can be split (e.g. 'sandbox not\n  | found'). Normalize
            # to alphanumerics+whitespace and collapse before matching the not-found case.
            DELETE_NORM=$(printf '%s' "${DELETE_OUT}" | tr -dc '[:alnum:][:space:]' | tr -s '[:space:]' ' ')
            if printf '%s' "${DELETE_NORM}" | grep -qi "not found"; then
                log_info "Sandbox ${SANDBOX_NAME} not found — nothing to delete (idempotent)"
            else
                log_error "openshell sandbox delete failed: ${DELETE_OUT}"
                exit 1
            fi
        else
            log_info "Sandbox ${SANDBOX_NAME} deleted"
        fi
        exit 0
        ;;

    # -----------------------------------------------------------------------
    # audit — surface openshell logs (BLD-05 / D-07)
    # -----------------------------------------------------------------------
    audit)
        log_info "Surfacing openshell logs for ${SANDBOX_NAME} (audit — no build/teardown/create)"
        audit_sandbox "${SANDBOX_NAME}" "${AUDIT_SINCE}"
        exit 0
        ;;

    # -----------------------------------------------------------------------
    # audit-plugins — strict headless plugin audit (D-05)
    # -----------------------------------------------------------------------
    # Distinct from the log-surfacing `audit` verb: this drives every toolkit
    # agent + skill headless against the running sandbox and HARD-FAILS (exit 1)
    # on any expected/actual mismatch (D-10). Thin wrapper over the harness.
    # Prerequisites: sandbox Ready + OAuth'd (./rebuild.sh + ./rebuild.sh login).
    audit-plugins)
        log_info "Running strict headless plugin audit for ${SANDBOX_NAME} (hard-fails on any mismatch — distinct from the log-surfacing 'audit' verb)"
        bash "${PROJECT_ROOT}/scripts/audit-plugins.sh" "${SANDBOX_NAME}" "${SHARED_DIR}"
        exit 0
        ;;

    # -----------------------------------------------------------------------
    # rebuild — full clean rebuild (default)
    # -----------------------------------------------------------------------
    rebuild)
        preflight_tools
        ensure_podman_ready
        ;;

    *)
        log_error "Internal error: unhandled verb '${VERB}'"
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Below: rebuild path only
# ---------------------------------------------------------------------------

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
    # openshell wraps long error text across lines with box-drawing chars, so
    # "sandbox not found" can be split (e.g. 'sandbox not\n  | found'). Normalize
    # to alphanumerics+whitespace and collapse before matching the not-found case.
    DELETE_NORM=$(printf '%s' "${DELETE_OUT}" | tr -dc '[:alnum:][:space:]' | tr -s '[:space:]' ' ')
    if printf '%s' "${DELETE_NORM}" | grep -qi "not found"; then
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
# Step 3.5: RUN-05 — Preflight gateway bind-mount config (D-05 delegation)
# Fail-closed BEFORE Step 4: the ~/claudeshared bind mount (RUN-03/RUN-04) is
# unusable unless the host gateway sets enable_bind_mounts = true under
# [openshell.drivers.podman]. The delegated script is READ-ONLY (never modifies
# host config / restarts the gateway) and exits 1 with remediation if unset; the
# set -e propagation aborts the rebuild here, before `openshell sandbox create`
# fails cryptically inside podman.
# ---------------------------------------------------------------------------
log_step 3.5 "RUN-05 — Preflight: gateway bind-mount enabled"
bash "${PROJECT_ROOT}/scripts/preflight-gateway-bind-mount.sh"

# ---------------------------------------------------------------------------
# Step 4: Create sandbox with bind mount and policy (RUN-03/RUN-04, BLD-06)
# ---------------------------------------------------------------------------
log_step 4 "Create sandbox"

CLAUDESHARED_ABS="${HOME}/claudeshared"
mkdir -p "${CLAUDESHARED_ABS}"

# Stage zero-egress CLAUDE.md if absent (idempotent — never overwrites an existing file)
if [[ ! -f "${CLAUDESHARED_ABS}/CLAUDE.md" ]]; then
    cp "${PROJECT_ROOT}/templates/CLAUDE.md" "${CLAUDESHARED_ABS}/CLAUDE.md"
    log_info "Staged CLAUDE.md into ${CLAUDESHARED_ABS}/"
else
    log_info "CLAUDE.md already present in ${CLAUDESHARED_ABS}/ — not overwriting"
fi

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
# policy.yaml carries the claude-egress allowlist (api.anthropic.com + platform.claude.com + claude.ai — architecture B-hardened)
openshell sandbox create \
    --name "${SANDBOX_NAME}" \
    --from "localhost/claude-sandbox:${BUILD_DATE}" \
    --policy "${PROJECT_ROOT}/policy.yaml" \
    --driver-config-json "{\"podman\":{\"mounts\":[{\"type\":\"bind\",\"source\":\"${CLAUDESHARED_ABS}\",\"target\":\"${SHARED_DIR}\",\"read_only\":false}]}}" \
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
# Step 5: Assert claude-egress allowlist — all 3 hosts, passthrough, claude-scoped (NET-04)
# ---------------------------------------------------------------------------
log_step 5 "NET-04 — Assert claude-egress allowlist in live policy (3 hosts, passthrough, claude-scoped)"
assert_claude_egress_allowlist "${SANDBOX_NAME}"

# ---------------------------------------------------------------------------
# Step 6: Egress smoke test — deny posture only (NET-05)
# ---------------------------------------------------------------------------
log_step 6 "NET-05 — Egress smoke test: deny posture (statsig/sentry/google blocked)"
run_egress_smoke_test "${SANDBOX_NAME}"

echo "" >&2
log_info "rebuild.sh complete — sandbox ${SANDBOX_NAME} is Ready"
log_info "  Image:          localhost/claude-sandbox:${BUILD_DATE}"
log_info "  Bind mount:     ${CLAUDESHARED_ABS} -> /claudeshared (read-write)"
log_info "  Policy:         ${PROJECT_ROOT}/policy.yaml"
log_info "  NET-04:         PASS (api.anthropic.com + platform.claude.com + claude.ai — :443 passthrough, claude-scoped; statsig+sentry absent)"
log_info "  NET-05:         PASS (deny posture: statsig/sentry/google blocked; claude-host reachability via ./rebuild.sh login)"
log_info ""
log_info "Next step — subscription OAuth login (one-time per session):"
log_info "  ./rebuild.sh login"
log_info "  (open the URL in a browser OUTSIDE the sandbox, paste the code back)"
log_info ""
log_info "Other verbs:"
log_info "  ./rebuild.sh connect   # attach to sandbox shell"
log_info "  ./rebuild.sh claude    # launch autonomous Claude session (--dangerously-skip-permissions + plugin-dir)"
log_info "  ./rebuild.sh audit     # surface openshell logs"
log_info "  ./rebuild.sh down      # delete sandbox (re-login required after next rebuild)"
