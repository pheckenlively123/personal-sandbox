# Phase 3: Network Isolation and Inference Validation - Research

**Researched:** 2026-06-16
**Domain:** OpenShell network policy enforcement, inference.local gateway brokering, rebuild.sh gate patterns
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01**: Zero-egress is enforced via the OpenShell `network_policies` mechanism at `sandbox create` time. The existing `policy.yaml` stays filesystem-only — do NOT add a network section to it. Network and filesystem isolation remain cleanly separated concerns.
- **D-02**: `rebuild.sh` asserts the absence of `api.anthropic.com` by querying the live created sandbox — `openshell policy get <sandbox>` after create — not by grepping the source policy file.
- **D-03**: `rebuild.sh` runs `openshell inference get` as a preflight before `sandbox create` and exits with a clear, actionable error if the provider is not registered.
- **D-04**: `rebuild.sh` is preflight-assert-only — it does NOT create or refresh the provider. The one-time `openshell provider create` and `openshell provider refresh` are explicit operator actions documented in README.
- **D-05**: The egress smoke test BLOCKS — `rebuild.sh` executes an outbound request from inside the running sandbox and exits non-zero if it unexpectedly succeeds.
- **D-06**: `rebuild.sh` also fires one automated model round-trip through `inference.local` as a non-fatal sanity check that reports pass/fail but does not block.
- **D-07**: The full multi-turn interactive session (criterion #2) is an operator step documented in README, not automated.

### Claude's Discretion

- **Smoke-test target and exec mechanism**: which endpoint(s) to probe, how to execute a command inside the running sandbox, and the fail/pass condition with a bounded timeout.
- **Round-trip method**: `claude -p "ping"` vs raw `curl` to `inference.local` for D-06.
- **`network_policies` exact syntax** and its delivery flag (D-01) — live CLI verification required.
- **Provider-existence check command** — exact `openshell inference get` vs `openshell provider get` invocation and registered-vs-missing exit signal (D-03).

### Deferred Ideas (OUT OF SCOPE)

- Multi-turn interactive session automation — remains an operator README step (D-07).
- Claude launch + MCP/plugin network audit (RUN-01, RUN-02) — Phase 4.
- `policy prove` formal verification (VER-01) and Makefile wrapper (ERG-01) — v2.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| NET-01 | Running sandbox has zero direct internet egress (deny-all egress policy) | Verified: absent/empty `network_policies` in policy.yaml = deny-all; live sandbox already blocks api.anthropic.com with curl exit 56. No code change needed — default behavior is deny-all. |
| NET-02 | Model inference brokered through the OpenShell gateway — `ANTHROPIC_BASE_URL` points at `inference.local`, not the public Anthropic API | Verified: Dockerfile already sets `ENV ANTHROPIC_BASE_URL=https://inference.local` (line 93). Phase 3 validates the round-trip path works. |
| NET-03 | Credentials injected at sandbox runtime via OpenShell provider mechanism, never baked into image. Primary path: Claude subscription login via `openshell provider create --from-existing` | Partially verified: provider create and inference set CLI flags confirmed live. Exact `--type` for subscription (OAuth) needs empirical confirmation during Phase 3 execution. |
| NET-04 | Rebuild script asserts egress policy contains no `api.anthropic.com` endpoint | Verified: `openshell policy get <sandbox> --full -o json` + jq provides parseable assertion. Pattern confirmed live. |
| NET-05 | Rebuild script runs egress smoke test confirming outbound request fails before handing control to operator | Verified: `openshell sandbox exec --name <sb> --no-tty -- curl --max-time N https://api.anthropic.com` exits 56 (CONNECT tunnel failed 403). Pattern confirmed live. |
</phase_requirements>

---

## Summary

Phase 3 adds three new gates to `rebuild.sh` and validates the inference path, on top of the Phase 2 sandbox lifecycle. The critical discovery from live testing is that **zero-egress enforcement is already active by default** in every OpenShell sandbox: all outbound connections are routed through a proxy at `http://10.200.0.1:3128`, and the proxy engine denies any connection not explicitly allowed in `network_policies`. Since the current `policy.yaml` has no `network_policies` section, deny-all is already enforced without any code change to the policy file. NET-01 is satisfied by the existing policy.yaml as-is; Phase 3 must only add the gates that *prove* this enforcement is working (NET-04, NET-05) and set up the inference path (NET-02, NET-03).

The inference path through `inference.local` is also already reachable from inside the sandbox (the proxy allows the `inference.local` tunnel), but returns a gateway error when no provider is configured. This means the Phase 3 round-trip test (D-06) requires the operator to first configure a provider and run `openshell inference set`, which are explicit pre-conditions documented in the README (D-04). The `rebuild.sh` preflight (D-03) detects the absence of this configuration and exits early rather than letting the sandbox create proceed to a 290-second hang.

**Primary recommendation:** Implement all gates as text-parsing or JSON-assertion checks against live `openshell` CLI output. No new files are needed beyond `rebuild.sh` edits and a README section. The existing `set -euo pipefail` + `log_step`/`log_error` discipline carries through.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Zero-egress enforcement | Sandbox runtime (OpenShell gateway proxy) | `rebuild.sh` preflight asserts it | The proxy at 10.200.0.1:3128 enforces policy; rebuild.sh only verifies post-create that no allowlist violations exist |
| Inference credential injection | OpenShell gateway (provider record) | — | The gateway strips sandbox placeholder credentials and injects the real OAuth token from the host-side provider record; no sandbox code involved |
| `inference.local` routing | OpenShell gateway | Dockerfile `ENV ANTHROPIC_BASE_URL` | Gateway exposes the `inference.local` HTTPS endpoint; Dockerfile tells Claude where to send requests |
| Provider existence preflight | `rebuild.sh` (host script) | — | Pre-create check runs entirely on the host against the gateway API |
| Egress policy assertion (NET-04) | `rebuild.sh` (host script, post-create) | — | Queries live sandbox policy via `openshell policy get`, not static file grep |
| Egress smoke test (NET-05) | `rebuild.sh` (host script, in-sandbox) | — | `openshell sandbox exec` drives curl inside the sandbox; blocks rebuild if egress unexpectedly succeeds |
| Round-trip inference test (D-06) | `rebuild.sh` (host script, in-sandbox) | — | Non-fatal curl POST to inference.local from inside sandbox; warns but does not block |

---

## Standard Stack

### Core (all already installed or CLI-level)

| Tool/Command | Version | Purpose | Provenance |
|--------|---------|---------|---------|
| `openshell` CLI | 0.0.62 | All sandbox, policy, inference, and provider management | [VERIFIED: live binary] |
| `openshell sandbox exec` | — | Run commands inside a running sandbox from the host | [VERIFIED: live `--help` output] |
| `openshell policy get` | — | Query live effective policy in JSON | [VERIFIED: live `--help` + live run] |
| `openshell inference get` | — | Check if gateway inference provider is configured | [VERIFIED: live run — outputs "Not configured" when unset] |
| `openshell provider create` | — | Register credential provider (operator step, not rebuild.sh) | [VERIFIED: live `--help`] |
| `openshell inference set` | — | Configure gateway-level model route (operator step) | [VERIFIED: live `--help`] |
| `jq` | already in preflight | Parse JSON from policy get assertion | [VERIFIED: already in rebuild.sh preflight loop] |
| `curl` | inside sandbox (8.18.0 on Fedora 44) | Smoke test egress + round-trip test | [VERIFIED: live sandbox exec] |

### No Additional Packages Needed

This phase adds zero external dependencies. All required capabilities are in the existing `openshell` CLI (v0.0.62), `jq`, and `curl` (already in the Fedora 44 image). No `npm install` or system package changes are required.

---

## Package Legitimacy Audit

> No new external packages are installed in this phase. Skip.

---

## Architecture Patterns

### System Architecture Diagram

```
rebuild.sh (host)
  |
  +-- [preflight] openshell inference get
  |     If "Not configured" → EXIT 1 (clear error + README link)
  |     If configured → continue
  |
  +-- [existing steps 1-4] build + teardown + sandbox create
  |     sandbox create uses policy.yaml (no network_policies section → deny-all)
  |
  +-- [Step 5] NET-04: openshell policy get <sandbox> --full -o json
  |     jq assertion: no anthropic endpoints in network_policies
  |     If violation found → EXIT 1 (hard error)
  |
  +-- [Step 6] NET-05: openshell sandbox exec → curl https://api.anthropic.com
  |     Expected: curl exits 56 (CONNECT tunnel 403 from proxy) = PASS
  |     If exits 0 (connection succeeded) → EXIT 1 (hard error)
  |     (also test https://example.com to prove deny-all, not just Anthropic-specific)
  |
  +-- [Step 7] D-06: openshell sandbox exec → curl POST https://inference.local/v1/messages
  |     If JSON response with content[] → log "Round-trip PASS"
  |     If error response → log "Round-trip WARN: provider not reachable" (non-fatal)
  |
  +-- "Ready — handing to operator" banner

OpenShell Proxy (10.200.0.1:3128 inside sandbox)
  |
  +-- api.anthropic.com:443 → 403 Forbidden (no network_policies entry)
  +-- example.com:443 → 403 Forbidden (no network_policies entry)
  +-- inference.local:443 → 200 Connection Established (special OpenShell route)
        |
        +-- No provider configured → {"error":"cluster inference is not configured"}
        +-- Provider configured → gateway strips x-api-key, injects OAuth token,
                                   rewrites model, forwards to api.anthropic.com

Host-side provider (operator one-time setup):
  openshell provider create --name claude-code --type claude-code --from-existing
  openshell inference set --provider claude-code --model <MODEL>
```

### Recommended Project Structure

No new directories needed. All changes go into existing files:

```
rebuild.sh               # Add: provider preflight (before Step 1), Steps 5-7 (post-create)
README.md (or new)       # Add: one-time provider setup + operator multi-turn validation
policy.yaml              # No changes (comment already says "deferred to Phase 3")
```

### Pattern 1: Provider Existence Preflight (D-03)

**What:** Before `openshell sandbox create`, check that the gateway inference provider is configured. Exit with a clear actionable error if not.

**When to use:** Every rebuild.sh run, before the slow `sandbox create` step.

**Implementation:**
```bash
# Source: live openshell inference get output (VERIFIED)
check_inference_provider() {
    local output
    output=$(openshell inference get 2>&1 | sed 's/\x1B\[[0-9;]*[mK]//g')
    if echo "${output}" | grep -q "Not configured"; then
        log_error "Inference provider is not configured — sandbox create would hang ~290s."
        log_error "One-time setup (operator action):"
        log_error "  openshell provider create --name claude-code --type claude-code --from-existing"
        log_error "  openshell inference set --provider claude-code --model <MODEL>"
        log_error "See README for full setup instructions."
        exit 1
    fi
    log_info "Inference provider configured — preflight passed"
}
```

**Detection confirmed:** `openshell inference get` exits 0 in both the configured and unconfigured states. Detection MUST use output grep, not exit code. Strip ANSI escape codes with `sed 's/\x1B\[[0-9;]*[mK]//g'` before grepping. The string "Not configured" appears in the output when neither gateway nor system inference route is set. [VERIFIED: live run]

### Pattern 2: Zero-Egress Policy Assertion (D-02 / NET-04)

**What:** After `sandbox create`, query the live effective policy and assert no direct Anthropic endpoint exists.

**When to use:** Post-create, before smoke test.

**Implementation:**
```bash
# Source: live openshell policy get --full -o json output (VERIFIED)
assert_no_anthropic_egress() {
    local sandbox_name="${1}"
    local policy_json
    policy_json=$(openshell policy get "${sandbox_name}" --full -o json 2>&1)
    
    # jq exits 0 if a matching endpoint is found (violation), non-zero if no match (pass)
    if echo "${policy_json}" | jq -e \
        '.policy.network_policies // {} | to_entries[] | .value.endpoints[]? | select(.host | test("anthropic"; "i"))' \
        >/dev/null 2>&1; then
        log_error "NET-04 VIOLATION: Direct Anthropic endpoint found in effective policy!"
        log_error "Policy output: ${policy_json}"
        exit 1
    fi
    log_info "NET-04 PASS: No direct Anthropic endpoints in effective policy"
}
```

**JSON structure confirmed:** `openshell policy get --full -o json` returns:
```json
{
  "policy": {
    "filesystem_policy": { ... },
    "network_policies": { ... },   // absent when empty — use // {} guard
    "version": 1
  }
}
```
When `network_policies` is absent (deny-all state), jq `// {}` returns an empty object, `to_entries[]` produces no output, and jq exits non-zero — PASS. [VERIFIED: live run + jq test cases]

### Pattern 3: Egress Smoke Test (D-05 / NET-05)

**What:** Run `curl` inside the sandbox against `api.anthropic.com` (and a generic target). If the connection succeeds, block the rebuild.

**When to use:** After sandbox is in Ready state, after NET-04 assertion passes.

**Implementation:**
```bash
# Source: live openshell sandbox exec (VERIFIED - exits 56 on blocked, 0 on success)
run_egress_smoke_test() {
    local sandbox_name="${1}"
    local -a targets=("https://api.anthropic.com" "https://example.com")
    
    for target in "${targets[@]}"; do
        local curl_output curl_rc
        # Redirect stderr to /dev/null: suppresses non-fatal /home/sandbox/.bash_profile error
        curl_output=$(openshell sandbox exec --name "${sandbox_name}" --no-tty \
            -- curl --max-time 8 --silent --show-error "${target}" 2>/dev/null) || true
        curl_rc=$?
        
        if [[ ${curl_rc} -eq 0 ]]; then
            log_error "NET-05 VIOLATION: Egress to ${target} SUCCEEDED (expected: blocked)"
            log_error "Zero-egress guarantee is broken. Aborting."
            exit 1
        elif [[ ${curl_rc} -eq 56 ]]; then
            log_info "NET-05 PASS: ${target} blocked by proxy (curl exit 56 — CONNECT tunnel 403)"
        else
            log_info "NET-05 PASS: ${target} blocked (curl exit ${curl_rc})"
        fi
    done
}
```

**Exit code behavior confirmed (live):**
- Exit 56 = `CONNECT tunnel failed, response 403` — proxy blocked the connection. PASS.
- Exit 0 = connection succeeded and got a response. VIOLATION → block.
- Other non-zero = timeout, DNS error, etc. — also counts as blocked. PASS.

**Stderr note:** `openshell sandbox exec` always emits `/bin/bash: /home/sandbox/.bash_profile: Permission denied` to stderr. This is non-fatal and should be suppressed via `2>/dev/null` on the exec call. [VERIFIED: live run]

**Recommended targets:** Test both `https://api.anthropic.com` (criterion #1) and `https://example.com` (prove deny-all, not just Anthropic-specific block).

### Pattern 4: Inference Round-Trip Test (D-06, non-fatal)

**What:** POST to `inference.local/v1/messages` from inside the sandbox. Report success or warning, never block.

**When to use:** After smoke test passes.

**Implementation:**
```bash
# Source: live openshell sandbox exec + inference-routing.mdx (VERIFIED)
run_inference_round_trip() {
    local sandbox_name="${1}"
    local response rc
    
    response=$(openshell sandbox exec --name "${sandbox_name}" --no-tty \
        -- curl --max-time 30 --silent --show-error \
        -X POST https://inference.local/v1/messages \
        -H "Content-Type: application/json" \
        -H "x-api-key: placeholder" \
        -d '{"model":"any","max_tokens":10,"messages":[{"role":"user","content":"ping"}]}' \
        2>/dev/null) || true
    rc=$?
    
    if [[ ${rc} -ne 0 ]]; then
        log_info "Round-trip WARN: curl failed (rc=${rc}) — inference path not verified (non-fatal)"
        return 0
    fi
    
    # Check if response has content (success) vs error message (provider not configured)
    if echo "${response}" | jq -e '.content | length > 0' >/dev/null 2>&1; then
        log_info "Round-trip PASS: inference.local returned a model response"
    else
        local err
        err=$(echo "${response}" | jq -r '.error // "unknown error"' 2>/dev/null || echo "${response}")
        log_info "Round-trip WARN: inference.local returned error: ${err} (non-fatal)"
        log_info "  If provider is not configured, run the one-time setup in README."
    fi
}
```

**Confirmed behavior without provider:** inference.local returns `{"error":"cluster inference is not configured","hint":"run: openshell cluster inference set --help"}` with curl exit 0. The jq `.content | length > 0` check correctly identifies this as a non-successful response. [VERIFIED: live run]

**Why curl, not `claude -p`:** The curl approach tests the raw inference gateway path directly, without requiring Claude binary flags or ANTHROPIC_BASE_URL to be set for `exec`. `claude -p` would require Phase 4's `--dangerously-skip-permissions` setup and ANTHROPIC_BASE_URL/ANTHROPIC_API_KEY in the exec environment. The curl approach is simpler and tests the exact path Claude Code would use. [ASSUMED: Phase 4 concern, but curl is clearly more appropriate here]

### Pattern 5: integration into rebuild.sh step numbering

**What:** Phase 3 adds a provider preflight gate and three new Steps (Steps 5, 6, 7) after the existing Step 4 (sandbox create). The existing Steps 1-4 are unchanged.

**Step layout:**
```
Step 0 (new, before Step 1): Provider preflight — openshell inference get check
Step 1: Resolve cooldown versions and build container image  [existing]
Step 2: Tag :latest alias                                    [existing]  
Step 3: Teardown existing sandbox and images                 [existing]
Step 4: Create sandbox with bind mount and policy            [existing]
Step 5 (new): NET-04 — policy assertion (openshell policy get + jq)
Step 6 (new): NET-05 — egress smoke test (sandbox exec curl)
Step 7 (new): D-06  — round-trip inference test (sandbox exec curl, non-fatal)
```

The existing "Ready" banner moves after Step 7.

### Anti-Patterns to Avoid

- **`openshell policy update --add-endpoint api.anthropic.com`**: Defeats the zero-egress guarantee. Explicitly forbidden in CLAUDE.md. Never use this, even temporarily for debugging.
- **Grepping `policy.yaml` source file for NET-04**: The file is the *input*, not the *enforced* policy. A built-in OpenShell default or a provider attachment could add endpoints not in the file. Query the *live* sandbox with `openshell policy get`.
- **Relying on `openshell inference get` exit code for provider detection**: The command exits 0 regardless of whether a provider is configured or not. Must grep output text after stripping ANSI codes.
- **Using `ANTHROPIC_BASE_URL=https://inference.local/v1`**: Claude Code appends `/v1/messages`, creating `/v1/v1/messages` double path. Must be `https://inference.local` (no trailing `/v1`). [VERIFIED: CLAUDE.md + Dockerfile line 93]
- **Provider create in Dockerfile or rebuild.sh**: `--from-existing` reads host keychain/OAuth token — not available inside the container build. This is an operator step. [VERIFIED: CLAUDE.md "What NOT to Use"]
- **`--allow-dangerously-skip-permissions`**: Not the correct flag. Use `--dangerously-skip-permissions`. [VERIFIED: CLAUDE.md "What NOT to Use"]

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Egress enforcement | iptables rules, custom proxy | OpenShell network policy (empty `network_policies`) | Already enforced by the OpenShell proxy at 10.200.0.1:3128; adding iptables creates a second enforcement layer that isn't needed and complicates auditing |
| Policy inspection | Parse policy.yaml source file | `openshell policy get --full -o json` | The source file is the input, not the enforcement state; built-in defaults and provider attachments can add endpoints not in the file |
| Credential injection | Bake credentials in Dockerfile | `openshell provider create --from-existing` + `openshell inference set` | NET-03 requirement: credentials never in image; gateway handles OAuth refresh host-side |
| Provider detection | Parse gateway.toml | `openshell inference get` output | The TOML shows driver config; inference configuration is a gateway-level state only queryable via the CLI |

---

## Runtime State Inventory

> Not applicable — this phase does not involve rename, rebrand, or migration.

---

## Common Pitfalls

### Pitfall 1: openshell inference get exits 0 even when provider is absent

**What goes wrong:** A script checks `if openshell inference get; then ...` and always proceeds, even when inference is unconfigured.

**Why it happens:** The CLI returns exit 0 for both "configured" and "not configured" states. The distinction is in the human-readable text output, not the exit code.

**How to avoid:** After stripping ANSI escape codes, grep for the string "Not configured". Fail-closed if found.
```bash
output=$(openshell inference get 2>&1 | sed 's/\x1B\[[0-9;]*[mK]//g')
if echo "${output}" | grep -q "Not configured"; then
    log_error "Inference provider not configured"; exit 1
fi
```

**Warning signs:** The rebuild ever completes despite `openshell inference get` showing "Not configured".

### Pitfall 2: The round-trip curl exit code is 0 even on gateway error responses

**What goes wrong:** `curl --fail` is used to detect round-trip failure. The inference.local gateway returns HTTP 403 or a JSON error body with HTTP 200, so curl exits 0 regardless.

**Why it happens:** `curl --fail` only fails on HTTP 4xx/5xx server errors when the server itself reports failure. The OpenShell gateway returns HTTP 200 with a JSON error body in some cases (e.g., the "connection not allowed by policy" body from earlier tests was preceded by HTTP 403, but future gateway versions may differ).

**How to avoid:** Parse the JSON response body with `jq`. Check `.content | length > 0` for a successful Anthropic response, rather than relying on curl's exit code.

### Pitfall 3: network_policies absent ≠ needs to be added

**What goes wrong:** A developer sees `network_policies` is missing from the policy JSON and adds an empty `network_policies: {}` section to policy.yaml, expecting that to enforce zero-egress.

**Why it happens:** Intuition says "missing field needs to be set".

**How to avoid:** Understand that the OpenShell proxy default-denies everything not explicitly listed. An absent or empty `network_policies` is the *correct* zero-egress state. Do not add a `network_policies` section to policy.yaml unless you intend to *allow* a specific endpoint.

**Warning signs:** After adding `network_policies: {}` to policy.yaml, the behavior is identical — no change needed.

### Pitfall 4: sandbox exec stderr noise breaks output capture

**What goes wrong:** Policy JSON or curl output is captured with `$(openshell sandbox exec ...)`, but the `.bash_profile: Permission denied` line from stderr contaminates the captured output if stderr is merged with stdout.

**Why it happens:** `openshell sandbox exec` spawns a bash shell that tries to source `/home/sandbox/.bash_profile`, which has a permissions issue. This is a non-fatal sandbox configuration issue.

**How to avoid:** Always redirect stderr to `/dev/null` when capturing output from `openshell sandbox exec`:
```bash
output=$(openshell sandbox exec --name "${SANDBOX_NAME}" --no-tty -- <cmd> 2>/dev/null)
```

**Warning signs:** JSON parsing fails with "unexpected token" due to the bash error line appearing in the output.

### Pitfall 5: Provider type for subscription (OAuth) vs API key

**What goes wrong:** `openshell provider create --type anthropic --from-existing` is used, which reads `ANTHROPIC_API_KEY` env var (API key auth). The operator has a Claude subscription (OAuth), not an API key.

**Why it happens:** The `anthropic` type is documented for API key auth. The `claude-code` profile is designed for subscription/OAuth authentication using `~/.claude/.credentials.json`.

**How to avoid:** Use `--type claude-code` (matching the profile ID from `openshell provider list-profiles`). The `claude-code` profile's `--from-existing` reads from `~/.claude/.credentials.json` (which contains `claudeAiOauth` with `accessToken`/`refreshToken`), not from env vars.

**Warning signs:** Provider creation succeeds but the round-trip fails with "Unauthorized" or "Invalid API key".

**Note:** The exact `--type` flag for subscription auth is `[ASSUMED]` based on profile structure. The CLAUDE.md explicitly states "Exact --type/profile flag confirmed empirically in the inference phase." The operator must test this during Phase 3 execution.

### Pitfall 6: Provider is gateway-scoped, not sandbox-scoped

**What goes wrong:** After creating a provider and running `openshell inference set`, the developer expects only the newly created sandbox to use it and is surprised when existing sandboxes also get inference routing.

**Why it happens:** `openshell inference set` configures the gateway-level route — all sandboxes on that gateway see the same `inference.local` backend.

**How to avoid:** This is the desired behavior for this project (one gateway, one inference backend). Document in README that `openshell inference set` is a one-time gateway setup, not per-sandbox.

---

## Code Examples

### Detecting "Not configured" from inference get output

```bash
# Source: live openshell v0.0.62 (VERIFIED)
check_inference_provider() {
    local output
    output=$(openshell inference get 2>&1 | sed 's/\x1B\[[0-9;]*[mK]//g')
    if echo "${output}" | grep -q "Not configured"; then
        log_error "Inference provider is not configured."
        log_error "Run the one-time setup documented in README:"
        log_error "  openshell provider create --name claude-code --type claude-code --from-existing"
        log_error "  openshell inference set --provider claude-code --model <MODEL>"
        exit 1
    fi
    log_info "Inference provider configured — preflight passed"
}
```

### NET-04 Policy Assertion (jq)

```bash
# Source: live openshell policy get output + jq test (VERIFIED)
assert_no_anthropic_egress() {
    local sandbox_name="${1}"
    local policy_json
    policy_json=$(openshell policy get "${sandbox_name}" --full -o json 2>&1)
    if echo "${policy_json}" | jq -e \
        '.policy.network_policies // {} | to_entries[] | .value.endpoints[]? | select(.host | test("anthropic"; "i"))' \
        >/dev/null 2>&1; then
        log_error "NET-04 VIOLATION: Direct Anthropic endpoint found in effective policy!"
        exit 1
    fi
    log_info "NET-04 PASS: No direct Anthropic endpoints in effective policy"
}
```

### NET-05 Egress Smoke Test

```bash
# Source: live openshell sandbox exec (VERIFIED - exits 56 on blocked)
run_egress_smoke_test() {
    local sandbox_name="${1}"
    for target in "https://api.anthropic.com" "https://example.com"; do
        local rc=0
        openshell sandbox exec --name "${sandbox_name}" --no-tty \
            -- curl --max-time 8 --silent "${target}" 2>/dev/null || rc=$?
        if [[ ${rc} -eq 0 ]]; then
            log_error "NET-05 VIOLATION: Egress to ${target} SUCCEEDED — zero-egress broken!"
            exit 1
        fi
        log_info "NET-05 PASS: ${target} blocked (curl exit ${rc})"
    done
}
```

### D-06 Non-Fatal Round-Trip Test

```bash
# Source: live inference.local behavior (VERIFIED) + inference-routing.mdx (CITED)
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
        return 0
    fi
    if echo "${response}" | jq -e '.content | length > 0' >/dev/null 2>&1; then
        log_info "D-06 PASS: inference.local returned a model response"
    else
        local err
        err=$(echo "${response}" | jq -r '.error // "unknown"' 2>/dev/null || echo "${response}")
        log_info "D-06 WARN: inference.local error: ${err} (non-fatal — check README setup)"
    fi
}
```

### Operator One-Time Setup (README content)

```bash
# Source: inference-routing.mdx (CITED) + CLAUDE.md (VERIFIED)

# Step 1: Create the inference provider from existing Claude subscription credentials
# (~/.claude/.credentials.json — loaded automatically by --from-existing)
openshell provider create --name claude-code --type claude-code --from-existing
# NOTE: --type is assumed to be "claude-code" (matching the profile ID from
# `openshell provider list-profiles`). Confirm this empirically on first execution.

# Step 2: Set the gateway-level inference route
# This configures inference.local for all sandboxes on this gateway
openshell inference set --provider claude-code --model <MODEL>
# <MODEL> is the model identifier your Claude subscription supports
# Example: claude-3-5-sonnet-20241022, claude-3-5-haiku-20241022

# Step 3: Verify configuration
openshell inference get

# Step 4 (if token expires): Refresh credentials
openshell provider refresh status claude-code
# Token refresh is handled automatically; this is only for manual inspection

# Step 5 (operator validation of criterion #2): Live multi-turn session
# From inside the sandbox (openshell sandbox connect claude-sandbox):
#   claude --dangerously-skip-permissions
# Verify at least two round-trips succeed interactively.
```

---

## State of the Art

| Old Approach | Current Approach | Impact |
|--------------|------------------|--------|
| Manual iptables rules for zero-egress | OpenShell proxy + empty `network_policies` | Automatic, auditable, and live-queryable via `openshell policy get` |
| Per-sandbox credential injection via env vars | Gateway-level provider + `inference.local` routing | Credentials never reach the sandbox; gateway handles OAuth refresh |
| Direct `api.anthropic.com` calls from Claude | `ANTHROPIC_BASE_URL=https://inference.local` | All traffic routed through the gateway privacy proxy |

**Deprecated/outdated:**
- `openshell policy update --add-endpoint api.anthropic.com`: This is the anti-pattern — explicitly forbidden. Creates direct egress, defeating the zero-egress guarantee.
- `ANTHROPIC_BASE_URL=https://inference.local/v1`: Double `/v1` path bug. The correct URL has no trailing `/v1`.

---

## Key Verified Behaviors (Live CLI Observations)

These are the ground-truth facts from running live commands against the installed `openshell` v0.0.62 binary and the existing `claude-sandbox`.

| Behavior | Observation | Impact on Plan |
|----------|-------------|----------------|
| `openshell inference get` exit code when unconfigured | **0** (not an error exit) | Must grep output text, not check exit code |
| `openshell inference get` output when unconfigured | `Gateway inference:\n  Not configured\nSystem inference:\n  Not configured` | Use `grep -q "Not configured"` after stripping ANSI |
| `curl https://api.anthropic.com` from inside sandbox | Exit 56; `CONNECT tunnel failed, response 403` | Smoke test PASS condition is any exit code ≠ 0 |
| `curl https://example.com` from inside sandbox | Exit 56; same proxy 403 | Proves deny-all, not Anthropic-specific block |
| `curl POST https://inference.local/v1/messages` (no provider) | Exit 0; `{"error":"cluster inference is not configured"}` | Must parse JSON body, not curl exit code for round-trip test |
| `openshell policy get claude-sandbox --full -o json` | JSON with `network_policies` **absent** (not empty) | Use `// {}` guard in jq to handle absent field |
| jq with no match (correct deny-all state) | Exit **non-zero** (no entries found) | Assertion logic: non-zero = PASS, 0 = VIOLATION |
| `openshell sandbox exec` stderr | `Permission denied /home/sandbox/.bash_profile` (non-fatal) | Always add `2>/dev/null` when capturing sandbox exec output |
| `inference.local` proxy tunnel | Returns HTTP 200 Connection Established | `inference.local` is always reachable; errors come from the gateway layer, not the proxy |
| Proxy address inside sandbox | `http://10.200.0.1:3128` (via `https_proxy` env var) | All traffic (except `localhost`) routes through this proxy |
| Claude binary path in sandbox | `/usr/local/bin/claude` (symlink) | Phase 4 can invoke Claude at this path |
| `ANTHROPIC_BASE_URL` in sandbox exec env | **Not available** via `openshell sandbox exec` environment | The Dockerfile ENV is in OCI config; exec spawns a fresh shell without container defaults. Phase 4 concern. |

---

## Open Questions

1. **Exact `--type` for OAuth/subscription provider create**
   - What we know: `openshell provider list-profiles` shows `claude-code` as a profile under the AGENT category. The profile reads `ANTHROPIC_API_KEY` for API key auth but also has OAuth discovery via `~/.claude/.credentials.json`. CLAUDE.md says "Exact --type/profile flag confirmed empirically in the inference phase."
   - What's unclear: Whether `--type claude-code` works with `--from-existing` to load the OAuth token, or whether there is a different `--type` for subscription auth.
   - Recommendation: The first execution task in Phase 3 should be `openshell provider create --name claude-code --type claude-code --from-existing` and verify whether `openshell inference get` shows the provider configured. If it fails, try `--type anthropic`. Document the confirmed flag in CLAUDE.md.

2. **What model identifier to use with `openshell inference set`**
   - What we know: `openshell inference set --provider <name> --model <MODEL>` requires a model string. Anthropic models are: `claude-3-5-sonnet-20241022`, `claude-3-5-haiku-20241022`, `claude-3-opus-20240229`, etc.
   - What's unclear: Whether the operator's subscription supports all models, or whether a specific model must be used.
   - Recommendation: Document this as a manual operator choice in the README. The round-trip test uses `"model":"any"` (which the gateway rewrites anyway), so the automated test is model-agnostic.

3. **`openshell provider refresh` subcommands for OAuth auto-refresh**
   - What we know: `openshell provider refresh` has subcommands: `status`, `configure`, `rotate`, `delete`. The CLAUDE.md says `openshell provider refresh` handles OAuth token refresh.
   - What's unclear: Whether `--from-existing` for the claude-code provider automatically sets up OAuth refresh, or whether `openshell provider refresh configure` needs additional arguments.
   - Recommendation: After the operator runs `provider create --from-existing`, run `openshell provider refresh status claude-code` to verify refresh is configured. Document the check in README.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `openshell` CLI | All NET-0x gates | Yes | 0.0.62 | — |
| `jq` | NET-04 policy assertion | Yes | in rebuild.sh preflight | — |
| `curl` | NET-05, D-06 (inside sandbox) | Yes | 8.18.0 (Fedora 44 image) | — |
| `sed` | ANSI stripping for inference get | Yes | GNU sed (macOS has it) | `tr -d` alternative |
| Claude subscription (OAuth) | NET-03, D-06 | Exists | ~/.claude/.credentials.json confirmed | — |
| `openshell inference set` (configured) | D-06 round-trip | Not yet configured | — | D-06 is non-fatal; warns and continues |

**Missing dependencies with no fallback:** None — all required tools are present.

**Pre-conditions required before `rebuild.sh` will fully pass:**
- Operator must run the one-time `openshell provider create` + `openshell inference set` setup.
- Until then, D-03 preflight will block and D-06 round-trip will WARN (non-fatal).

---

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | Yes | Credentials injected by gateway via `openshell provider create --from-existing`; never in image or script |
| V3 Session Management | No | No session state in rebuild.sh |
| V4 Access Control | Yes | Empty `network_policies` = deny-all; no allowlist entries added |
| V5 Input Validation | Yes | No user-controlled input in shell commands; all URLs are hardcoded |
| V6 Cryptography | No | TLS is handled by OpenShell proxy (`/etc/openshell-tls/ca-bundle.pem`); no custom crypto |

### Known Threat Patterns for Shell Scripting / OpenShell

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Credential leakage in rebuild.sh logs | Information Disclosure | Provider credentials never passed to rebuild.sh; only `openshell inference get` output (which shows no credential values) is logged |
| ANSI injection via openshell output | Tampering | Strip ANSI with `sed 's/\x1B\[[0-9;]*[mK]//g'` before grepping; don't `eval` CLI output |
| Smoke test false negative (policy bypassed) | Elevation of Privilege | Test two independent targets (api.anthropic.com + example.com); deny-all means both must fail |
| `network_policies` added post-create | Tampering | The policy assertion runs after create and before handing to operator; hot-reload could theoretically add endpoints later, but this is outside rebuild.sh scope |
| Provider credentials in image | Information Disclosure | NET-03 requirement explicitly forbids it; `--from-existing` is a host-only operator action |

---

## Project Constraints (from CLAUDE.md)

| Directive | Applies to Phase 3 |
|-----------|-------------------|
| Zero direct internet egress from running sandbox | Core requirement; validated by NET-04 + NET-05 |
| `openshell sandbox create` with podman-built image ref | Unchanged from Phase 2; no Dockerfile changes needed |
| `ANTHROPIC_BASE_URL=https://inference.local` (no trailing `/v1`) | Already set in Dockerfile line 93; validated by D-06 round-trip |
| Credentials NEVER baked into image | D-04 decision; operator-only provider create |
| Never use `openshell policy update --add-endpoint api.anthropic.com` | Anti-pattern; explicitly listed in "What NOT to Use" |
| `enable_bind_mounts = true` already set in gateway.toml | No change needed |
| `set -euo pipefail` in shell scripts | All new rebuild.sh functions must respect this (no unguarded rc=$? without `|| true`) |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `--type claude-code` is the correct `--type` for OAuth subscription auth with `--from-existing` | Open Questions #1, Code Examples | Provider create fails; operator must try `--type anthropic` or inspect `openshell provider list-profiles` more carefully. Low operational risk since it's an operator step, not baked into rebuild.sh. |
| A2 | The gateway rewrites any model name to the configured model, so `"model":"any"` works for the D-06 round-trip test | Code Examples (D-06 curl body) | If the gateway validates model names before rewriting, the curl call may return a 400. Low risk — the round-trip is non-fatal. |
| A3 | `openshell provider refresh` for a `--from-existing` claude-code provider auto-configures OAuth refresh without additional `refresh configure` subcommand | Open Questions #3 | Token expires and inference fails silently until operator manually refreshes. Mitigated by README documenting `openshell provider refresh status` as a check. |

---

## Sources

### Primary (HIGH confidence)

- Live `openshell` v0.0.62 binary help output — `sandbox create`, `inference get`, `inference set`, `policy get`, `sandbox exec`, `provider create`, `provider list-profiles`, `provider refresh` — all flags and output formats verified by direct execution in this research session
- Live `openshell sandbox exec` runs against `claude-sandbox` — exit codes 56 (blocked), 0 (success), curl behavior, proxy env vars, ANSI output format — all observed directly
- Live `openshell policy get claude-sandbox --full -o json` — JSON structure confirmed, `network_policies` absent in deny-all state
- Live `openshell inference get` — "Not configured" text and exit code 0 confirmed
- `~/.claude/.credentials.json` — `claudeAiOauth` key structure confirmed (OAuth, not API key)
- `~/.config/openshell/gateway.toml` — `compute_drivers = ["podman"]`, `enable_bind_mounts = true`
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/sandboxes/policies.mdx` — `network_policies` structure, zero-egress enforcement mechanism, `openshell policy get` command
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/sandboxes/inference-routing.mdx` — `inference.local` architecture, `openshell inference set`, provider types, Claude Code `ANTHROPIC_BASE_URL` example

### Secondary (MEDIUM confidence)

- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/sandboxes/manage-sandboxes.mdx` — sandbox create flags, general sandbox lifecycle
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/sandboxes/manage-providers.mdx` — provider credential injection mechanism, `--from-existing` flag behavior
- `openshell provider profile export claude-code` — claude-code profile YAML showing credential type and endpoint list

### Tertiary (LOW confidence / ASSUMED)

- Provider `--type claude-code` for subscription OAuth auth — inferred from profile ID but not empirically tested
- `openshell provider refresh` behavior for OAuth auto-refresh — based on CLAUDE.md reference and CLI help, not tested

---

## Metadata

**Confidence breakdown:**
- Egress enforcement mechanism: HIGH — live sandbox tests confirmed proxy blocks with exit 56
- Inference.local routing: HIGH — live sandbox tests confirmed 200 Connect + gateway error response
- Policy assertion pattern: HIGH — jq logic tested against live JSON output and synthetic test cases
- NET-04/NET-05 shell patterns: HIGH — exit codes and output formats verified live
- Provider create `--type` for OAuth: LOW — profile structure consistent but not empirically tested

**Research date:** 2026-06-16
**Valid until:** Stable (OpenShell CLI v0.0.62 is pinned; changes only on CLI upgrade)
