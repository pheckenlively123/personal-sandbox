# Phase 4: Claude Code Launch and MCP Audit — Pattern Map

**Generated:** 2026-06-19
**Purpose:** Map each file this phase creates/modifies to its closest existing analog so the planner and executor replicate established conventions instead of inventing new ones.

---

## Files to create / modify

| File | Role | Change | Closest analog |
|------|------|--------|----------------|
| `rebuild.sh` (`claude` verb) | Operator launch entry | New verb | `connect` verb (lines ~337–344) |
| `rebuild.sh` (`audit-plugins` verb) | Operator audit entry | New verb | `audit` verb (lines ~390–396) |
| `scripts/audit-plugins.sh` | Headless audit harness | New script | `scripts/verify-pins.sh` |
| `policy.yaml` | Landlock FS policy | Add `/opt` to `read_only` | existing `read_only` entries (lines ~31, 37–40) |
| `Dockerfile` | Image build | govulncheck copy + CMD repoint | line 48 (go install), line 116 (CMD) |
| `.planning/phases/04-…/PLUGIN-AUDIT.md` | Committed audit report | New artifact | none — structure from 04-RESEARCH.md |
| `ROADMAP.md` / `REQUIREMENTS.md` / `PROJECT.md` | Planning docs | Architecture B reconciliation (D-13) | copy wording from `CLAUDE.md` |

---

## Pattern details

### 1. New verbs — `claude` and `audit-plugins`

The `claude` verb is a near-copy of the existing `connect`/`login` verbs. All interactive verbs use:

```
openshell sandbox exec --name $SANDBOX --tty --workdir $SHARED_DIR -- <cmd>
```

- `connect` runs `/bin/bash`; the new `claude` verb runs `claude --dangerously-skip-permissions --plugin-dir /opt/claude-engineering-toolkit` instead (D-01).
- `audit-plugins` follows the existing `audit` verb's thin-wrapper shape: the verb delegates to `scripts/audit-plugins.sh` (D-05).
- The verb dispatch `case` block (~line 239) MUST be extended to recognize `claude` and `audit-plugins`, and the usage/help text updated.

### 2. Headless exec pattern

Interactive verbs use `--tty`. Headless audit calls use:

```
openshell sandbox exec --name $SANDBOX --no-tty --timeout 120 -- claude -p "<prompt>"
```

Per RESEARCH.md D-07: the OpenShell proxy returns HTTP 403 in ~38ms for denied hosts (no unbounded hang). A generous `--timeout 120` covers legitimate `api.anthropic.com` model latency; **exit code 124 = hang = always FAIL** regardless of plugin type.

### 3. Fail-closed harness discipline (`scripts/audit-plugins.sh`)

Copy the `verify-pins.sh` pattern:
- `set -euo pipefail` header
- `VIOLATIONS` (or `FINDINGS`) counter incremented per failure
- Logging helpers `ts`, `log_step`, `log_info`, `log_error` are **copy-pasted into the script, not imported** (existing convention — scripts are self-contained)
- `=== [ts] Step N ===` banners for each phase of the run
- Explicit `FAIL:`/`ERROR:` on any uncertainty; exit non-zero on any violation (D-10 hard-fail)
- Per-plugin expected-outcome table drives PASS/FAIL: MUST_SUCCEED plugins that fail, or MUST_FAIL_CLEAN plugins that hang/succeed wrongly, are violations.

### 4. policy.yaml — `/opt` Landlock fix (Blocker 1)

Add `/opt` to the `read_only` list following the existing comment style of the surrounding entries. Without it, toolkit agents/skills at `/opt/claude-engineering-toolkit` load as 0 (criterion #1 fails).

### 5. Dockerfile fixes (Blocker 2 + D-03)

- Line ~48 (govulncheck `go install`): append `&& cp /root/go/bin/govulncheck /usr/local/bin/govulncheck` so the `sandbox` user can reach it.
- Line ~116 CMD: repoint to `/bin/bash` (supervisor is PID 1 and never executes the image CMD; repoint is documentation-clarity per D-03).

### 6. PLUGIN-AUDIT.md report

No existing analog. Structure derives from RESEARCH.md: per-plugin rows (plugin name, type MUST_SUCCEED/MUST_FAIL_CLEAN, observed outcome, wall-clock, verdict) plus the telemetry-suppression evidence section (D-11/D-12).

### 7. Doc reconciliation (D-13)

ROADMAP/REQUIREMENTS/PROJECT.md are stale (gateway/zero-egress). Copy the authoritative Architecture B wording from `CLAUDE.md` (Network Policy, Core Value, Key Decisions sections). Doc-truth correction only — no behavior change.

---

*Pattern map for Phase 4. Analog line numbers are approximate — executor reads the live file first.*
