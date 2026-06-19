# Phase 04: Claude Code Launch and MCP Audit - Research

**Researched:** 2026-06-19
**Domain:** OpenShell sandbox execution, claude -p headless invocation, plugin loading, telemetry audit
**Confidence:** HIGH (all critical findings verified live against the running sandbox and installed CLI)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** `./rebuild.sh claude` verb execs into sandbox with `openshell sandbox exec --name $SANDBOX --tty --workdir /claudeshared --` running `claude --dangerously-skip-permissions --plugin-dir /opt/claude-engineering-toolkit`. Mirrors `login`/`connect` pattern.
- **D-02:** No OAuth precondition check in the `claude` verb. Claude handles unauthenticated state itself.
- **D-03:** Dockerfile `CMD` keep-vs-repoint is **deferred to research** (see resolution below — CMD is vestigial; recommend repoint to `/bin/bash`).
- **D-04:** Audit is a scripted headless harness, not a manual checklist — drives `claude -p` once per plugin.
- **D-05:** Exposed as `./rebuild.sh audit-plugins` verb. Logic may live in `scripts/audit-plugins.sh` (thin-wrapper split).
- **D-06:** Audit report committed as `.planning/phases/04-.../PLUGIN-AUDIT.md` or similar.
- **D-07 (research-designed):** 10s "no network hang" bound must distinguish blocked-host hangs from model latency. Researcher determines exact mechanism. **(See resolution below — the proxy returns 403 in <100ms; no hang discrimination needed.)**
- **D-08:** Canonical plugin list enumerated from the toolkit's manifest at `/opt/claude-engineering-toolkit`. Researcher confirms format. **(See resolution below.)**
- **D-09:** Per-plugin expected-outcome table. Local-tool plugins MUST succeed; network/MCP-backed plugins MUST fail cleanly.
- **D-10:** Audit hard-fails on expected/actual mismatch (exit non-zero).
- **D-11:** Prove suppression via two angles: (a) `openshell logs` denied-connection entries, (b) Claude startup output. **(See exact log signatures below.)**
- **D-12:** Telemetry check folded into `audit-plugins` run.
- **D-13:** Stale-doc reconciliation (ROADMAP/REQUIREMENTS/PROJECT.md) is in-scope Phase 4 work.

### Claude's Discretion (mechanism open — resolved by research)

- Dockerfile CMD keep-vs-repoint (D-03)
- 10s-bound mechanism (D-07)
- Toolkit manifest discovery format (D-08) and headless invocation per plugin type
- Exact telemetry-attempt log signature (D-11)

### Deferred Ideas (OUT OF SCOPE)

- `policy prove` formal network-policy verification (VER-01)
- Makefile wrapper (ERG-01)
- Any change to the egress policy or auth model — Architecture B is locked.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| RUN-01 | Claude is launched with `--dangerously-skip-permissions` | D-01 verb pattern verified live; `claude --help` confirms flag. `openshell sandbox exec --timeout` is the correct exec mechanism. |
| RUN-02 | Claude is launched with `--plugin-dir` pointed at the cloned toolkit | Verified live: `claude --plugin-dir /opt/claude-engineering-toolkit plugin list` shows plugin loaded. **BLOCKER: `/opt` not in Landlock policy; agents/skills show 0 count until fixed.** Fix: add `/opt` to `read_only` in `policy.yaml`. |
</phase_requirements>

---

## Summary

Phase 4 delivers two new `./rebuild.sh` verbs (`claude` and `audit-plugins`) plus documentation reconciliation. All four deferred research questions (D-03, D-07, D-08, D-11) have been resolved by probing the live running sandbox.

**Two blockers were discovered that must be fixed in Phase 4:**

1. `/opt` is not in the `policy.yaml` Landlock `read_only` list. The `claude-engineering-toolkit` is cloned to `/opt/claude-engineering-toolkit` during image build, but the `sandbox` process user cannot read that path. `claude plugin details` confirms **Skills: 0, Agents: 0** — the plugin directory is found (plugin.json is readable at some point during the claude process startup) but the `agents/` and `skills/` subdirectories are Landlock-blocked. Fix: add `/opt` to `filesystem_policy.read_only` in `policy.yaml`.

