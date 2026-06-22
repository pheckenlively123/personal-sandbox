---
phase: quick-260622-omo
plan: 01
type: execute
status: complete
requirements: [RUN-05]
date: 2026-06-22
---

# Quick Task 260622-omo — Summary

## Objective

Make the OpenShell gateway bind-mount precondition part of the sandbox setup so
the repo works on a fresh host (e.g. Fedora) instead of failing mid-build with a
cryptic podman error (`podman bind mounts require enable_bind_mounts = true in
[openshell.drivers.podman]`). The repo previously assumed this host config was
"already set on this host."

## Operator decision (locked)

**Verify + fail closed only.** The preflight READS `~/.config/openshell/gateway.toml`
and exits 1 with remediation if `enable_bind_mounts = true` is not set under
`[openshell.drivers.podman]`. It never writes/creates/modifies host config and
never restarts the gateway. (Auto-create and auto-restart were both rejected.)

## What changed

| Task | File(s) | Commit |
|------|---------|--------|
| 1. New preflight script | `scripts/preflight-gateway-bind-mount.sh` | `712a008` |
| 2. Wire into rebuild path | `rebuild.sh` (Step 3.5, before Step 4 Create sandbox) | `5cbb1de` |
| 3. Doc sync | `README.md`, `CLAUDE.md`, `AGENTS.md` | `f9b834f` |

### Task 1 — `scripts/preflight-gateway-bind-mount.sh`
- Section-aware **awk** TOML parse (no python dependency): tracks `[section]`
  headers, strips `#` comments, and matches `enable_bind_mounts = true` **only**
  within `[openshell.drivers.podman]`. A naive `grep` would false-match a
  commented line or the key under another table.
- Fail-closed: absent file, absent table, key-not-true, and awk failure all
  `exit 1` with a consistent remediation block (what to add + Linux/macOS restart
  commands) to stderr. Distinct diagnostics for table-absent vs key-not-set.
- Path resolution honors `$XDG_CONFIG_HOME`/`$HOME` (works on Linux and macOS);
  optional positional arg overrides the path for testing.
- Read-only by construction — contains no write/restart of the config.

### Task 2 — `rebuild.sh`
- New `log_step 3.5 "RUN-05 — Preflight: gateway bind-mount enabled"` invokes the
  delegated script after image teardown (Step 3) and before `log_step 4 "Create
  sandbox"`. `set -e` propagation aborts the rebuild before `openshell sandbox
  create` can fail cryptically inside podman.
- Dispatcher stays thin (D-05): parse logic lives in the script. Header step-list
  comment updated and anchored to RUN-05.

### Task 3 — docs
- `README.md`: new "First-time host setup (required)" note + a new rebuild step 5
  (renumbered Create→6, NET-04→7, NET-05→8) describing the read-only fail-closed
  preflight and the restart commands.
- `CLAUDE.md`: replaced the stale "`enable_bind_mounts = true` already set" claim
  with a REQUIRED host precondition note anchored to RUN-05.
- `AGENTS.md`: added the new script to the repo-structure tree.

## Verification

- `bash -n` clean on both `scripts/preflight-gateway-bind-mount.sh` and `rebuild.sh`.
- Guard gauntlet (`ALL_GUARDS_OK`): good config → exit 0; commented-out key,
  key under wrong table, and absent file → exit 1 with remediation.
- Wiring check (`WIRED_BEFORE_STEP4`): preflight invoked before the Create-sandbox
  step.
- Docs check (`DOCS_SYNCED`): README documents the preflight, AGENTS lists the
  script, CLAUDE references RUN-05 and no longer says "already set".
- Confirmed PASS against the live host `~/.config/openshell/gateway.toml`.

## Notes / deviations

- Executed inline by the orchestrator after the worktree-isolated executor parked
  on a Write-permission prompt it could not clear. Same plan, same atomic commits,
  same verifies — no scope change.
- The runtime `log_step` numbering in `rebuild.sh` (Create = Step 4) differs from
  the prose header-comment numbering; the preflight is wired as Step 3.5 to sit
  between the actual teardown (3) and create (4) runtime steps.
