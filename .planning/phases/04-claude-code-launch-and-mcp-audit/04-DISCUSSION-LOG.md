# Phase 4: Claude Code Launch and MCP Audit - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-19
**Phase:** 04-claude-code-launch-and-mcp-audit
**Areas discussed:** Launch entry point, Audit harness form, Plugin list + expected outcomes, Telemetry-suppression proof, Documentation reconciliation

---

## Launch entry point

### How is the audited autonomous Claude session launched?
| Option | Description | Selected |
|--------|-------------|----------|
| New `./rebuild.sh claude` verb | Execs into sandbox (cwd /claudeshared), runs claude with both flags; mirrors login/connect | ✓ |
| Keep Dockerfile CMD only | Leave CMD as-is; not the path operators actually use | |
| Operator types it manually | Document full command in README; no new verb | |

### OAuth-token precondition handling
| Option | Description | Selected |
|--------|-------------|----------|
| Check + guide, don't block | Detect credentials, warn if missing, still launch | |
| Hard-fail if no token | Exit non-zero if no credentials | |
| Just launch, no check | Exec claude directly; let claude handle unauth case | ✓ |

### Dockerfile CMD fate
| Option | Description | Selected |
|--------|-------------|----------|
| Keep as-is (documents intent) | Living documentation of intended flags | |
| Repoint to bash/sleep | Harmless long-running process | |
| Let research decide | Confirm whether OpenShell honors/overrides CMD, then choose | ✓ |

**Notes:** Verb reuses the `connect`/`login` exec pattern (`--tty --workdir /claudeshared`). CMD becomes vestigial; OpenShell supervisor likely overrides it — research confirms.

---

## Audit harness form

### Form of the audit
| Option | Description | Selected |
|--------|-------------|----------|
| Scripted headless harness | `claude -p` per plugin with timeout + recorded artifact | ✓ |
| Operator README checklist | Manual, not reproducible | |
| Hybrid: script + manual spot-check | Script local plugins, manual for interactive ones | |

### Location / invocation
| Option | Description | Selected |
|--------|-------------|----------|
| `./rebuild.sh audit-plugins` verb | New verb (distinct from log-surfacing `audit`) | ✓ |
| Standalone scripts/audit-plugins.sh | Separate script under scripts/ | |
| Verb that calls the script | Both — wrapper + script | |

### Report artifact location
| Option | Description | Selected |
|--------|-------------|----------|
| Phase dir, committed | Durable evidence committed to repo | ✓ |
| /claudeshared, not committed | Transient run artifact on host | |
| Stdout + summary table only | No persisted file | |

### 10s no-hang bound interpretation
| Option | Description | Selected |
|--------|-------------|----------|
| Generous total cap, separate hang signal | Distinguish blocked-host hang from model latency | |
| Hard 10s timeout on everything | Literal but false-fails legit model latency | |
| Let research design it | Lock intent; researcher picks mechanism after probing | ✓ |

**Notes:** Key correctness subtlety — `claude -p` itself round-trips to api.anthropic.com (allowed, may exceed 10s); the criterion targets *blocked-host* hangs, not total runtime.

---

## Plugin list + expected outcomes

### Defining the plugin list
| Option | Description | Selected |
|--------|-------------|----------|
| Enumerate from the toolkit manifest | Derive programmatically so audit can't drift | ✓ |
| Hand-curated fixed list | Explicit names; goes stale | |
| Review agents only | Just the 11 review agents; misses network plugins | |

### Pre-classify expected outcomes?
| Option | Description | Selected |
|--------|-------------|----------|
| Yes — expected-outcome table | Local→succeed, network/MCP→clean-fail; gate on match | ✓ |
| No — uniform clean-behavior check | Just assert terminal state within bounds | |
| Let research classify | Researcher proposes table from evidence | |

### Action on expected/actual mismatch
| Option | Description | Selected |
|--------|-------------|----------|
| Record finding, don't block | Observe + document; non-fatal | |
| Hard-fail on any mismatch | Exit non-zero on any deviation | ✓ |
| Block only on hangs | Hangs fatal; other mismatches recorded | |

**Notes:** Table encodes *intended* correct behavior; research seeds it by probing actual behavior, and observed-vs-intended divergences are fixed/justified before the table is locked, not baked in as "expected."

---

## Telemetry-suppression proof

### Evidence method
| Option | Description | Selected |
|--------|-------------|----------|
| Both: egress logs + startup output | Inspect openshell logs for statsig/sentry/downloads attempts AND grep startup | ✓ |
| Egress logs only | Network truth, misses in-process errors | |
| Startup output only | Matches wording, trusts claude's own logging | |

### Placement
| Option | Description | Selected |
|--------|-------------|----------|
| Part of audit-plugins | Folded into the same run (already launches claude) | ✓ |
| Separate check/gate | Own step, since it's about the env var | |

---

## Documentation reconciliation

### Handling stale ROADMAP/REQUIREMENTS/PROJECT docs (still gateway/zero-egress)
| Option | Description | Selected |
|--------|-------------|----------|
| Reconcile as part of Phase 4 | Update stale docs to Architecture B; in-scope, planner allocates a task | ✓ |
| Note for auditor only, defer doc edits | CONTEXT note only; cleanup separately | |
| Separate quick task now | /gsd-quick before planning | |

**Notes:** Framed as doc-truth correction for shipped reality, not new capability — keeps the phase's own success criteria (esp. criterion #3 "zero-egress sandbox") judged against Architecture B.

---

## Claude's Discretion

- Dockerfile CMD keep-vs-repoint (pending OpenShell CMD-honoring behavior).
- 10s-bound mechanism — blocked-host-hang vs model-latency discrimination.
- Toolkit manifest discovery format; exact per-plugin `claude -p` invocation.
- Exact telemetry-attempt signature to grep for in `openshell logs`.

## Deferred Ideas

- `policy prove` formal verification (VER-01) and Makefile wrapper (ERG-01) — v2.
- Any change to the egress policy or auth model — locked by Phase 3 / Architecture B.
