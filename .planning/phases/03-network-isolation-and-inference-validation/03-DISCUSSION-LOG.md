# Phase 3: Network Isolation and Inference Validation - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-16
**Phase:** 03-network-isolation-and-inference-validation
**Areas discussed:** Validation depth, Egress policy home, No-Anthropic assertion, Provider lifecycle

---

## Validation depth (NET-05, criteria #1/#2)

| Option | Description | Selected |
|--------|-------------|----------|
| Smoke blocks, round-trip auto | Egress smoke test BLOCKS on failure; one automated `claude -p`/curl round-trip through inference.local as a non-fatal sanity check; full multi-turn interactive session stays an operator/README step | ✓ |
| Smoke blocks, round-trip manual | Only the egress smoke test is automated (block-on-fail); entire model round-trip left to operator | |
| Run both, warn-only | Run smoke test + round-trip but never block; just report and hand off | |

**User's choice:** Smoke blocks, round-trip auto (recommended)
**Notes:** Interactive multi-turn validation can't be faithfully scripted, so the automated single round-trip is the machine-checkable proxy; the smoke test is the hard gate before handoff.

---

## Egress policy home (NET-01)

| Option | Description | Selected |
|--------|-------------|----------|
| Separate network_policies at create | policy.yaml stays filesystem-only; deny-all egress via OpenShell `network_policies` at sandbox create (per CLAUDE.md) | ✓ |
| Add deny-all section to policy.yaml | Extend the `--policy` file with a network/egress section — single source of truth | |
| You decide | Lock requirement, let research confirm mechanism | |

**User's choice:** Separate network_policies at create (recommended)
**Notes:** Matches CLAUDE.md ("empty network_policies from the start") and the explicit policy.yaml comment deferring egress to Phase 3. Keeps network vs filesystem isolation separated. Exact syntax/delivery flag left to research.

---

## No-Anthropic assertion (NET-04)

| Option | Description | Selected |
|--------|-------------|----------|
| Live policy query post-create | `openshell policy get <sandbox>` after create; assert no api.anthropic.com — reflects what's actually enforced | ✓ |
| Static grep pre-create | Grep source policy/config for api.anthropic.com before create — simpler, earlier, but misses built-in defaults | |
| Both (static pre-check + live gate) | Fast static grep guard + authoritative live query gate | |

**User's choice:** Live policy query post-create (recommended)
**Notes:** Truthfulness over simplicity — assert against the running sandbox's actual enforced policy, including any OpenShell defaults. Fail-closed.

---

## Provider lifecycle (NET-03, criterion #3)

| Option | Description | Selected |
|--------|-------------|----------|
| Preflight-assert only | `openshell inference get` before create, error if unregistered; one-time `provider create --from-existing` is a documented operator action | ✓ |
| Assert + auto-refresh | Assert existence, run `openshell provider refresh` if present, never create | |
| Idempotent create/refresh | Ensure provider exists, creating/refreshing from host state every run | |

**User's choice:** Preflight-assert only (recommended)
**Notes:** Matches criterion #3 (preflight prevents the ~290s hang) and the project's security posture — credential provisioning stays an explicit human step, never baked into the rebuild path or image.

---

## Claude's Discretion

Deferred to research (requirement locked, mechanism open):
- Smoke-test target endpoint(s) and exec-into-sandbox mechanism; pass/fail condition with a bounded timeout.
- Round-trip method for the non-fatal check (`claude -p` vs raw curl to inference.local).
- Exact `network_policies` syntax and its delivery flag on `sandbox create`.
- Exact provider-existence check command and registered-vs-missing exit signal.

## Deferred Ideas

- Multi-turn interactive session automation — stays an operator README step (criterion #2 is inherently hands-on).
- Claude launch + MCP/plugin network audit (RUN-01, RUN-02) — Phase 4.
- `policy prove` formal verification (VER-01) and Makefile wrapper (ERG-01) — v2.
