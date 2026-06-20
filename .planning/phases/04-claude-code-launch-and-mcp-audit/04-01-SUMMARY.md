---
phase: 04-claude-code-launch-and-mcp-audit
plan: "01"
subsystem: sandbox-policy-and-image
tags:
  - landlock
  - filesystem-policy
  - govulncheck
  - blocker-fix
  - sandbox-rebuild
dependency_graph:
  requires:
    - 03-02-SUMMARY.md
  provides:
    - /opt read-only Landlock grant (Blocker 1 fix)
    - govulncheck on PATH for sandbox user (Blocker 2 fix)
    - toolkit plugins loaded (Agents 11 / Skills 6)
    - sandbox Ready + OAuth'd
  affects:
    - policy.yaml (filesystem_policy.read_only gains /opt)
    - Dockerfile (govulncheck cp to /usr/local/bin, CMD repointed)
tech_stack:
  added: []
  patterns:
    - landlock-read-only-opt (grant /opt read to sandbox user without write surface)
    - govulncheck-cp-to-world-readable-bin (copy from GOPATH to /usr/local/bin at build time)
    - bash-entrypoint-cmd (CMD repointed to /bin/bash; OpenShell supervisor is PID 1)
key_files:
  created: []
  modified:
    - policy.yaml
    - Dockerfile
decisions:
  - "Add /opt to filesystem_policy.read_only only (never read_write) — T-04-02 mitigated; toolkit is operator-maintained fork, no untrusted runtime writes to /opt"
  - "Copy govulncheck from /root/go/bin to /usr/local/bin at Dockerfile build time so the sandbox user (Landlock default-deny) can reach it without expanding GOPATH grants"
  - "CMD repointed from the claude invocation to [/bin/bash] (D-03): OpenShell supervisor is PID 1 and never executes the image CMD; canonical launch is ./rebuild.sh claude (04-02)"
  - "No ENV ANTHROPIC_BASE_URL added — Architecture B has no inference.local gateway; Claude Code uses its built-in default (api.anthropic.com)"
metrics:
  duration: "~30 minutes (includes host-side rebuild + sandbox recreate + login)"
  completed_date: "2026-06-19"
  tasks_completed: 2
  files_modified: 2
---

# Phase 04 Plan 01: Blocker Fixes — /opt Landlock Grant + govulncheck PATH + CMD Repoint Summary

Fixed two RESEARCH.md blockers that gated all Phase 4 audit work: granted /opt to Landlock read_only so the toolkit plugins load (Agents 11/Skills 6), and copied govulncheck to /usr/local/bin so the sandbox user can invoke it; also repointed the vestigial Dockerfile CMD to /bin/bash (D-03).

## What Was Built

Two files modified (Task 1, auto) and verified live after operator rebuild + sandbox recreate + re-login (Task 2, checkpoint:human-verify, APPROVED):

### policy.yaml — /opt added to filesystem_policy.read_only (Blocker 1)

Added `- /opt` after the `- /var/log` entry in the `filesystem_policy.read_only` block. Inline comment notes that the toolkit is cloned to `/opt/claude-engineering-toolkit` (IMG-05) and Landlock must grant read for the sandbox user. The entry is read-only only — `/opt` is NOT added to `read_write` (T-04-02 mitigation: Landlock blocks runtime writes to the operator-controlled fork).

### Dockerfile — govulncheck copy + CMD repoint (Blocker 2 + D-03)

1. **Blocker 2**: The govulncheck `go install` RUN line was extended with `&& cp /root/go/bin/govulncheck /usr/local/bin/govulncheck` so the binary lands in a path the sandbox user can reach (Landlock-readable, world-executable). The `@${GOVULNCHECK_VERSION}` pin is unchanged (PIN-03 preserved).

2. **D-03**: The final `CMD` was repointed from `["claude", "--dangerously-skip-permissions", "--plugin-dir", "/opt/claude-engineering-toolkit"]` to `["/bin/bash"]`. The comment was updated to state this is for direct `podman run` only and that `./rebuild.sh claude` (04-02) is the canonical launch path. OpenShell's supervisor is PID 1 and never executes the image CMD; the old CMD was vestigial and misleading.

## Live Verification Evidence (Task 2 — operator-confirmed)

All four verification steps passed after `./rebuild.sh` completed:

| Check | Command | Result |
|-------|---------|--------|
| NET-04 | rebuild.sh internal gate | PASS |
| NET-05 | rebuild.sh internal gate | PASS |
| Sandbox ready | rebuild.sh | Ready |
| Blocker 1 — plugins loaded | `openshell sandbox exec ... claude --plugin-dir /opt/claude-engineering-toolkit plugin details claude-engineering-toolkit` | Agents (11) / Skills (6) — NOT 0/0 |
| Blocker 2 — govulncheck on PATH | `openshell sandbox exec ... bash -c 'govulncheck --version'` | `Scanner: govulncheck@v1.3.0` |
| OAuth | `./rebuild.sh login` | Succeeded |

Criterion #1 precondition is now satisfied. The sandbox is Ready and OAuth'd for 04-02 (`claude` verb) and 04-03 (`audit-plugins` verb).

## Acceptance Criteria Status

| Criterion | Status |
|-----------|--------|
| policy.yaml `read_only` includes `/opt` | PASS |
| policy.yaml `read_write` does NOT include `/opt` | PASS |
| Dockerfile govulncheck RUN copies binary to `/usr/local/bin/govulncheck` | PASS |
| `@${GOVULNCHECK_VERSION}` pin unchanged | PASS |
| Dockerfile final CMD is `["/bin/bash"]` | PASS |
| No `ENV ANTHROPIC_BASE_URL` present | PASS |
| `claude plugin details` reports Agents(11)/Skills(6) | PASS (live) |
| `govulncheck --version` prints version in sandbox | PASS (live — v1.3.0) |
| `./rebuild.sh login` succeeds | PASS (live) |
| NET-04 PASS | PASS (live) |
| NET-05 PASS | PASS (live) |

## Deviations from Plan

None — plan executed exactly as written. Both blockers fixed in source in Task 1 and proven live after rebuild in Task 2.

## Threat Surface Scan

No new network endpoints, auth paths, or schema changes introduced. Changes are:
- Adding a filesystem path to a read-only Landlock grant (T-04-01 accepted, T-04-02 mitigated — covered in PLAN.md threat register)
- Copying a public Go binary to a world-readable location at build time (T-04-03 accepted — govulncheck is public; no secrets embedded)

All new surface is covered by the PLAN.md threat register (T-04-01 through T-04-SC). No new surface beyond what the plan modeled.

## Known Stubs

None. Both fixes are fully wired and verified live.

## Self-Check: PASSED

- Task 1 commit 23c760b exists: confirmed (git log)
- Task 2: operator-approved human-verify checkpoint with live evidence
- `policy.yaml` contains `- /opt` under `filesystem_policy.read_only`: confirmed (Task 1 verification grep passed)
- `Dockerfile` contains `cp /root/go/bin/govulncheck /usr/local/bin/govulncheck`: confirmed
- `Dockerfile` final CMD is `["/bin/bash"]`: confirmed
- Live: Agents(11)/Skills(6), govulncheck@v1.3.0, NET-04/05 PASS, login OK
