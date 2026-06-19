# Phase 4: Claude Code Launch and MCP Audit - Context

**Gathered:** 2026-06-19
**Status:** Ready for planning

<domain>
## Phase Boundary

Take the now-isolated sandbox (Phase 3, **Architecture B** — see callout below)
and prove the *autonomous Claude launch* works end-to-end, then audit every
claude-engineering-toolkit plugin for clean behavior under the egress allowlist.

This phase delivers:

1. **A first-class launch path** (RUN-01, RUN-02) — Claude runs inside the
   sandbox with `--dangerously-skip-permissions --plugin-dir
   /opt/claude-engineering-toolkit`, with the toolkit agents/skills loaded.
2. **A reproducible plugin audit** (criterion #2) — each toolkit plugin invoked
   once headless; each either works or fails cleanly/deterministically; nothing
   hangs unbounded on a blocked-host network call.
3. **Telemetry-suppression evidence** (criterion #3) — proof that
   `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` keeps statsig/sentry/auto-update
   hosts uncontacted and produces no startup telemetry/connection errors.
4. **Stale-doc reconciliation** — bring ROADMAP/REQUIREMENTS/PROJECT.md into
   line with Architecture B (they still describe the superseded gateway/zero-
   egress model), so the phase's own success criteria are judged against reality.

**⚠️ Architecture reality (MUST frame all downstream work):** The project
pivoted during Phase 3 quick tasks (commits 4f99856 / a6c8e83) from the original
"zero-egress + `inference.local` gateway" design to **Architecture B**: Claude
Code runs in-sandbox, authenticates via **subscription OAuth** (`./rebuild.sh
login`), and reaches a **3-host direct TLS-passthrough allowlist** —
`api.anthropic.com:443`, `platform.claude.com:443`, `claude.ai:443` — binary-
scoped to `claude`. There is **no gateway, no `inference.local`, no zero-egress**.
`CLAUDE.md` is already updated to Architecture B; ROADMAP/REQUIREMENTS/PROJECT.md
are **stale**. ROADMAP criterion #3's phrase "zero-egress sandbox" must be read
as "the 3-host-allowlist sandbox."

**In scope (Phase 4):**
- New `./rebuild.sh claude` verb that launches the autonomous Claude session
  (RUN-01, RUN-02).
- New `./rebuild.sh audit-plugins` verb + committed audit report (criterion #2).
- Telemetry-suppression check folded into the `audit-plugins` run (criterion #3).
- Doc reconciliation of ROADMAP/REQUIREMENTS/PROJECT.md to Architecture B.

**Out of scope:**
- Re-deriving the egress policy or auth model — Architecture B is locked
  (Phase 3). This phase consumes it, does not change it.
- Any new sandbox capability beyond launch + audit.
- `policy prove` formal verification (VER-01) / Makefile wrapper (ERG-01) — v2.
</domain>

<decisions>
## Implementation Decisions

### Launch entry point (RUN-01, RUN-02)
- **D-01:** Add a new **`./rebuild.sh claude` verb** as the canonical launch
  path. It execs into the running sandbox (`openshell sandbox exec --name
  $SANDBOX --tty --workdir /claudeshared --`) and runs `claude
  --dangerously-skip-permissions --plugin-dir /opt/claude-engineering-toolkit`.
  Mirrors the existing `login`/`connect` verb pattern (same `--tty --workdir
  /claudeshared` mechanism, since `/` is not Landlock-listable).
- **D-02:** The verb does **no OAuth precondition check** — it just launches.
  Claude itself handles the unauthenticated case (prints its own login prompt).
  Keeps the verb minimal; `login` remains the separate, documented auth step.
- **D-03:** The Dockerfile `CMD ["claude", "--dangerously-skip-permissions",
  "--plugin-dir", ...]` becomes vestigial once the verb owns the real launch.
  **Keep-vs-repoint is deferred to research:** the researcher confirms whether
  OpenShell's sandbox supervisor honors or overrides container `CMD` for a
  created sandbox, then chooses keep-as-documentation vs repoint-to-bash/sleep.
  The requirement (canonical flags live in the verb) is locked either way.

### Audit harness (criterion #2)
- **D-04:** The audit is a **scripted headless harness**, not a manual checklist
  — it drives `claude -p` once per plugin inside the sandbox, capturing
  exit/output per plugin. Reproducible; matches Phase 1–3 fail-closed
  verification discipline.
- **D-05:** Exposed as a new **`./rebuild.sh audit-plugins` verb** (distinct
  from the existing log-surfacing `audit` verb). Verb-first interface
  consistency. Logic may live in `scripts/audit-plugins.sh` if the planner
  prefers a thin-wrapper split, but the operator entry point is the verb.
- **D-06:** The audit **report artifact is written into the phase dir and
  committed** (e.g. `.planning/phases/04-…/PLUGIN-AUDIT.md` or an `audit/`
  report) as durable evidence that criterion #2 passed.
- **D-07 (research-designed):** The **10s "no network hang" bound** must
  distinguish a *blocked-host hang* (a connection to a denied host that stalls
  until killed — the criterion #2 failure mode) from *legitimate model round-
  trip latency* (`claude -p` calls `api.anthropic.com`, which is allowed and may
  take >10s). Locked intent: nothing stalls unbounded; pass = reached a terminal
  state (answer or deterministic error); record wall-clock so a >10s blocked-host
  stall is visible. A naïve `timeout 10` on the whole invocation is rejected (it
  false-fails legitimate model latency). Researcher determines the exact
  mechanism after probing real plugin behavior headless under the allowlist.

### Plugin enumeration & expected outcomes (criterion #2)
- **D-08:** The canonical plugin list is **enumerated from the toolkit's own
  manifest** at `/opt/claude-engineering-toolkit` (the agents + skills it
  registers), so the audit can't drift from what's installed. Researcher
  confirms the manifest format / discovery mechanism.
- **D-09:** Maintain a **per-plugin expected-outcome table** encoding *intended
  correct behavior*: local-tool plugins (lint, vuln, security, and other agents
  that run `golangci-lint`/`govulncheck`/grep locally) **MUST succeed**;
  network/MCP-backed plugins (e.g. `my-work`, `jira-ticket` → Jira/GitHub/Google,
  all blocked by the 3-host allowlist) **MUST fail cleanly/deterministically**
  within bounds. The table encodes the *intended* verdict — research **seeds it
  by probing actual behavior**, and any divergence between observed and intended
  is a finding to **fix or explicitly justify before the table is locked**, not
  something to bake in as "expected."
- **D-10:** The audit **hard-fails on any expected/actual mismatch** — exit
  non-zero if any plugin deviates from its locked expected verdict. Makes
  criterion #2 a real gate (catches both unbounded hangs and plugins that
  wrongly succeed/fail), and turns the committed report into a regression guard.

### Telemetry suppression (criterion #3)
- **D-11:** Prove suppression via **two independent angles**: (a) inspect
  `openshell logs` for any outbound connection *attempt* to the known telemetry/
  update hosts (`statsig.anthropic.com`, `sentry.io`, `downloads.claude.ai` —
  none are in the allowlist, so attempts would be denied + logged), AND (b) grep
  Claude's own startup output for telemetry/auto-update connection errors.
- **D-12:** This check is **folded into the same `./rebuild.sh audit-plugins`
  run** — that run already launches Claude, so it captures startup cleanliness
  there. One command covers the audit + telemetry evidence.

### Documentation reconciliation
- **D-13:** Updating the stale planning docs to Architecture B is **in-scope
  Phase 4 work** (the planner allocates a task): ROADMAP success-criteria wording
  (esp. Phase 4 #3 "zero-egress sandbox"), REQUIREMENTS NET-/RUN- notes that
  reference the gateway/`inference.local`/`ANTHROPIC_BASE_URL`, and PROJECT.md
  Core Value + Key Decisions. This is doc-truth correction, **not** a new
  capability — it ensures the audit and its criteria are judged against reality.

### Claude's Discretion (locked intent, mechanism open — deferred to research)
- Dockerfile `CMD` keep-vs-repoint (D-03) — pending OpenShell CMD-honoring
  behavior.
- The 10s-bound mechanism (D-07) — blocked-host-hang vs model-latency
  discrimination.
- Toolkit manifest discovery format (D-08) and how to invoke each plugin once
  headless via `claude -p` (the exact prompt/agent-invocation per plugin type).
- Exact telemetry-attempt signature to grep for in `openshell logs` (D-11).
</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project specs & requirements (this repo)
- `CLAUDE.md` — **authoritative tech-stack spec, already on Architecture B.**
  For Phase 4 specifically: "Network Policy — Three-Host Claude Egress Allowlist
  (Architecture B)"; "Runtime Configuration"; "Plugin Loading (`--plugin-dir`)";
  "5. Claude Code CLI" (launch flags, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`);
  "What NOT to Use" (esp. `--allow-dangerously-skip-permissions` anti-pattern,
  adding `statsig.anthropic.com`/`sentry.io` anti-pattern). MUST read first.
- `.planning/REQUIREMENTS.md` §RUN — RUN-01 (`--dangerously-skip-permissions`)
  and RUN-02 (`--plugin-dir` at the toolkit) are the two requirements this phase
  satisfies. **Note: this file is stale (gateway/zero-egress wording) and is a
  D-13 reconciliation target.**
- `.planning/ROADMAP.md` → "Phase 4: Claude Code Launch and MCP Audit" — goal +
  3 success criteria. **Criterion #3's "zero-egress sandbox" = the 3-host-
  allowlist sandbox; this file is a D-13 reconciliation target.**
- `.planning/PROJECT.md` — Core Value + Key Decisions still describe the gateway
  model; **D-13 reconciliation target.**
- `.planning/phases/03-network-isolation-and-inference-validation/03-CONTEXT.md`
  — Phase 3 decisions; note it predates the Architecture B pivot, so read it
  alongside the Phase 3 quick-task notes in STATE.md (commits 4f99856, a6c8e83,
  851eae4, 6338120) which record the actual shipped design.

### Repo artifacts to extend (this repo)
- `rebuild.sh` (verb-first orchestrator: `rebuild|status|connect|login|down|
  audit`) — add `claude` and `audit-plugins` verbs. Match conventions:
  `set -euo pipefail`, `ts`/`log_step`/`log_info`/`log_error`, `=== [ts] Step N
  ===` banners, fail-closed gates. The `connect`/`login` verbs already use
  `openshell sandbox exec --name $SANDBOX --tty --workdir /claudeshared --
  /bin/bash` — the new `claude` verb reuses this exec pattern (D-01).
- `Dockerfile` — line 47 `ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`
  (criterion #3 mechanism); lines 76–80 clone the toolkit to
  `/opt/claude-engineering-toolkit` (IMG-05); line 116 `CMD` carries the launch
  flags (D-03 keep-vs-repoint). Architecture B note already in the CMD comment
  (no `ANTHROPIC_BASE_URL`).
- `policy.yaml` — Landlock filesystem policy; grants `/home/sandbox` so Claude
  can persist `~/.claude` OAuth token. Egress (3-host allowlist) is in
  `network_policies` at `sandbox create` time, not here.
- `scripts/verify-pins.sh` — reference for the fail-closed, host-side,
  explicit-`ERROR:` verification discipline the audit harness should mirror.

### External resources (verify live during research)
- `https://github.com/pheckenlWork/claude-engineering-toolkit` — the cloned fork;
  inspect its plugin manifest / agent + skill registration (D-08) to enumerate
  the audit list and understand each plugin's network dependencies.
- `openshell sandbox exec --help`, `openshell logs --help` — confirm exec/log
  flags for the `claude` verb and the telemetry-attempt inspection (D-11).
- `claude --help` (in-image) — confirm `claude -p` headless invocation and
  `--plugin-dir` plugin-loading report for criterion #1 ("reports toolkit
  agents/skills as loaded").
</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `rebuild.sh` — the single integration point. Logging helpers, the verb
  dispatch (`rebuild|status|connect|login|down|audit`), and the `openshell
  sandbox exec --name $SANDBOX --tty --workdir /claudeshared -- /bin/bash`
  pattern used by `connect`/`login` are all in place. The new `claude` verb is a
  near-copy of `connect` with `claude …` as the exec command instead of
  `/bin/bash`. The new `audit-plugins` verb adds a `--no-tty` headless exec loop.
- `scripts/verify-pins.sh` pattern — fail-closed host-side verification with
  clear `ERROR:` output; the audit harness mirrors this discipline.

### Established Patterns
- Verb-first `rebuild.sh` interface — new operator capabilities are verbs, not
  flags or separate scripts (D-01, D-05).
- Fail-closed gates with `=== [ts] Step N ===` banners (Phases 1–3) — the audit
  hard-fail (D-10) and telemetry check (D-11) adopt this.
- "Audit surfaces, operator decides" was the prior posture for the log-surfacing
  `audit` verb; **Phase 4's `audit-plugins` is stricter (D-10 hard-fails)** —
  the two `audit*` verbs are intentionally different in posture.

### Integration Points
- The `claude` and `audit-plugins` verbs both require a **running, OAuth'd**
  sandbox — they run after `./rebuild.sh` (create) and `./rebuild.sh login`.
- The audit `claude -p` calls round-trip to `api.anthropic.com` (allowed by the
  Architecture B policy from Phase 3) — D-07's bound must not treat that latency
  as a hang.
- Telemetry inspection (D-11) reads `openshell logs` for the running sandbox —
  same log source the existing `audit` verb surfaces.
</code_context>

<specifics>
## Specific Ideas

- Strong preference for **provable, reproducible** verification over manual
  observation: a scripted headless harness (D-04) with a committed report (D-06)
  that **hard-fails** (D-10), consistent with the Phase 1–3 fail-closed posture.
- The audit must be judged against **Architecture B reality**, not the stale
  zero-egress/gateway docs — hence reconciling the docs in-phase (D-13) so a
  blocked MCP call is correctly read as "expected clean failure under the 3-host
  allowlist," not a regression.
- Distinguishing *blocked-host hang* from *legitimate model latency* (D-07) is
  the single most important correctness detail of the harness — flagged
  explicitly for the researcher.
</specifics>

<deferred>
## Deferred Ideas

- **`policy prove` formal network-policy verification (VER-01)** and **Makefile
  wrapper (ERG-01)** — v2 (carried forward from Phases 1–3).
- Any change to the egress policy or auth model — locked by Phase 3 /
  Architecture B; out of scope here.

None raised during discussion that fall outside the v1 requirement set (the doc
reconciliation D-13 is doc-truth correction for shipped reality, not new scope).
</deferred>

---

*Phase: 4-Claude Code Launch and MCP Audit*
*Context gathered: 2026-06-19*
