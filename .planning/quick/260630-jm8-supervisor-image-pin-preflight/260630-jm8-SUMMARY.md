---
phase: quick-260630-jm8
plan: 01
type: execute
status: complete
requirements: [RUN-06]
date: 2026-06-30
---

# Quick Task 260630-jm8 — Summary

## Objective

Add a fail-closed, RUN-05-style preflight that asserts the OpenShell gateway pins
its supervisor image to a non-floating tag before `openshell sandbox create`,
closing the supply-chain gap that let `ghcr.io/nvidia/openshell/supervisor:latest`
drift past the pinned gateway.

## Root cause (the live failure this defends against)

`./rebuild.sh` failed with `"sandbox is not ready"` / `ssh exited with status 255`.
The sandbox container was created but its supervisor (the OpenShell PID 1, mounted
at runtime from a container image) crashed during network-namespace setup:

```
WARN  ...netns: Failed to delete network namespace
Error:  × Invalid argument (os error 22)
```

The gateway log showed `Ensuring supervisor image image=ghcr.io/nvidia/openshell/supervisor:latest policy="newer"`. Upstream published a new `:latest` (~3h before the
run, built 2026-06-30 15:01 UTC) newer than the host's pinned gateway (`openshell
0.0.62`); the `newer` pull policy re-pulled it, and the version skew broke netns
setup. Reproduced identically on the stock `base` image (so it was not the repo's
image/policy); plain `ip netns add` worked with the supervisor's caps (so not the
kernel). The matching `supervisor:0.0.62` image was still present locally.

Host fix applied (then verified — a `base` sandbox reached Ready): pin in
`~/.config/openshell/gateway.toml`:
```toml
[openshell.drivers.podman]
supervisor_image = "ghcr.io/nvidia/openshell/supervisor:0.0.62"
```

## Operator decision (locked)

- **Verify + fail closed only** (mirrors RUN-05). Read-only; never writes host
  config, never restarts the gateway.
- **Version-agnostic.** Any tag other than `latest` passes — the version is NOT
  hardcoded, so the check survives `brew upgrade openshell` + re-pin.

## What changed

| Task | File(s) |
|------|---------|
| 1. New preflight script | `scripts/preflight-supervisor-pin.sh` |
| 2. Wire into rebuild path | `rebuild.sh` (Step 3.6, after RUN-05 Step 3.5, before Step 4 Create) + header step-list comment (4.6) |
| 3. Doc sync | `README.md`, `CLAUDE.md`, `AGENTS.md` |

### Task 1 — `scripts/preflight-supervisor-pin.sh`
- Section-aware **awk** TOML parse (no python/eval): tracks `[section]` headers,
  strips `#` comments, captures the (quote-stripped, last-wins) `supervisor_image`
  value **only** within `[openshell.drivers.podman]`.
- Tag extraction splits on the **last** `:` and detects a registry `host:port`
  prefix (segment after `:` containing `/` ⇒ no tag ⇒ podman implies `:latest`).
- Fail-closed: absent file, awk failure, table absent, key absent, empty value,
  untagged ref, and `:latest` all `exit 1` with a shared remediation block
  (find gateway version → pin → restart → re-run) on stderr.
- PASS (exit 0) for any non-`latest` tag; logs the resolved pin.
- XDG-aware path; optional positional arg overrides for the guard gauntlet.

### Task 2 — `rebuild.sh`
- New `log_step 3.6 "RUN-06 — Preflight: supervisor image pinned"` invokes the
  delegated script immediately after RUN-05 (3.5) and before Create (Step 4);
  `set -e` aborts before a drifted `:latest` supervisor is pulled. Dispatcher
  stays thin (D-05). Header step-list comment updated and anchored to RUN-06 (4.6).

### Task 3 — docs
- `README.md`: first-time host-setup block now includes the `supervisor_image`
  pin (with the drift rationale + re-pin-after-upgrade note); new rebuild step 6
  (RUN-06), Create→7, NET-04→8, NET-05→9.
- `CLAUDE.md`: new Version Compatibility row — supervisor image MUST be pinned to
  the gateway version; default `:latest` drifts; anchored to RUN-06 preflight.
- `AGENTS.md`: added `scripts/preflight-supervisor-pin.sh` to the repo-structure tree.

## Verification
- `bash -n` clean on the new script and `rebuild.sh`.
- Guard gauntlet (11 cases, temp configs in `mktemp -d`, cleaned via `trap`):
  pinned-version → 0; explicit-`:latest` → 1; no-tag → 1; registry `host:port`
  + pinned tag → 0; `host:port` no-tag → 1; key under wrong table → 1;
  commented-out → 1; empty value → 1; key absent → 1; file absent → 1;
  last-wins (`:latest` then pinned) → 0. All pass.
- Wiring order check: RUN-05 (3.5) → RUN-06 (3.6) → Create (4).
- Confirmed PASS against the live host `~/.config/openshell/gateway.toml`
  (now pinned to `:0.0.62`).

## Notes / deviations
- Executed inline by the orchestrator (same plan, same atomic commits, same
  verifies — no scope change), matching the RUN-05 (260622-omo) precedent.
- No committed `tests/` file — matches the RUN-05 precedent; verified inline.
- The host config fix was applied + verified before this task (a `base` sandbox
  reached Ready with `supervisor:0.0.62`); this task makes the precondition
  explicit and enforced for future rebuilds and fresh hosts.
