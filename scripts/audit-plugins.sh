#!/usr/bin/env bash
# audit-plugins.sh — Headless harness for the claude-engineering-toolkit plugin audit
#
# Invoked by `./rebuild.sh audit-plugins` (D-05 thin wrapper). Run it directly via:
#   bash scripts/audit-plugins.sh <SANDBOX_NAME> <SHARED_DIR>
#
# What it does (D-04/D-07/D-08/D-09/D-10/D-11):
#   - Statically enumerates 11 agents + 6 skills with expected verdicts (D-08)
#   - Invokes each plugin headless via `openshell sandbox exec --no-tty --timeout 120`
#   - exit 124 = HANG = always FAIL (D-07)
#   - MUST_SUCCEED: exit 0 = PASS
#   - MUST_FAIL_CLEAN: exit 0 + network/MCP error in output = PASS;
#       exit 0 WITHOUT error = MISMATCH = FAIL (D-10 — no WARN escape)
#   - Any other case = FAIL
#   - Asserts zero claude.exe denial entries to statsig.anthropic.com and sentry.io (D-11)
#   - Documents mcp-proxy.anthropic.com and datadoghq.com denials as expected (policy working)
#   - VIOLATIONS counter: every FAIL increments it; script exits 1 if VIOLATIONS > 0 (D-10)
#   - NEVER evals plugin output (T-04-07 / threat mitigation)
#
# Usage:
#   bash scripts/audit-plugins.sh <SANDBOX_NAME> <SHARED_DIR>
#
# Arguments:
#   SANDBOX_NAME   Name of the running OpenShell sandbox (e.g. claude-sandbox)
#   SHARED_DIR     Working directory inside sandbox (e.g. /claudeshared)

set -euo pipefail

