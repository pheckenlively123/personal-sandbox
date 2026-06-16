# Phase 2: Rebuild Script and Sandbox Lifecycle - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-14
**Phase:** 02-rebuild-script-and-sandbox-lifecycle
**Areas discussed:** Teardown scope & idempotency, Image tag & cooldown label, rebuild.sh ↔ build-and-lock seam, Egress-audit surfacing

---

## Teardown scope & idempotency (BLD-02)

### Q1 — What to tear down on rerun

| Option | Description | Selected |
|--------|-------------|----------|
| Sandbox + old image | Delete sandbox AND remove old image + prune dangling. Known-empty start; full rebuild each run. | ✓ |
| Sandbox only | Delete just the sandbox; keep podman layer cache. Faster reruns; old images accumulate. | |
| You decide | sandbox-only default + `--prune` flag. | |

**User's choice:** Sandbox + old image
**Notes:** Preference for "every run starts from a known-empty state"; full rebuild cost accepted.

### Q2 — Behavior on awkward state (Running / first-run absent)

| Option | Description | Selected |
|--------|-------------|----------|
| Force + tolerate-absent | Stop-then-remove with force if present; treat not-found as success. Makes run #1 and #2 both pass. | ✓ |
| Stop only if running, else skip | Check state first; more branching. | |
| You decide | Recommend force + tolerate-absent. | |

**User's choice:** Force + tolerate-absent
**Notes:** Directly targets success criterion #1 (idempotent rerun).

---

## Image tag & cooldown label (BLD-03)

### Q1 — Tag scheme

| Option | Description | Selected |
|--------|-------------|----------|
| Date tag + :latest | `claude-sandbox:<date>` + move `:latest`; hand date-pinned ref to openshell. | ✓ |
| Date tag only | Only `:<date>`; no floating latest. | |
| You decide | Recommend date + :latest. | |

**User's choice:** Date tag + :latest
**Notes:** Date-pinned ref to `openshell create`; `:latest` as stable handle. Accumulation moot due to full-clean teardown.

### Q2 — Label mechanism

| Option | Description | Selected |
|--------|-------------|----------|
| Dockerfile LABEL via ARG | Provenance travels with image; ARGs already plumbed. | (recommended) |
| podman build --label | Script injects labels; Dockerfile label-free. | |
| You decide | Recommend Dockerfile LABEL via ARG. | ✓ |

**User's choice:** You decide → Dockerfile LABEL via ARG (Claude's recommendation locked)
**Notes:** —

---

## rebuild.sh ↔ build-and-lock seam (BLD-01)

### Q1 — Reuse mechanism

| Option | Description | Selected |
|--------|-------------|----------|
| Call as subprocess | rebuild.sh invokes build-and-lock.sh; minimal change to Phase 1. | (recommended) |
| Refactor into sourced lib | Extract shared block to scripts/lib/*; both source it; finer logging. | |
| You decide | Recommend call-as-subprocess first pass. | ✓ |

**User's choice:** You decide → call-as-subprocess (Claude's recommendation locked)
**Notes:** Flagged BLD-04 tension — dnf/npm/go run inside `podman build` layers; rebuild.sh wraps timestamps around major phases it controls, layer granularity comes from build output. To be confirmed in research/planning.

---

## Egress-audit surfacing (BLD-05)

### Q1 — How to surface `openshell logs` audit

| Option | Description | Selected |
|--------|-------------|----------|
| End-of-run reminder + README | Print audit command at end + docs. | |
| README docs only | Docs only; script silent. | |
| Dedicated --audit flag | rebuild.sh `--audit` runs the egress log query directly. | ✓ |

**User's choice:** Dedicated --audit flag
**Notes:** Scoped to log surfacing only; egress *policy* assertion stays Phase 3.

---

## Claude's Discretion

- Cooldown-label mechanism → Dockerfile `LABEL` via ARG.
- Build seam → call `build-and-lock.sh` as subprocess.
- BLD-04 per-phase logging granularity → confirm in research/planning.
- UID-alignment mechanism (RUN-04) → researcher determines; the requirement
  (host-user-owned `canary.txt`) is fixed. User chose "I'm ready for context"
  rather than locking a UID mechanism.
- Sandbox name, exact `openshell sandbox` subcommand/flag names, basic preflight —
  left to research (live CLI verification).

## Deferred Ideas

- Preflight `openshell inference get` (anti-hang) — Phase 3.
- Egress *policy* assertion (no `api.anthropic.com`) — Phase 3.
- Makefile wrapper (ERG-01), `policy prove` (VER-01) — v2.
- `--prune`/fast cache-reuse teardown toggle — rejected in favor of always-full-clean.