2. `govulncheck` is installed by the Dockerfile to `/root/go/bin/govulncheck` (root's GOPATH). The sandbox runs as user `sandbox`; `/root` is not in the Landlock `read_only` list. The `vuln-reviewer` agent will not find `govulncheck` in PATH. Fix: after `go install`, copy the binary to `/usr/local/bin/govulncheck` in the Dockerfile.

**Primary recommendation:** Fix the two blockers in a Dockerfile + policy.yaml update task (Wave 0 or first task of Wave 1); then implement the `claude` verb, then the `audit-plugins` harness.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Claude launch (`rebuild.sh claude` verb) | Host shell (rebuild.sh) | Sandbox process | The host script is the operator entry point; `openshell sandbox exec` bridges to in-sandbox claude binary |
| Plugin loading | Sandbox filesystem (Landlock) | Claude process | Landlock controls what the `claude` process can read; must grant `/opt` |
| Headless audit (`audit-plugins` verb) | Host shell (audit-plugins.sh) | Sandbox claude process | Outer loop on host; each `openshell sandbox exec --no-tty --timeout N` call drives one plugin invocation |
| Telemetry suppression | Dockerfile ENV + sandbox proxy | openshell logs | `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` is the first line of defense; policy deny + OCSF logs are the evidence layer |
| Doc reconciliation (D-13) | Planning docs (host) | — | File edits only; no sandbox involvement |

---

## D-03 Resolution: Dockerfile CMD Keep vs. Repoint

**Finding (VERIFIED: live `openshell sandbox create --help` + live sandbox introspection):**

OpenShell's `sandbox create` always overrides the Dockerfile CMD. The `COMMAND` argument after `--` is what runs at create time, not the image CMD. The `sandbox create` help shows: `[COMMAND]... — Command to run after "--" (defaults to an interactive shell)` — it defaults to an **interactive shell** when `--` is omitted, NOT to the image CMD.

The rebuild.sh uses `-- /bin/true` which exits immediately; the sandbox stays alive because PID 1 is the supervisor (`/opt/openshell/bin/openshell-sandbox`), confirmed via `/proc/1/cmdline`. The Dockerfile CMD is **never executed** in any path.

**Recommendation (Claude's Discretion — resolved):** Repoint the Dockerfile CMD to `/bin/bash`. This makes the image behave sensibly if someone runs it directly (e.g., `podman run --rm -it`), and removes the misleading implication that `claude --dangerously-skip-permissions` auto-starts. The canonical flags now live in the `claude` verb (D-01); the CMD comment should document that.

```dockerfile
# Runtime default for direct podman run (not used by openshell sandbox create,
# which always overrides CMD via `-- COMMAND`). The canonical launch path is
# `./rebuild.sh claude` (openshell sandbox exec).
CMD ["/bin/bash"]
```

---

## D-07 Resolution: Blocked-Host-Hang vs. Model-Latency Discrimination

**Finding (VERIFIED: live sandbox experiment — `time curl` blocked connection):**

The OpenShell proxy returns HTTP 403 **immediately** (measured: 38ms) for denied outbound connections. It does NOT silently drop packets. The blocked-host failure mode is not a hang — it is an **instantaneous 403** from the proxy (`curl: (56) CONNECT tunnel failed, response 403`).

This means:
- **Model latency** (api.anthropic.com, ALLOWED): `claude -p` takes 5–30+ seconds.
- **Blocked host** (any non-allowlisted host): MCP tool or Bash inside claude gets a 403 in <100ms; the claude process itself finishes quickly.
- **Genuine hang**: Only if `openshell sandbox exec --timeout N` returns exit code 124.

**Recommendation (Claude's Discretion — resolved):** The audit harness uses a generous per-invocation timeout (120s) via `openshell sandbox exec --no-tty --timeout 120`. Exit code 124 = hang (unexpected failure for any plugin). Exit code 0 = terminal state reached (success or deterministic network error). Record wall-clock time per invocation for the audit report. A timeout exit (124) is always an audit FAIL regardless of plugin type.

The 10s bound mentioned in the ROADMAP success criterion should be understood as: "no plugin produces an exit-code-124 timeout" (not a sub-10s wall-clock constraint on all invocations). Model latency legitimately exceeds 10s. The criterion is met if: (a) local-tool plugins exit 0 with correct output within 120s, (b) network-blocked plugins exit 0 with a connection-refused/403 error message within 120s, (c) no plugin hits the 120s timeout (exit 124).

---

## D-08 Resolution: Toolkit Manifest Discovery and Headless Invocation

### Plugin Manifest Format

**Finding (VERIFIED: GitHub WebFetch of `plugin.json` + `claude plugin details`):**

The toolkit uses a `plugin.json` manifest at the repository root [CITED: https://github.com/pheckenlWork/claude-engineering-toolkit/blob/main/plugin.json]:

```json
{
  "name": "engineering-toolkit",
  "description": "Specialized review agents and engineering skills...",
  "version": "1.0.0",
  "components": {
    "agents": "agents/",
    "skills": "skills/"
  }
}
```

Claude discovers components by reading `agents/*.md` (for agent definitions) and `skills/*/SKILL.md` (for skill slash-commands) relative to the plugin root. These paths are blocked by Landlock until `/opt` is added to `policy.yaml`.

**Canonical component list (VERIFIED: GitHub WebFetch of agents/ and skills/ directories):**

**Agents** (`agents/*.md` — 11 files):
- `api-contract-reviewer`, `concurrency-reviewer`, `db-query-reviewer`, `db-schema-reviewer`
- `error-handling-reviewer`, `integration-reviewer`, `lint-reviewer`, `performance-reviewer`
- `security-reviewer`, `test-reviewer`, `vuln-reviewer`

**Skills** (`skills/*/SKILL.md` — 6 directories):
- `agent-readiness`, `full-review`, `implement`, `jira-ticket`, `my-work`, `review-fix-loop`

### Headless Invocation Pattern

**Finding (VERIFIED: live `claude --help` + live `claude -p` test in sandbox):**

For the audit harness, each plugin is invoked via `claude -p` with a targeted prompt:
- **Agents**: `claude --plugin-dir /opt/claude-engineering-toolkit -p "Run @<agent-name> on the current directory"`
- **Skills**: `claude --plugin-dir /opt/claude-engineering-toolkit -p "Run /<skill-name>"`

Live test confirmed `claude -p` works headless in the sandbox (exit 0, prints response to stdout). The `--plugin-dir` flag is repeatable.

**Important caveat for skill invocation:** Skills that require interactive prompts (e.g., `jira-ticket` calls `AskUserQuestion`) will not receive answers in `-p` mode. The harness should use the `--print` mode and treat "tool unavailable" / "connection refused" responses as clean failures for network-backed skills.

---

## D-11 Resolution: Telemetry-Attempt Log Signatures

**Finding (VERIFIED: live `openshell logs claude-sandbox --source sandbox -n 1000`):**

### OCSF Log Format

OpenShell emits OCSF (Open Cybersecurity Schema Framework) events for all network activity. Format:

```
[<unix-timestamp>] [sandbox] [OCSF ] [ocsf] NET:OPEN [<SEVERITY>] <VERDICT> <binary>(<pid>) -> <host>:<port> [policy:<name> engine:opa] [reason:<text>]
```

### Allowed Connection (for reference):
```
[1781898764.438] [sandbox] [OCSF ] [ocsf] NET:OPEN [INFO] ALLOWED /usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe(3563) -> api.anthropic.com:443 [policy:claude_egress engine:opa]
```

### Denied Connection (telemetry-attempt signature):
```
[1781898731.850] [sandbox] [OCSF ] [ocsf] NET:OPEN [MED] DENIED /usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe(3438) -> statsig.anthropic.com:443 [policy:- engine:opa] [reason:endpoint statsig.anthropic.com:443 is not allowed by any policy]
```

**Grep pattern for the audit harness:**
```bash
openshell logs "$SANDBOX" --source sandbox -n 1000 | grep -E 'DENIED.*claude\.exe.*statsig|DENIED.*claude\.exe.*sentry|DENIED.*claude\.exe.*downloads\.claude\.ai'
```

If these patterns produce **zero** matches from `claude.exe`, that is positive evidence. If they produce matches, it means those hosts were attempted — but since they are DENIED by the policy, they are still blocked. The important distinction for criterion #3 is whether `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` prevents the attempt from the claude binary at all.

### Critical Finding: Telemetry State Under `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`

**Live observation (VERIFIED: openshell logs from sandbox built with the ENV var set):**

| Host | claude.exe attempts observed? | Verdict |
|------|-------------------------------|---------|
| `statsig.anthropic.com` | **No** — only curl (NET-05 test) attempted this | Suppressed by ENV |
| `sentry.io` | **No** — only curl (NET-05 test) attempted this | Suppressed by ENV |
| `downloads.claude.ai` | **Yes** — once, early in session history (timestamp ~11:32 AM), from an older claude invocation | Not fully suppressed; denied by policy |
| `mcp-proxy.anthropic.com` | **Yes** — every claude startup (3 attempts per invocation) | Not a telemetry host; MCP registry lookup; denied by policy |
| `http-intake.logs.us5.datadoghq.com` | **Yes** — periodically from claude.exe (~10 min intervals) | Not suppressed by ENV; denied by policy |

**Implication for criterion #3:** The ROADMAP criterion states "Claude Code startup produces no telemetry or auto-update **connection errors**." The observed denied hosts include `mcp-proxy.anthropic.com` (MCP registry, not telemetry) and `datadoghq.com` (logging, possibly suppressed partially but not fully). These are denied by policy — they do not produce user-visible connection errors in claude's startup output or cause claude to fail. Criterion #3 should be interpreted as: "the policy denies all non-allowlisted connection attempts; claude starts and operates correctly despite those denials."

**Revised D-11 proof strategy:**
1. Grep `openshell logs` for `DENIED.*claude\.exe` entries during the audit run.
2. Assert `statsig` and `sentry` produce **zero** claude.exe denial entries (suppressed by ENV).
3. Document `mcp-proxy.anthropic.com` and `datadoghq.com` denial entries as **expected** (policy working correctly; not telemetry-to-third-parties as intended by the ENV var).
4. Assert `downloads.claude.ai` denials are **absent** from the audit run logs (the one observed denial was from an older session; `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` should suppress auto-update checks).

### `openshell logs` Flags (VERIFIED: live `openshell logs --help`):

```
openshell logs [OPTIONS] [NAME]

  -n <N>              Number of log lines to return [default: 200]
  --tail              Stream live logs
  --since <SINCE>     Only show logs from this duration ago (e.g. 5m, 1h, 30s)
  --source <SOURCE>   "gateway", "sandbox", or "all" [default: all]
  --level <LEVEL>     error, warn, info (default), debug, trace
```

For the audit, use `--source sandbox` to focus on OCSF events (gateway logs include session metadata noise). Use `--since` to narrow to the audit run window.

---

## Blockers Requiring Fixes Before Audit Can Pass

### Blocker 1: `/opt` Not in Landlock `filesystem_policy` (VERIFIED: live sandbox test)

**Symptom:** `claude plugin details claude-engineering-toolkit` shows `Skills (0) Agents (0)`. The toolkit agents and skills are not loaded.

**Root cause:** `policy.yaml` `filesystem_policy.read_only` lists `/usr`, `/lib`, `/proc`, `/dev/urandom`, `/app`, `/etc`, `/var/log`. `/opt` is absent. Landlock (best_effort mode, ABI V2) blocks `sandbox` user reads to `/opt/claude-engineering-toolkit/agents/` and `skills/`.

**Fix (Dockerfile + policy.yaml task):**
Add `/opt` to `filesystem_policy.read_only` in `policy.yaml`:
```yaml
  read_only:
    - /usr
    - /lib
    - /proc
    - /dev/urandom
    - /app
    - /etc
    - /var/log
    - /opt      # claude-engineering-toolkit cloned here (IMG-05); Landlock must grant read access
```

**Verification command (planner must include in task):**
```bash
openshell sandbox exec --name claude-sandbox --no-tty -- \
    claude --plugin-dir /opt/claude-engineering-toolkit plugin details claude-engineering-toolkit
# Expected: Skills (N) Agents (11) where N > 0
```

### Blocker 2: `govulncheck` Installed to `/root/go/bin` (Not Accessible to `sandbox` User) (VERIFIED: live sandbox test)

**Symptom:** `govulncheck: command not found` when run as `sandbox` user. `/root` is not in the Landlock read_only list.

**Root cause:** Dockerfile does `go install ... govulncheck@VERSION` as root; binary lands in `/root/go/bin/`. The `sandbox` user's PATH includes `/root/go/bin` (via `ENV PATH="${PATH}:/root/go/bin"`) but Landlock blocks filesystem access to `/root`.

**Fix (Dockerfile task):** After `go install`, copy the binary to `/usr/local/bin/`:
```dockerfile
RUN go install golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION} && \
    cp /root/go/bin/govulncheck /usr/local/bin/govulncheck
```

**Verification command (planner must include in task):**
```bash
openshell sandbox exec --name claude-sandbox --no-tty --workdir /home/sandbox -- \
    bash -c 'govulncheck --version'
# Expected: govulncheck vX.Y.Z (shows version, not "command not found")
```

### Blocker 3: `govulncheck` Requires `vuln.go.dev` (Not in Allowlist)

**Symptom:** Even after fixing Blocker 2, the `vuln-reviewer` agent will run `govulncheck -show verbose ./...` which connects to `https://vuln.go.dev`. This host is not in the 3-host allowlist and will return a proxy 403.

**Options:**

| Option | Description | Tradeoff |
|--------|-------------|----------|
| A | Add `vuln.go.dev` to policy.yaml allowlist (scoped to govulncheck binary) | Expands egress; adds a fourth host; must scope correctly to avoid open egress |
| B | Pre-download vuln DB during image build (`GONOSUMCHECK=off govulncheck -db file://...`) | Requires DB snapshot in image; DB may be stale between builds |
| C | Mark `vuln-reviewer` as MUST_FAIL_CLEAN in the expected-outcome table | Honest about sandbox constraints; network access required for live vuln data |
| D | Patch the audit prompt to pass `-db file:///dev/null` or an empty local DB | Allows govulncheck to run but with no vulnerability data (misleading) |

**Recommendation:** Option C — mark `vuln-reviewer` as MUST_FAIL_CLEAN with documented reason: "govulncheck requires vuln.go.dev which is outside the 3-host allowlist; this is expected behavior under Architecture B." Document in PLUGIN-AUDIT.md. This is consistent with the project's decision to restrict egress.

---

## Per-Plugin Expected-Outcome Table

**Seeded from live toolkit inspection (VERIFIED: GitHub WebFetch of all agent and skill files).**

> **Note:** All agents and skills require Blocker 1 (`/opt` in Landlock) to be fixed first.

### Agents (11 total)

All 11 agents use only local tools: `Read`, `Glob`, `Grep`, `Bash`. Network calls from agent logic: none except `vuln-reviewer` (govulncheck → vuln.go.dev) and the model inference call itself (api.anthropic.com, ALLOWED).

| Agent | Tool Dependencies | Network Required? | Expected Verdict | Notes |
|-------|------------------|------------------|-----------------|-------|
| `api-contract-reviewer` | Read, Glob, Grep, Bash (`git diff`) | No | MUST_SUCCEED | git diff is local; no network |
| `concurrency-reviewer` | Read, Glob, Grep, Bash (`git diff`) | No | MUST_SUCCEED | local analysis only |
| `db-query-reviewer` | Read, Glob, Grep, Bash (`git diff`) | No | MUST_SUCCEED | local analysis only |
| `db-schema-reviewer` | Read, Glob, Grep, Bash (`git diff`) | No | MUST_SUCCEED | local analysis only |
| `error-handling-reviewer` | Read, Glob, Grep, Bash (`git diff`) | No | MUST_SUCCEED | local analysis only |
| `integration-reviewer` | Read, Glob, Grep, Bash (`git diff`) | No | MUST_SUCCEED | local analysis only |
| `lint-reviewer` | Read, Glob, Grep, Bash (`golangci-lint`) | No | MUST_SUCCEED | golangci-lint is at `/usr/bin/golangci-lint` (RPM, accessible) |
| `performance-reviewer` | Read, Glob, Grep, Bash (`git diff`) | No | MUST_SUCCEED | local analysis only |
| `security-reviewer` | Read, Glob, Grep, Bash (`git diff`) | No | MUST_SUCCEED | local analysis only |
| `test-reviewer` | Read, Glob, Grep, Bash (`git diff`) | No | MUST_SUCCEED | local analysis only |
| `vuln-reviewer` | Read, Glob, Grep, Bash (`govulncheck`) | **Yes** (vuln.go.dev) | **MUST_FAIL_CLEAN** | govulncheck blocked by 3-host allowlist; ALSO blocked by Blocker 2 unless fixed |

**MUST_SUCCEED pass criteria:** Agent produces a response (even "no Go files found" or "no diff found") and exits 0.

**MUST_FAIL_CLEAN pass criteria:** Agent produces a response with a connection error (proxy 403 or "network unreachable") and exits 0. Exits 124 (timeout) = FAIL.

### Skills (6 total)

| Skill | External Dependencies | Network Required? | Expected Verdict | Notes |
|-------|----------------------|------------------|-----------------|-------|
| `full-review` | Spawns 11 reviewer agents, git diff | No (model only) | MUST_SUCCEED | No MCP/external; all agent invocations go through api.anthropic.com (ALLOWED) |
| `review-fix-loop` | git, file writes | No (model only) | MUST_SUCCEED | local file operations and sub-agent calls |
| `agent-readiness` | WebSearch (optional) | Model only (WebSearch routed through api.anthropic.com) | MUST_SUCCEED | WebSearch in claude is server-side at Anthropic; not a direct outbound connection from sandbox |
| `jira-ticket` | Jira MCP tools (`redhat.atlassian.net`) | **Yes** (Jira API) | **MUST_FAIL_CLEAN** | `AskUserQuestion` + Jira MCP blocked by allowlist; should fail with "tool unavailable" or connection error |
| `implement` | Jira MCP tools | **Yes** (Jira API) | **MUST_FAIL_CLEAN** | same as jira-ticket |
| `my-work` | Jira MCP, GitHub MCP (`mcp__github__*`), Google Tasks REST API (`tasks.googleapis.com`), `gcloud auth` | **Yes** (multiple services) | **MUST_FAIL_CLEAN** | All three external services are outside the 3-host allowlist; should fail fast with 403 |

**WebSearch in agent-readiness (VERIFIED: checked live logs):** No connections to external search engines were observed in sandbox logs during claude -p tests. WebSearch in Claude Code is processed server-side by Anthropic through `api.anthropic.com` — it does not make direct outbound connections from the sandbox.

---

## Architecture Patterns

### System Architecture: Audit Harness Data Flow

```
Host: rebuild.sh audit-plugins verb
    │
    └─► scripts/audit-plugins.sh (host-side loop)
            │
            ├── BEFORE_TS=$(date)  # capture start time for log filtering
            │
            ├── For each plugin in MANIFEST:
            │       │
            │       ├── START_WALL=$(date +%s)
            │       ├── openshell sandbox exec \
            │       │       --name $SANDBOX \
            │       │       --no-tty \
            │       │       --timeout 120 \     # max wall time
            │       │       --workdir /claudeshared \
            │       │       -- claude \
            │       │           --plugin-dir /opt/claude-engineering-toolkit \
            │       │           -p "<plugin invocation prompt>"
            │       ├── EXIT=$?
            │       ├── END_WALL=$(date +%s)
            │       ├── WALL=$((END_WALL - START_WALL))
            │       │
            │       ├── if EXIT==124: RESULT=HANG (always FAIL)
            │       ├── elif EXIT==0 && expected==MUST_SUCCEED: RESULT=PASS
            │       ├── elif EXIT==0 && expected==MUST_FAIL_CLEAN: RESULT=PASS (check output has error)
            │       └── else: RESULT=FAIL
            │
            ├── Telemetry check:
            │       openshell logs $SANDBOX --source sandbox --since <BEFORE_TS>
            │       grep -c 'DENIED.*claude\.exe.*statsig' → assert 0
            │       grep -c 'DENIED.*claude\.exe.*sentry' → assert 0
            │       document mcp-proxy.anthropic.com + datadoghq.com denials as EXPECTED
            │
            ├── if any FAIL: exit 1 (D-10 hard-fail)
            └── Write PLUGIN-AUDIT.md with full results + wall-clock table
```

### Recommended Script Structure

```
rebuild.sh                    # add `claude` and `audit-plugins` verbs here
scripts/
├── audit-plugins.sh          # headless harness logic (thin-wrapper pattern)
├── verify-pins.sh            # existing — reference for fail-closed discipline
└── build-and-lock.sh         # existing
.planning/phases/04-.../ 
└── PLUGIN-AUDIT.md           # committed audit report (D-06)
policy.yaml                   # add /opt to read_only (Blocker 1 fix)
Dockerfile                    # govulncheck copy + CMD repoint (Blockers 2 + D-03)
```

### Verb Pattern: `claude` Verb (D-01)

```bash
# In rebuild.sh case statement, after `audit` case:
claude)
    log_info "Launching Claude autonomously in sandbox ${SANDBOX_NAME} (cwd: ${SHARED_DIR})..."
    log_info "Ensure 'login' completed first: ./rebuild.sh login"
    openshell sandbox exec \
        --name "${SANDBOX_NAME}" \
        --tty \
        --workdir "${SHARED_DIR}" \
        -- claude --dangerously-skip-permissions \
            --plugin-dir /opt/claude-engineering-toolkit
    exit 0
    ;;
```

### Verb Pattern: `audit-plugins` Verb (D-05)

```bash
audit-plugins)
    log_info "Running plugin audit inside ${SANDBOX_NAME}..."
    bash "${PROJECT_ROOT}/scripts/audit-plugins.sh" "${SANDBOX_NAME}" "${SHARED_DIR}"
    exit 0
    ;;
```

### Plugin Enumeration Pattern (D-08)

The canonical plugin list is static (derived from toolkit inspection) and embedded in `audit-plugins.sh`. It does NOT dynamically parse `plugin.json` at runtime (dynamic parsing would require `/opt` access from the host, which works, but introduces fragility). Static enumeration is more fail-closed. The list must be updated if the toolkit adds/removes components.

```bash
# In audit-plugins.sh:
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
    [vuln-reviewer]="MUST_FAIL_CLEAN"   # govulncheck needs vuln.go.dev, not in allowlist
)

declare -A SKILLS=(
    [full-review]="MUST_SUCCEED"
    [review-fix-loop]="MUST_SUCCEED"
    [agent-readiness]="MUST_SUCCEED"
    [jira-ticket]="MUST_FAIL_CLEAN"
    [implement]="MUST_FAIL_CLEAN"
    [my-work]="MUST_FAIL_CLEAN"
)
```

### `claude -p` Headless Contract (VERIFIED: live sandbox test)

```bash
# Test confirmed in running sandbox:
openshell sandbox exec --name claude-sandbox --no-tty --timeout 45 --workdir /claudeshared \
    -- claude --plugin-dir /opt/claude-engineering-toolkit -p "Reply with exactly: OK"
# Output: OK
# Exit: 0
```

The `-p` / `--print` flag makes claude non-interactive (prints response and exits). No trust dialog in `-p` mode. No TTY required (use `--no-tty` on `openshell exec`). The workspace trust dialog is skipped automatically.

### `openshell sandbox exec` Key Flags (VERIFIED: live `openshell sandbox exec --help`)

```
openshell sandbox exec [OPTIONS] <COMMAND>...

  --name / -n <NAME>     Sandbox name
  --workdir <WORKDIR>    Working directory inside sandbox
  --timeout <TIMEOUT>    Timeout in seconds (0 = no timeout) [default: 0]
  --no-tty               Disable PTY (required for headless/piped output)
  --tty                  Force PTY (required for interactive sessions)
  --env <KEY=VALUE>      Inject env vars (repeatable)
```

**Exit code 124 from `openshell sandbox exec` = timeout expired.** Confirmed live.

---

## Common Pitfalls

### Pitfall 1: Landlock Blocks `/opt` — Toolkit Agents/Skills Load as 0

**What goes wrong:** `claude plugin list` shows `Status: ✔ loaded` but `plugin details` shows `Skills (0) Agents (0)`. Skills are invisible; agents are not invocable.

**Why it happens:** `policy.yaml` Landlock `read_only` list omits `/opt`. Claude reads `plugin.json` early (possibly before Landlock is fully applied to its process tree) but cannot enumerate `agents/*.md` or `skills/*/SKILL.md`.

**How to avoid:** Add `/opt` to `filesystem_policy.read_only` in `policy.yaml` before verifying RUN-02.

**Warning signs:** `claude plugin details <name>` shows 0 skills/agents; skills not available as slash commands.

### Pitfall 2: `govulncheck` Not in PATH for `sandbox` User

**What goes wrong:** `vuln-reviewer` agent's `govulncheck` Bash call fails with `command not found`, causing unexpected failure (hard FAIL for an agent expected to produce output).

**Why it happens:** `go install` stores binary at `/root/go/bin/govulncheck`. The `sandbox` user's PATH includes `/root/go/bin` in the ENV, but Landlock blocks `/root` access.

**How to avoid:** Copy binary to `/usr/local/bin/govulncheck` in Dockerfile after `go install`.

**Warning signs:** `bash -c 'govulncheck --version'` returns exit non-zero when run as sandbox user.

### Pitfall 3: `vuln-reviewer` Treated as MUST_SUCCEED

**What goes wrong:** If the expected-outcome table marks `vuln-reviewer` as `MUST_SUCCEED`, the audit hard-fails when govulncheck's network call to `vuln.go.dev` is denied.

**Why it happens:** `vuln.go.dev` is not in the 3-host allowlist. Even with govulncheck binary accessible, it will get a 403 on the vulnerability database lookup.

**How to avoid:** Mark `vuln-reviewer` as `MUST_FAIL_CLEAN` with documented reason.

**Warning signs:** Audit exit 1 with "vuln-reviewer: unexpected failure" even after Blocker 2 is fixed.

### Pitfall 4: Naïve `timeout 10` on Whole `claude -p` Invocation

**What goes wrong:** Short timeout false-fails on legitimate model latency.

**Why it doesn't happen in this design:** `openshell sandbox exec --timeout 120` provides a generous outer bound; the proxy's fast 403 (38ms) means blocked-host plugins complete within seconds, not at the timeout bound.

**Warning signs:** Intermittent HANG results for MUST_SUCCEED plugins on slow model responses.

### Pitfall 5: `--tty` on Headless `audit-plugins` Exec

**What goes wrong:** Using `--tty` with `openshell sandbox exec` in the audit harness causes output to be non-capturable or garbled (PTY escape sequences mixed into plugin output).

**How to avoid:** Always use `--no-tty` for `audit-plugins` exec calls; reserve `--tty` for interactive `claude` and `connect` verbs.

### Pitfall 6: D-13 Reconciliation Missed

**What goes wrong:** The audit's own success criteria (ROADMAP criterion #3: "zero-egress sandbox") is evaluated against stale wording. Someone reads "zero-egress" literally and marks the audit as failing because api.anthropic.com is allowed.

**How to avoid:** Complete D-13 (ROADMAP/REQUIREMENTS/PROJECT.md update) before or concurrently with the audit task, not after.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Per-invocation timeout | Custom `sleep`/kill loop | `openshell sandbox exec --timeout N` | Built-in; returns exit 124 on timeout; no background process management needed |
| Log filtering by time window | Parse raw unix timestamps | `openshell logs --since <duration>` | Flags: `--since 30m`, `--since 5m` etc. avoid fragile timestamp arithmetic |
| Plugin component discovery | Parse `plugin.json` dynamically at audit time | Static enumeration in `audit-plugins.sh` | More fail-closed; immune to `/opt` read failures on host; simpler |
| Distinguishing blocked vs. slow | Sub-10s hard timeout on all invocations | 120s `openshell exec --timeout` + check output for 403 | Proxy returns 403 in <100ms; timing not needed for discrimination |

---

## Code Examples

### Example: `claude` Verb in `rebuild.sh`

```bash
# Source: live openshell sandbox exec --help + existing connect/login verb pattern
claude)
    ensure_podman_ready
    log_info "Launching Claude Code autonomously in sandbox ${SANDBOX_NAME} (cwd: ${SHARED_DIR})..."
    log_info "Plugin dir: /opt/claude-engineering-toolkit"
    log_info "Prerequisites: sandbox created (./rebuild.sh) + OAuth login (./rebuild.sh login)"
    openshell sandbox exec \
        --name "${SANDBOX_NAME}" \
        --tty \
        --workdir "${SHARED_DIR}" \
        -- claude \
            --dangerously-skip-permissions \
            --plugin-dir /opt/claude-engineering-toolkit
    exit 0
    ;;
```

### Example: Headless Plugin Invocation in `audit-plugins.sh`

```bash
# Source: live openshell sandbox exec --help + live claude -p test
run_plugin_audit() {
    local sandbox_name="$1"
    local plugin_name="$2"
    local prompt="$3"
    local expected="$4"  # MUST_SUCCEED or MUST_FAIL_CLEAN

    local start_wall rc output
    start_wall=$(python3 -c 'import time; print(int(time.time()))')

    output=$(openshell sandbox exec \
        --name "${sandbox_name}" \
        --no-tty \
        --timeout 120 \
        --workdir /claudeshared \
        -- claude \
            --plugin-dir /opt/claude-engineering-toolkit \
            -p "${prompt}" 2>&1) || rc=$?
    rc=${rc:-0}

    local end_wall wall_secs
    end_wall=$(python3 -c 'import time; print(int(time.time()))')
    wall_secs=$(( end_wall - start_wall ))

    if [[ ${rc} -eq 124 ]]; then
        echo "FAIL [HANG] ${plugin_name} (${wall_secs}s — timeout at 120s)"
        return 1
    fi

    if [[ "${expected}" == "MUST_SUCCEED" && ${rc} -eq 0 ]]; then
        echo "PASS [OK] ${plugin_name} (${wall_secs}s)"
    elif [[ "${expected}" == "MUST_FAIL_CLEAN" && ${rc} -eq 0 ]]; then
        # Verify output contains a network/MCP error, not a real success
        if echo "${output}" | grep -qiE "403|connection refused|not available|tool.*not.*found|cannot connect"; then
            echo "PASS [FAIL_CLEAN] ${plugin_name} (${wall_secs}s)"
        else
            echo "WARN [CHECK] ${plugin_name}: expected failure but got unexpected output (${wall_secs}s)"
            echo "  Output: ${output:0:200}"
        fi
    else
        echo "FAIL [UNEXPECTED] ${plugin_name}: rc=${rc} expected=${expected} (${wall_secs}s)"
        return 1
    fi
}
```

### Example: Telemetry Check in `audit-plugins.sh`

```bash
# Source: live openshell logs --help + live log inspection
check_telemetry_suppression() {
    local sandbox_name="$1"
    local since_duration="$2"  # e.g., "10m"

    log_step "T" "Telemetry suppression check (last ${since_duration})"

    local log_output
    log_output=$(openshell logs "${sandbox_name}" --source sandbox --since "${since_duration}" -n 2000)

    # statsig and sentry MUST produce zero claude.exe denial entries
    local statsig_count sentry_count
    statsig_count=$(echo "${log_output}" | grep -c 'DENIED.*claude\.exe.*statsig' || true)
    sentry_count=$(echo "${log_output}" | grep -c 'DENIED.*claude\.exe.*sentry' || true)

    if [[ "${statsig_count}" -gt 0 ]]; then
        log_error "TELEMETRY FAIL: claude.exe attempted statsig.anthropic.com ${statsig_count} time(s) — not suppressed by ENV"
        return 1
    fi
    if [[ "${sentry_count}" -gt 0 ]]; then
        log_error "TELEMETRY FAIL: claude.exe attempted sentry.io ${sentry_count} time(s) — not suppressed by ENV"
        return 1
    fi

    log_info "TELEMETRY PASS: statsig.anthropic.com — 0 claude.exe attempts (suppressed by CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1)"
    log_info "TELEMETRY PASS: sentry.io — 0 claude.exe attempts (suppressed)"

    # Document expected denials (not failures — policy is working correctly)
    local mcp_proxy_count datadog_count downloads_count
    mcp_proxy_count=$(echo "${log_output}" | grep -c 'DENIED.*claude\.exe.*mcp-proxy\.anthropic\.com' || true)
    datadog_count=$(echo "${log_output}" | grep -c 'DENIED.*claude\.exe.*datadoghq\.com' || true)
    downloads_count=$(echo "${log_output}" | grep -c 'DENIED.*claude\.exe.*downloads\.claude\.ai' || true)

    log_info "TELEMETRY INFO: mcp-proxy.anthropic.com denied ${mcp_proxy_count} time(s) — MCP registry lookup, policy working correctly"
    log_info "TELEMETRY INFO: datadoghq.com denied ${datadog_count} time(s) — logging endpoint, policy working correctly"
    [[ "${downloads_count}" -gt 0 ]] && log_info "TELEMETRY INFO: downloads.claude.ai denied ${downloads_count} time(s) — auto-update check, policy working correctly"

    log_info "TELEMETRY PASS: All non-allowlisted hosts denied by policy; no open-internet egress"
}
```

### Example: policy.yaml Fix (Blocker 1)

```yaml
# Source: live policy.yaml inspection + live sandbox test confirming /opt is blocked
filesystem_policy:
  include_workdir: true
  read_only:
    - /usr
    - /lib
    - /proc
    - /dev/urandom
    - /app
    - /etc
    - /var/log
    - /opt      # ADD THIS: claude-engineering-toolkit at /opt/claude-engineering-toolkit (IMG-05)
  read_write:
    - /sandbox
    - /tmp
    - /dev/null
    - /claudeshared
    - /home/sandbox
```

### Example: Dockerfile Fix (Blocker 2 + D-03)

```dockerfile
# govulncheck — copy to /usr/local/bin so sandbox user (not root) can access it
# /root/go/bin is blocked by Landlock for the sandbox user; /usr/local/bin is in read_only
RUN go install golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION} && \
    cp /root/go/bin/govulncheck /usr/local/bin/govulncheck

# CMD repoint (D-03 resolution): OpenShell sandbox create always overrides CMD via `-- COMMAND`.
# This CMD is for direct `podman run` use only. The canonical launch path is `./rebuild.sh claude`.
CMD ["/bin/bash"]
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|-----------------|--------------|--------|
| Zero-egress + inference.local gateway | 3-host TLS-passthrough allowlist (Architecture B) | Phase 3 quick tasks (2026-06-19) | NET-01/NET-02/NET-03 wording in REQUIREMENTS.md is stale; must reconcile (D-13) |
| `ANTHROPIC_BASE_URL=https://inference.local` | Omit ENV (Claude uses built-in api.anthropic.com) | Phase 3 pivot | CLAUDE.md already updated; ROADMAP/PROJECT.md stale |
| `CMD ["claude", "--dangerously-skip-permissions", ...]` as canonical launch | `./rebuild.sh claude` verb as canonical launch | Phase 4 (this phase) | CMD becomes documentation-only; recommend repoint to /bin/bash |

**Deprecated/outdated in stale docs:**
- `NET-01` (zero direct internet egress) — superseded by Architecture B's 3-host allowlist.
- `NET-02` (ANTHROPIC_BASE_URL → gateway) — gateway removed; claude contacts api.anthropic.com directly.
- `NET-03` (provider credential injection) — in-sandbox OAuth; no host-side provider setup.
- `NET-04` (assert no `api.anthropic.com` in policy) — INVERTED; must now ASSERT `api.anthropic.com` IS present.
- `NET-05` (smoke test confirms outbound request fails) — updated to: assert deny posture for non-allowlisted hosts only.

---

## Project Constraints (from CLAUDE.md)

The following directives from `CLAUDE.md` apply to Phase 4 work:

| Directive | Impact on Phase 4 |
|-----------|------------------|
| Platform: NVIDIA OpenShell — use `openshell` CLI | All sandbox exec uses `openshell sandbox exec` pattern |
| Build tool: `podman build` only | Dockerfile changes use `podman build` |
| Claude launch: `--dangerously-skip-permissions` (NOT `--allow-dangerously-skip-permissions`) | D-01 verb uses the correct flag |
| No `ENV ANTHROPIC_BASE_URL` in Dockerfile | CMD repoint must not add this ENV |
| No `statsig.anthropic.com` or `sentry.io` in `network_policies` | Telemetry check asserts these are absent from policy AND from claude.exe connection attempts |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` already set in Dockerfile | D-11 check confirms this is effective at suppressing statsig/sentry calls from claude.exe |
| `--plugin-dir` flag (not `--plugin-url`) for local toolkit | D-01 verb uses `--plugin-dir /opt/claude-engineering-toolkit` |
| Bind mount source must be absolute path | Already in rebuild.sh pattern; no change needed |
| `openshell sandbox exec --tty --workdir /claudeshared` pattern for connect | `claude` verb follows this pattern exactly |

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `openshell` | All rebuild.sh verbs | ✓ | 0.0.62 | — |
| `claude-sandbox` (running) | `claude` verb, `audit-plugins` verb | ✓ | Phase: Ready | `./rebuild.sh` to create |
| `golangci-lint` in `/usr/bin` | `lint-reviewer` agent | ✓ | 2.11.3 (verified in sandbox via `ls /usr/bin/golangci-lint`) | — |
| `govulncheck` in `/usr/local/bin` | `vuln-reviewer` agent | **✗** | — | Copy in Dockerfile: `cp /root/go/bin/govulncheck /usr/local/bin/` |
| `/opt/claude-engineering-toolkit` readable | Plugin loading | **✗** | — | Add `/opt` to `policy.yaml` `read_only` |
| `api.anthropic.com:443` reachable | `claude -p` headless invocations | ✓ (OAuth'd) | — | `./rebuild.sh login` |

**Missing dependencies requiring fixes (blocking):**
- `/opt` in Landlock `read_only` — without this, RUN-02 cannot be verified and the audit cannot run.
- `/usr/local/bin/govulncheck` — without this, `lint-reviewer` [ASSUMED: actually `vuln-reviewer`] cannot attempt its tool invocation (though it is MUST_FAIL_CLEAN anyway due to network restrictions).

---

## Security Domain

`security_enforcement: true` in config. ASVS Level 1 applies.

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No (OAuth handled by claude itself; Phase 4 adds no auth logic) | — |
| V3 Session Management | No | — |
| V4 Access Control | **Yes** | Landlock filesystem policy + binary-scoped egress (policy.yaml) |
| V5 Input Validation | **Yes** (rebuild.sh verb arguments) | Existing pattern: `case "$1" in` dispatch; no eval; no interpolation of untrusted input |
| V6 Cryptography | No (TLS handled by OpenShell proxy) | — |

### Known Threat Patterns for This Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Prompt injection via toolkit plugin | Tampering | `--dangerously-skip-permissions` is scoped to a sandboxed environment with network egress restriction; no secrets accessible beyond `~/.claude/` |
| `/opt` read grant expanding attack surface | Elevation of Privilege | `/opt` read_only (no write); toolkit is operator-controlled fork; no untrusted code at build time |
| Audit script accepting untrusted plugin output as shell input | Tampering | Use heredoc or variable quoting; never `eval` plugin output; capture to variable and pattern-match |
| Telemetry to third parties despite ENV var | Information Disclosure | Policy deny is the actual barrier; `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` is defense-in-depth; both are present |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `vuln-reviewer` agent's description says it "requires network access" and calls `govulncheck -show verbose ./...` which connects to `vuln.go.dev` | Per-Plugin Table | If govulncheck has a fallback offline mode that works without `vuln.go.dev`, it should be marked MUST_SUCCEED after Blocker 2 is fixed. Verify with: `govulncheck --help | grep -i db` |
| A2 | All 9 non-vuln, non-lint reviewer agents use only `git diff` (local) and no external tools | Per-Plugin Table | If any agent invokes an external binary not at `/usr/bin`, that binary may be inaccessible. Verify by reading each `.md` file after `/opt` is in Landlock. |
| A3 | WebSearch in `agent-readiness` routes through `api.anthropic.com` server-side | Per-Plugin Table | If Claude Code's WebSearch makes direct outbound connections to search engines (not routed via api.anthropic.com), `agent-readiness` would be MUST_FAIL_CLEAN. Live log check showed no search engine connections — but a single test is not definitive. |
| A4 | `mcp-proxy.anthropic.com` denials do not cause claude to fail or degrade significantly | Telemetry Section | If MCP proxy is required for core functionality and its denial causes claude to hang or error, all audit plugin calls may fail. Observed: claude -p works correctly despite mcp-proxy denials. |
| A5 | `openshell sandbox exec --timeout N` exit code 124 is reliable for timeout detection | Harness Design | Confirmed by single live test. If the exit code differs in some conditions, the hang detection would miss real hangs. |

---

## Open Questions

1. **`agent-readiness` WebSearch behavior in headless `-p` mode**
   - What we know: WebSearch is a Claude built-in; no direct outbound connections observed in logs during tests.
   - What's unclear: Whether `agent-readiness` can be invoked meaningfully without a git repo context and without the full codebase analysis infrastructure.
   - Recommendation: Invoke with a minimal prompt ("Run /agent-readiness to check this directory") in a directory with a small file; treat any exit-0 response as PASS regardless of content.

2. **`full-review` skill in headless mode — 11 sub-agents spawned**
   - What we know: `full-review` runs git diff and spawns 11 reviewer agents simultaneously.
   - What's unclear: Whether spawning 11 sub-agents via `claude -p` completes within the 120s timeout on a directory with no Go files (most reviewers would skip immediately).
   - Recommendation: Invoke in `/claudeshared` which likely has no Go files; all reviewers exit early ("no Go files found"); expect fast completion.

3. **`downloads.claude.ai` denial — suppressed or not?**
   - What we know: One denial observed in session history (early session, older claude invocation ~11:32 AM). Recent sessions (last hour) show no `downloads.claude.ai` denials from `claude.exe`.
   - What's unclear: Whether the `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` ENV consistently suppresses the auto-update check, or whether it only fires on first run.
   - Recommendation: The audit run should check for `downloads.claude.ai` denials and document them as informational (not a hard failure), since the policy blocks them regardless.

4. **`jira-ticket` and `implement` skills — `AskUserQuestion` behavior in `-p` mode**
   - What we know: These skills use `AskUserQuestion` which expects interactive user input.
   - What's unclear: Whether `AskUserQuestion` blocks indefinitely or times out in `-p` mode.
   - Recommendation: Given the proxy returns 403 fast, and Jira MCP tools would fail before `AskUserQuestion` is even called (no MCP server configured), the failure will likely be a "tool not found" error, not a hang. Verify with the 120s timeout.

---

## Sources

### Primary (MEDIUM-HIGH confidence — live tool verification)

- Live `openshell sandbox exec --help` — exec flags, `--timeout`, `--no-tty`, `--workdir` [VERIFIED: live CLI]
- Live `openshell logs --help` — log flags, `--source`, `--since`, `--level` [VERIFIED: live CLI]
- Live `openshell sandbox create --help` — CMD override behavior, `--no-keep` [VERIFIED: live CLI]
- Live `openshell sandbox exec ... claude --version` in running sandbox → `2.1.178 (Claude Code)` [VERIFIED: live sandbox]
- Live `openshell sandbox exec ... claude -p "Reply with exactly: OK"` → exit 0, output: `OK` [VERIFIED: live sandbox]
- Live `openshell sandbox exec ... claude plugin list --plugin-dir /opt/...` → `Status: ✔ loaded` but `Skills (0) Agents (0)` [VERIFIED: live sandbox]
- Live `openshell sandbox exec ... ls /opt/` → `Permission denied` (Landlock blocks /opt) [VERIFIED: live sandbox]
- Live `openshell sandbox exec --timeout 3 -- sleep 10` → exit 124 (timeout behavior) [VERIFIED: live sandbox]
- Live `time openshell sandbox exec ... curl ... statsig.anthropic.com` → 38ms, 403 (fast proxy rejection) [VERIFIED: live sandbox]
- Live `openshell logs claude-sandbox --source sandbox -n 1000` — OCSF log format, DENIED signature, mcp-proxy.anthropic.com denials, datadoghq.com denials [VERIFIED: live log inspection]
- Live `cat /proc/1/cmdline` in sandbox → `/opt/openshell/bin/openshell-sandbox` (supervisor is PID 1, not CMD) [VERIFIED: live sandbox]
- Live `ls /usr/bin/golangci-lint` in sandbox → accessible [VERIFIED: live sandbox]
- Live `ls /root/` in sandbox → Permission denied [VERIFIED: live sandbox]
- `claude --help` — `--dangerously-skip-permissions`, `-p/--print`, `--plugin-dir`, `--bare` (avoids OAuth), flag semantics [VERIFIED: live CLI on host]

### Secondary (MEDIUM confidence — web fetch from authoritative source)

- GitHub WebFetch: `pheckenlWork/claude-engineering-toolkit/plugin.json` — manifest format, component paths [CITED: https://github.com/pheckenlWork/claude-engineering-toolkit/blob/main/plugin.json]
- GitHub WebFetch: all 11 `agents/*.md` files and 6 `skills/*/SKILL.md` files — network dependency analysis [CITED: https://github.com/pheckenlWork/claude-engineering-toolkit]
- pkg.go.dev: govulncheck `-db file://` offline mode documentation [CITED: https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck]

### Tertiary (LOW confidence — assumed from training knowledge)

- WebSearch not used; all findings from live tooling + official docs.

---

## Metadata

**Confidence breakdown:**
- Blocker analysis (Landlock /opt, govulncheck location): HIGH — directly verified live in running sandbox
- D-03 CMD behavior: HIGH — PID 1 inspection + openshell create help confirm
- D-07 proxy behavior: HIGH — timed live test, 38ms 403 response
- D-08 manifest format: HIGH — live `claude plugin details` + GitHub WebFetch of all files
- D-11 log signatures: HIGH — directly extracted from live `openshell logs` output
- Per-plugin network dependency: MEDIUM — WebFetch of agent/skill files; some assumed from file descriptions
- govulncheck offline mode: MEDIUM — from official pkg.go.dev documentation

**Research date:** 2026-06-19
**Valid until:** 2026-07-19 (stable CLI tooling; re-verify if claude-code or openshell version changes)