# Clean interrupt: if the operator Ctrl-C's mid-loop, exit with a clear message and the
# conventional 130 (SIGINT) rather than a bare set -e abort mid-invocation.
trap 'echo "" >&2; echo "ERROR: audit-plugins interrupted (SIGINT/SIGTERM) — partial run, no summary." >&2; exit 130' INT TERM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Argument parsing (fail-closed)
# ---------------------------------------------------------------------------
if [[ $# -lt 2 ]]; then
    echo "ERROR: Missing required arguments." >&2
    echo "Usage: $0 <SANDBOX_NAME> <SHARED_DIR>" >&2
    exit 1
fi

SANDBOX_NAME="$1"
SHARED_DIR="$2"

# ---------------------------------------------------------------------------
# Logging helpers (copy-pasted from rebuild.sh — self-contained, not sourced)
# ---------------------------------------------------------------------------
ts() { python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }

log_step() {
    echo "" >&2
    echo "=== [$(ts)] Step $1: $2 ===" >&2
}
log_info()  { echo "INFO: $1" >&2; }
log_error() { echo "ERROR: $1" >&2; }

# ---------------------------------------------------------------------------
# Static plugin enumeration (D-08)
# Verified against live toolkit: 11 agents + 6 skills
# Invoked with --dangerously-skip-permissions to match the autonomous `claude` verb
# (04-02) — without it, tool-executing reviewers/skills stall on permission prompts.
# All 11 agents MUST_SUCCEED: the 6 read-only reviewers analyze locally; lint/test/vuln
# run their Go tools against the go_egress allowlist (proxy.golang.org / sum.golang.org /
# vuln.go.dev) added in policy.yaml (Phase 4 / 04-03 audit enablement).
# jira-ticket, implement, my-work: MUST_FAIL_CLEAN — Jira/GitHub/Google APIs outside allowlist
# ---------------------------------------------------------------------------
declare -A AGENTS=(
    [api-contract-reviewer]="MUST_SUCCEED"
    [concurrency-reviewer]="MUST_SUCCEED"
    [db-query-reviewer]="MUST_SUCCEED"
    [db-schema-reviewer]="MUST_SUCCEED"
    [error-handling-reviewer]="MUST_SUCCEED"
    [integration-reviewer]="MUST_SUCCEED"
    [lint-reviewer]="MUST_SUCCEED"
    [performance-reviewer]="MUST_SUCCEED"
    [security-reviewer]="MUST_SUCCEED"
    [test-reviewer]="MUST_SUCCEED"
    [vuln-reviewer]="MUST_SUCCEED"
)

declare -A SKILLS=(
    [full-review]="MUST_SUCCEED"
    [review-fix-loop]="MUST_SUCCEED"
    [agent-readiness]="MUST_SUCCEED"
    [jira-ticket]="MUST_FAIL_CLEAN"
    [implement]="MUST_FAIL_CLEAN"
    [my-work]="MUST_FAIL_CLEAN"
)

# ---------------------------------------------------------------------------
# Violations counter (D-10 hard-fail gate)
# ---------------------------------------------------------------------------
VIOLATIONS=0
FAILED_PLUGINS=""

# ---------------------------------------------------------------------------
# run_plugin_audit — invoke one plugin headless and record verdict
# ---------------------------------------------------------------------------
# Arguments: sandbox_name, plugin_name, prompt, expected (MUST_SUCCEED or MUST_FAIL_CLEAN)
# Increments VIOLATIONS on any FAIL; never evals output (T-04-07).
# ---------------------------------------------------------------------------
run_plugin_audit() {
    local sandbox_name="$1"
    local plugin_name="$2"
    local prompt="$3"
    local expected="$4"

    local start_wall rc output
    start_wall=$(python3 -c 'import time; print(int(time.time()))')
    rc=0

    output=$(openshell sandbox exec \
        --name "${sandbox_name}" \
        --no-tty \
        --timeout 120 \
        --workdir "${SHARED_DIR}" \
        -- claude \
            --plugin-dir /opt/claude-engineering-toolkit \
            --dangerously-skip-permissions \
            -p "${prompt}" 2>&1) || rc=$?

    local end_wall wall_secs
    end_wall=$(python3 -c 'import time; print(int(time.time()))')
    wall_secs=$(( end_wall - start_wall ))

    if [[ ${rc} -eq 124 ]]; then
        # D-07: exit 124 = timeout = hang = always FAIL (no exception)
        echo "FAIL [HANG] ${plugin_name} (${wall_secs}s — timeout at 120s)"
        log_error "HANG: ${plugin_name} hit 120s timeout (exit 124)"
        VIOLATIONS=$(( VIOLATIONS + 1 ))
        FAILED_PLUGINS="${FAILED_PLUGINS} ${plugin_name}[HANG]"
        return 0
    fi

    if [[ "${expected}" == "MUST_SUCCEED" ]]; then
        if [[ ${rc} -eq 0 ]]; then
            echo "PASS [OK] ${plugin_name} (${wall_secs}s)"
        else
            # Any non-zero exit for a MUST_SUCCEED plugin is a FAIL
            echo "FAIL [UNEXPECTED] ${plugin_name}: expected success, rc=${rc} (${wall_secs}s)"
            log_error "UNEXPECTED: ${plugin_name} exited ${rc} (expected 0 for MUST_SUCCEED)"
            VIOLATIONS=$(( VIOLATIONS + 1 ))
            FAILED_PLUGINS="${FAILED_PLUGINS} ${plugin_name}[UNEXPECTED:rc=${rc}]"
        fi
        return 0
    fi

    if [[ "${expected}" == "MUST_FAIL_CLEAN" ]]; then
        if [[ ${rc} -eq 0 ]]; then
            # D-10: exit 0 alone is not a PASS — output MUST contain a network/MCP error pattern.
            # A MUST_FAIL_CLEAN plugin that exits 0 WITHOUT a clean network/MCP error is an
            # expected/actual MISMATCH → hard-fail (increment VIOLATIONS). No WARN escape.
            if echo "${output}" | grep -qiE "40[13]|connection refused|econnrefused|etimedout|ehostunreach|not available|tool.*not.*found|cannot connect|network unreachable|network error|fetch failed|request failed|unauthorized|mcp.*error|tool call failed"; then
                echo "PASS [FAIL_CLEAN] ${plugin_name} (${wall_secs}s)"
            else
                echo "FAIL [MISMATCH] ${plugin_name}: expected clean failure but exited 0 with no network/MCP error (${wall_secs}s)"
                log_error "MISMATCH: ${plugin_name} exited 0 but output contains no network/MCP error (D-10 violation)"
                echo "  Output snippet: ${output:0:200}" >&2
                VIOLATIONS=$(( VIOLATIONS + 1 ))
                FAILED_PLUGINS="${FAILED_PLUGINS} ${plugin_name}[MISMATCH]"
            fi
        else
            # Non-zero exit for MUST_FAIL_CLEAN — also a FAIL (unexpected error path)
            echo "FAIL [UNEXPECTED] ${plugin_name}: expected clean failure (exit 0 + error msg), rc=${rc} (${wall_secs}s)"
            log_error "UNEXPECTED: ${plugin_name} exited ${rc} (expected 0 with clean network/MCP error for MUST_FAIL_CLEAN)"
            VIOLATIONS=$(( VIOLATIONS + 1 ))
            FAILED_PLUGINS="${FAILED_PLUGINS} ${plugin_name}[UNEXPECTED:rc=${rc}]"
        fi
        return 0
    fi

    # Unknown expected value — fail closed
    echo "FAIL [CONFIG] ${plugin_name}: unknown expected verdict '${expected}'"
    log_error "CONFIG ERROR: ${plugin_name} has unrecognized expected verdict '${expected}'"
    VIOLATIONS=$(( VIOLATIONS + 1 ))
    FAILED_PLUGINS="${FAILED_PLUGINS} ${plugin_name}[CONFIG]"
    return 0
}

# ---------------------------------------------------------------------------
# check_telemetry_suppression (D-11/D-12)
# ---------------------------------------------------------------------------
# Asserts zero claude.exe denial entries for statsig and sentry.
# Documents mcp-proxy.anthropic.com and datadoghq.com denials as expected.
# since_arg: value for --since flag (e.g. "15m") scoped to this run window.
# ---------------------------------------------------------------------------
check_telemetry_suppression() {
    local sandbox_name="$1"
    local since_arg="$2"

    log_step "T" "Telemetry suppression check (since ${since_arg})"

    # Do NOT swallow a logs-fetch failure into an empty string — that would drop the
    # statsig/sentry counts to 0 and report a FALSE telemetry PASS (criterion #3 silently
    # not evaluated). A failed fetch is itself a violation.
    local log_output
    if ! log_output=$(openshell logs "${sandbox_name}" --source sandbox --since "${since_arg}" -n 2000 2>&1); then
        log_error "TELEMETRY: 'openshell logs ${sandbox_name}' failed — cannot assert telemetry suppression (criterion #3 NOT evaluated)"
        log_error "Output: ${log_output}"
        VIOLATIONS=$(( VIOLATIONS + 1 ))
        FAILED_PLUGINS="${FAILED_PLUGINS} telemetry[log-fetch-failed]"
        return 0
    fi

    # statsig and sentry MUST produce zero claude.exe denial entries (criterion #3).
    # grep -c prints the count (0 on no match) and exits 1 when 0 — `|| true` keeps that "0";
    # `${x:-0}` guards the rare grep-error (exit 2) empty-output case so the arithmetic test
    # below can never abort under `set -e`. (Do NOT use `|| echo 0` — grep already printed "0",
    # so that form would double-count to "0\n0".)
    local statsig_count sentry_count
    statsig_count=$(echo "${log_output}" | grep -c 'DENIED.*claude\.exe.*statsig' || true); statsig_count=${statsig_count:-0}
    sentry_count=$(echo "${log_output}" | grep -c 'DENIED.*claude\.exe.*sentry' || true); sentry_count=${sentry_count:-0}

    if [[ "${statsig_count}" -gt 0 ]]; then
        log_error "TELEMETRY FAIL: claude.exe attempted statsig.anthropic.com ${statsig_count} time(s) — not suppressed by CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
        echo "TELEMETRY FAIL: statsig.anthropic.com — ${statsig_count} claude.exe attempt(s) (criterion #3 violated)"
        VIOLATIONS=$(( VIOLATIONS + 1 ))
        FAILED_PLUGINS="${FAILED_PLUGINS} telemetry[statsig]"
    else
        log_info "TELEMETRY PASS: statsig.anthropic.com — 0 claude.exe attempts (suppressed by CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1)"
        echo "TELEMETRY PASS: statsig.anthropic.com — 0 claude.exe attempts"
    fi

    if [[ "${sentry_count}" -gt 0 ]]; then
        log_error "TELEMETRY FAIL: claude.exe attempted sentry.io ${sentry_count} time(s) — not suppressed by CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
        echo "TELEMETRY FAIL: sentry.io — ${sentry_count} claude.exe attempt(s) (criterion #3 violated)"
        VIOLATIONS=$(( VIOLATIONS + 1 ))
        FAILED_PLUGINS="${FAILED_PLUGINS} telemetry[sentry]"
    else
        log_info "TELEMETRY PASS: sentry.io — 0 claude.exe attempts (suppressed)"
        echo "TELEMETRY PASS: sentry.io — 0 claude.exe attempts"
    fi

    # Document expected denials (informational only — policy is working correctly)
    local mcp_proxy_count datadog_count downloads_count
    mcp_proxy_count=$(echo "${log_output}" | grep -c 'DENIED.*claude\.exe.*mcp-proxy\.anthropic\.com' || true); mcp_proxy_count=${mcp_proxy_count:-0}
    datadog_count=$(echo "${log_output}" | grep -c 'DENIED.*claude\.exe.*datadoghq\.com' || true); datadog_count=${datadog_count:-0}
    downloads_count=$(echo "${log_output}" | grep -c 'DENIED.*claude\.exe.*downloads\.claude\.ai' || true); downloads_count=${downloads_count:-0}

    log_info "TELEMETRY INFO: mcp-proxy.anthropic.com denied ${mcp_proxy_count} time(s) — MCP registry lookup, policy working correctly"
    log_info "TELEMETRY INFO: datadoghq.com denied ${datadog_count} time(s) — logging endpoint, policy working correctly"
    echo "TELEMETRY INFO: mcp-proxy.anthropic.com — ${mcp_proxy_count} denial(s) (expected, policy working)"
    echo "TELEMETRY INFO: datadoghq.com — ${datadog_count} denial(s) (expected, policy working)"
    if [[ "${downloads_count}" -gt 0 ]]; then
        log_info "TELEMETRY INFO: downloads.claude.ai denied ${downloads_count} time(s) — auto-update check, policy working correctly"
        echo "TELEMETRY INFO: downloads.claude.ai — ${downloads_count} denial(s) (expected, policy working)"
    else
        echo "TELEMETRY INFO: downloads.claude.ai — 0 denials (suppressed by CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1)"
    fi
}

# ---------------------------------------------------------------------------
# Main audit flow
# ---------------------------------------------------------------------------

RUN_START_EPOCH=$(python3 -c 'import time; print(int(time.time()))')
RUN_START_TS=$(ts)

log_step 1 "Plugin audit — ${SANDBOX_NAME} — $(date -u '+%Y-%m-%d')"
log_info "Sandbox: ${SANDBOX_NAME}"
log_info "Working dir: ${SHARED_DIR}"
log_info "Plugin dir: /opt/claude-engineering-toolkit"
log_info "Timeout per invocation: 120s"
log_info "AGENTS: ${!AGENTS[*]}"
log_info "SKILLS: ${!SKILLS[*]}"

echo ""
echo "=== Plugin Audit Results ==="
echo "| Plugin | Type | Expected | Exit | Wall(s) | Verdict |"
echo "| ------ | ---- | -------- | ---- | ------- | ------- |"

# ---------------------------------------------------------------------------
# Step 2: Agent invocations
# ---------------------------------------------------------------------------
log_step 2 "Agent invocations (11 agents)"

for agent_name in "${!AGENTS[@]}"; do
    expected="${AGENTS[${agent_name}]}"
    prompt="Run @${agent_name} on the current directory"
    log_info "Invoking agent: ${agent_name} (expected: ${expected})"
    run_plugin_audit "${SANDBOX_NAME}" "${agent_name}" "${prompt}" "${expected}"
done

# ---------------------------------------------------------------------------
# Step 3: Skill invocations
# ---------------------------------------------------------------------------
log_step 3 "Skill invocations (6 skills)"

for skill_name in "${!SKILLS[@]}"; do
    expected="${SKILLS[${skill_name}]}"
    prompt="Run /${skill_name}"
    log_info "Invoking skill: ${skill_name} (expected: ${expected})"
    run_plugin_audit "${SANDBOX_NAME}" "${skill_name}" "${prompt}" "${expected}"
done

# ---------------------------------------------------------------------------
# Step 4: Telemetry suppression check (D-11/D-12)
# ---------------------------------------------------------------------------
# Compute elapsed minutes since run start for --since window (add 1 min buffer)
RUN_END_EPOCH=$(python3 -c 'import time; print(int(time.time()))')
ELAPSED_SECS=$(( RUN_END_EPOCH - RUN_START_EPOCH ))
SINCE_MINS=$(( ELAPSED_SECS / 60 + 2 ))
SINCE_ARG="${SINCE_MINS}m"

log_step 4 "Telemetry suppression check (D-11)"
check_telemetry_suppression "${SANDBOX_NAME}" "${SINCE_ARG}"

# ---------------------------------------------------------------------------
# Step 5: Hard-fail gate (D-10)
# ---------------------------------------------------------------------------
log_step 5 "Hard-fail gate (D-10)"
echo ""
echo "=== Audit Summary ==="

if [[ "${VIOLATIONS}" -gt 0 ]]; then
    log_error "AUDIT FAIL: ${VIOLATIONS} violation(s) found — hard-fail exit 1 (D-10)"
    log_error "Failed plugins/checks:${FAILED_PLUGINS}"
    echo "AUDIT FAIL: ${VIOLATIONS} violation(s)"
    echo "Failed:${FAILED_PLUGINS}"
    exit 1
fi

log_info "AUDIT PASS: All ${#AGENTS[@]} agents + ${#SKILLS[@]} skills reached expected terminal states; telemetry suppressed"
echo "AUDIT PASS: 0 violations — all plugins + telemetry checks passed"
echo "  Agents checked: ${#AGENTS[@]}"
echo "  Skills checked: ${#SKILLS[@]}"
echo "  Run start: ${RUN_START_TS}"
echo "  Run end:   $(ts)"
exit 0
