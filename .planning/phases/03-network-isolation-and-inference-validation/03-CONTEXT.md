# Phase 3: Network Isolation and Inference Validation - Context

**Gathered:** 2026-06-16
**Status:** Ready for planning

<domain>
## Phase Boundary

Take the working sandbox from Phase 2 and make its isolation provable. Phase 3
adds, on top of the existing `rebuild.sh` lifecycle:

1. **Zero direct egress** (NET-01) enforced by the OpenShell policy so the
   running sandbox cannot reach the open internet.
2. **Gateway-brokered inference** (NET-02/NET-03) — Claude Code reaches the
   model only through `inference.local`, with the real Claude subscription
   credential injected host-side by the OpenShell provider mechanism.
3. **Three new `rebuild.sh` gates**: an `openshell inference get` **preflight**
   before `sandbox create` (criterion #3 — prevents the ~290s provider hang); a
   **no-Anthropic egress-policy assertion** (NET-04); and an **egress smoke
   test** that confirms an outbound request from inside the sandbox fails before
   control is handed to the operator (NET-05).

**In scope (Phase 3):**
- Enforce deny-all egress at `openshell sandbox create` time via the OpenShell
  `network_policies` mechanism (NET-01).
- `openshell inference get` preflight in `rebuild.sh` before create, fail-closed
  with a clear error if the provider is unregistered (criterion #3).
- Post-create live policy assertion (`openshell policy get`) that no
  `api.anthropic.com` / direct-Anthropic egress entry exists (NET-04).
- Egress smoke test executed inside the running sandbox; **blocks** (exit
  non-zero) if the outbound request unexpectedly succeeds (NET-05, criterion #1).
- One automated model round-trip through `inference.local` as a **non-fatal**
  sanity check that the gateway broker works (partial criterion #2).
- README documentation of the one-time `provider create --from-existing` setup
  and the operator-run multi-turn interactive validation.

**Out of scope (later phases / already done):**
- `ANTHROPIC_BASE_URL` injection — **already baked into the Dockerfile ENV**
  (line 93: `ENV ANTHROPIC_BASE_URL=https://inference.local`). NET-02 mechanism
  is set; Phase 3 only validates it round-trips.
- Claude launch flags (`--dangerously-skip-permissions`, `--plugin-dir`) and the
  MCP/plugin network audit — **Phase 4** (RUN-01, RUN-02). Note the Dockerfile
  `CMD` already carries these flags; Phase 3 does not audit them.
- Egress-log *surfacing* via `--audit` — already shipped in Phase 2 (BLD-05,
  log-surfacing only). Phase 3's NET-04 is *policy* assertion, a distinct check.
</domain>

<decisions>
## Implementation Decisions

### Egress policy enforcement (NET-01)
- **D-01:** Zero-egress is enforced via the OpenShell **`network_policies`
  mechanism at `sandbox create` time** (per CLAUDE.md "zero-egress requires
  empty `network_policies` from the start"). The existing `policy.yaml` stays
  **filesystem-only** (Landlock `filesystem_policy` / `landlock` / `process`
  schema v1) — do NOT add a network section to it. Network and filesystem
  isolation remain cleanly separated concerns.
- **Research note:** The exact `network_policies` syntax and whether it is passed
  via `--policy`, `--driver-config-json`, or a dedicated flag must be confirmed
  live against `openshell sandbox create --help` and the policies.mdx docs.
  CLAUDE.md anti-pattern: never use `openshell policy update --add-endpoint
  api.anthropic.com` — that defeats zero-egress.

### No-Anthropic egress assertion (NET-04)
- **D-02:** rebuild.sh asserts the absence of `api.anthropic.com` (or any direct
  Anthropic endpoint) by **querying the live created sandbox** —
  `openshell policy get <sandbox>` after create — not by grepping the source
  policy file. The live query reflects what is actually enforced, including any
  OpenShell built-in defaults. Fail-closed: non-zero exit if a direct-Anthropic
  entry is found.

### Provider lifecycle / credential injection (NET-03, criterion #3)
- **D-03:** rebuild.sh runs `openshell inference get` (or equivalent provider-
  existence check) as a **preflight before `sandbox create`** and exits with a
  clear, actionable error if the provider is not registered — directly
  mitigating the OpenShell #759 ~290s hang. This slots into the preflight seam
  Phase 2 reserved before create.
- **D-04:** rebuild.sh is **preflight-assert-only** — it does NOT create or
  refresh the provider. The one-time `openshell provider create … --from-existing`
  (loading the existing `claude-code` subscription credential from host state)
  and `openshell provider refresh` are **explicit operator actions documented in
  README**. Credential provisioning stays a deliberate human step, never baked
  into the rebuild path or the image (NET-03: credentials never in the image).

### Validation depth (NET-05, criteria #1/#2)
- **D-05:** The **egress smoke test BLOCKS** — rebuild.sh executes an outbound
  request from inside the running sandbox and exits non-zero if it unexpectedly
  succeeds (criterion #1: `curl https://api.anthropic.com` must fail with proxy
  error / connection refused). This is the hard gate before handing control to
  the operator.
- **D-06:** rebuild.sh ALSO fires **one automated model round-trip through
  `inference.local`** (e.g. `claude -p`/`curl`) as a **non-fatal** sanity check
  that the gateway broker is alive. It reports pass/fail but does not block on
  it.
- **D-07:** The **full multi-turn interactive session** (criterion #2 — "live
  multi-turn interactive session, ≥2 round-trips") is an **operator step
  documented in README**, because an interactive session cannot be faithfully
  scripted. The automated D-06 round-trip is the machine-checkable proxy.

### Claude's Discretion (deferred to research — requirement fixed, mechanism open)
- **Smoke-test target & exec mechanism:** which endpoint(s) to probe (criterion
  #1 names `api.anthropic.com`; consider also a generic endpoint like
  `example.com` to prove deny-all, not just an Anthropic-specific block), how to
  execute a command inside the running sandbox (`openshell exec`?), and the
  fail/pass condition (connection-refused vs proxy-error vs timeout — with a
  bounded timeout so the test never hangs). Requirement (outbound fails) is
  locked; the how is research.
- **Round-trip method:** `claude -p "ping"` vs a raw `curl` to `inference.local`
  for D-06. Researcher picks the most reliable non-interactive proof.
- **`network_policies` exact syntax** and its delivery flag (D-01) — live CLI
  verification required.
- **Provider-existence check command** — exact `openshell inference get` vs
  `openshell provider get` invocation and the registered-vs-missing exit signal
  (D-03) — confirm live.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project specs & requirements
- `CLAUDE.md` — authoritative tech-stack spec. For Phase 3 specifically:
  "Gateway Inference Brokering (`inference.local`)" (header stripping, credential
  injection, model rewrite); "Zero-Egress Policy" + "policies.mdx — zero-egress
  via empty `network_policies`"; the `openshell provider create … --from-existing`
  / `openshell provider refresh` flow under §1; "What NOT to Use"
  (`ANTHROPIC_BASE_URL=https://inference.local/v1` double-path anti-pattern,
  `--from-existing` in Dockerfile anti-pattern, `policy update --add-endpoint
  api.anthropic.com` anti-pattern, `--allow-dangerously-skip-permissions`);
  Sources block confirming `openshell` v0.0.62. MUST read before planning.
- `.planning/REQUIREMENTS.md` §NET (NET-01..NET-05) — the 5 requirements this
  phase satisfies (verbatim wording, esp. NET-03's subscription-login detail).
- `.planning/ROADMAP.md` → "Phase 3" — goal + 4 success criteria (notably #1
  curl api.anthropic.com fails, #2 live multi-turn interactive ≥2 round-trips,
  #3 `openshell inference get` preflight prevents 290s hang, #4 policy contains
  no direct-Anthropic endpoint).
- `.planning/phases/02-rebuild-script-and-sandbox-lifecycle/02-CONTEXT.md` —
  Phase 2 decisions; esp. the deferred list (preflight + egress-policy assertion
  explicitly handed to Phase 3) and the code_context note that rebuild.sh was
  designed so "a preflight step slots in before `sandbox create`."

### Phase 1/2 artifacts to extend (in this repo)
- `rebuild.sh` — the top-level orchestrator to extend. Today: preflight (tools on
  PATH) → build-and-lock → tag :latest → teardown → `openshell sandbox create
  --policy policy.yaml --driver-config-json {bind mount}` → Ready check, plus an
  `--audit` log-surfacing subcommand. Phase 3 adds: provider preflight (before
  create), `network_policies` deny-all on create, post-create policy assertion,
  and the egress smoke test + non-fatal round-trip before the final "Ready"
  banner. Match its conventions: `set -euo pipefail`, stderr logging with
  `log_step`/`log_info`/`log_error`, `=== [ts] Step N ===` banners, fail-closed.
- `policy.yaml` — current Landlock filesystem policy (v1). Has an explicit
  comment: "Egress policy (zero-egress enforcement) is intentionally deferred to
  Phase 3. Do not add a network section here." D-01 keeps this file
  filesystem-only; egress lives in `network_policies` at create time.
- `Dockerfile` — line 93 already sets `ENV ANTHROPIC_BASE_URL=https://inference.local`
  (no trailing `/v1`); line 94 `CMD` already carries the Claude launch flags
  (Phase 4 territory). Phase 3 should NOT need to modify the Dockerfile.

### External resources (OpenShell CLI — verify live during research)
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/sandboxes/policies.mdx`
  — zero-egress via empty `network_policies`; create-time-only static sections.
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/sandboxes/inference-routing.mdx`
  — `inference.local`, `ANTHROPIC_BASE_URL`, provider brokering, Claude Code example.
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/sandboxes/manage-sandboxes.mdx`
  — `sandbox create` flags, `--driver-config-json`.
- `openshell sandbox create --help`, `openshell inference get --help`,
  `openshell provider create --help`, `openshell provider refresh --help`,
  `openshell policy get --help`, `openshell exec --help` (or equivalent) —
  verify exact subcommands/flags for D-01..D-06 against the live v0.0.62 binary.
- `~/.config/openshell/gateway.toml` — live gateway config (provider record,
  `compute_drivers = ["podman"]`).
</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `rebuild.sh` (219 lines) — the single integration point. Logging helpers
  (`ts`, `log_step`, `log_info`, `log_error`), the `--audit` subcommand, the
  tools-on-PATH preflight loop, and the `openshell sandbox create` invocation are
  all already in place and conventionally styled. New Phase 3 logic attaches to
  named seams: provider preflight goes in the existing preflight region (before
  Step 1 build, or just before Step 4 create); the smoke test + round-trip + live
  policy assertion go after the Ready check, before the final summary banner.
- Phase 1 verification scripts (`scripts/verify-pins.sh` pattern) demonstrate the
  fail-closed, host-side, explicit-error verification discipline to mirror for
  NET-04/NET-05 gates.

### Established Patterns
- Fail-closed host-side verification (Phase 1) — every Phase 3 gate (preflight,
  policy assertion, smoke test) should exit non-zero with a clear `ERROR:` on
  violation; the round-trip (D-06) is the deliberate exception (non-fatal).
- `=== [ts] Step N: … ===` timestamped banners (BLD-04 / D-06 from Phase 2) — new
  steps adopt the same numbered, timestamped banner format.
- "Tolerate-absent vs hard-error" teardown discipline (Phase 2 D-02) — applies
  inversely here: a *present* egress path or a *missing* provider must hard-error.

### Integration Points
- Provider preflight (D-03) must run **before** `openshell sandbox create` (the
  290s-hang mitigation only works pre-create).
- The `network_policies` deny-all (D-01) is supplied **at** `sandbox create`,
  composed alongside the existing `--policy policy.yaml` and bind-mount
  `--driver-config-json`.
- The smoke test (D-05) and round-trip (D-06) run **after** the sandbox reaches
  Ready (they need a running sandbox to exec into), and **before** the final
  "Ready — handing to operator" banner.
- Phase 4 will launch Claude with plugins inside this now-isolated sandbox; D-06's
  round-trip proves the inference path Phase 4 depends on.

</code_context>

<specifics>
## Specific Ideas

- Strong preference for **provable** isolation over assumed isolation: the live
  `openshell policy get` query (D-02) over a static file grep, and a smoke test
  that **blocks** (D-05) rather than merely warns — the operator should never be
  handed a sandbox whose egress block is unverified.
- Credential setup stays an **explicit human action** (D-04), not automated into
  rebuild.sh — matches the project's security posture (credentials never baked,
  injection is deliberate).
- The script automates everything that *can* be scripted (smoke test, single
  round-trip) but does not fake the inherently-interactive multi-turn validation
  (D-07) — it documents it for the operator instead.

</specifics>

<deferred>
## Deferred Ideas

- **Multi-turn interactive session automation** — criterion #2's "live multi-turn
  interactive session" remains an operator README step (D-07); not automated this
  phase.
- **Claude launch + MCP/plugin network audit** (RUN-01, RUN-02) — Phase 4. The
  Dockerfile `CMD` flags and `--plugin-dir` audit are explicitly out of scope here.
- **`policy prove` formal verification (VER-01)** and **Makefile wrapper
  (ERG-01)** — v2 (carried forward from Phases 1–2).

None raised during discussion that fall outside the v1 requirement set.

</deferred>

---

*Phase: 3-Network Isolation and Inference Validation*
*Context gathered: 2026-06-16*
