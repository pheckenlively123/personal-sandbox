---
phase: 04-claude-code-launch-and-mcp-audit
plan: "03"
subsystem: plugin-audit-harness-and-go-egress
status: partial-deferred
tags:
  - audit-plugins
  - plugin-audit
  - go-egress
  - network-policy
  - telemetry-suppression
  - deferred-verification
dependency_graph:
  requires:
    - 04-01-SUMMARY.md
    - 04-02-SUMMARY.md
  provides:
    - scripts/audit-plugins.sh headless audit harness (D-04/D-07/D-08/D-09/D-10)
    - ./rebuild.sh audit-plugins verb (D-05)
    - go_egress binary-scoped network allowlist (proxy.golang.org, sum.golang.org, vuln.go.dev)
    - NET-04 assertion extended to go_egress
    - PLUGIN-AUDIT.md interim/baseline report (D-06)
    - criterion #3 (telemetry suppression) verified
  affects:
    - policy.yaml (go_egress policy added)
    - rebuild.sh (audit-plugins verb + NET-04 go_egress assertion + header)
    - scripts/audit-plugins.sh (--dangerously-skip-permissions; vuln-reviewer MUST_SUCCEED)
    - CLAUDE.md (Core Value + Network Policy reconciled to two-allowlist model)
  deferred:
    - criterion #2 full plugin-audit green pass (all plugins terminal + verdicts matched)
---

# 04-03 Summary — Plugin Audit Harness + go_egress (PARTIAL / DEFERRED)

## What shipped (committed, verified)

- **`scripts/audit-plugins.sh`** (`ab3dffb`) — fail-closed headless audit harness: static
  enumeration of 11 agents + 6 skills, per-plugin `claude -p` with timeout, telemetry-suppression
  assertion, `VIOLATIONS` hard-fail (exit 1) on any expected/actual mismatch (D-10). Both
  `<verify>` gates pass. Confirmed working: it correctly caught every mismatch/HANG.
- **`audit-plugins` verb** in `rebuild.sh` (`e620b7a`) — distinct from the log-surfacing `audit`
  verb; thin wrapper delegating to the harness (D-05).
- **`go_egress` network allowlist** (`2bd4dba`) — second, independently binary-scoped egress
  policy (`proxy.golang.org` / `sum.golang.org` / `vuln.go.dev` → Go-toolchain binaries) so the
  Go-tool reviewers resolve modules + the vuln DB without widening `claude_egress`. NET-04
  extended to assert it. `--dangerously-skip-permissions` added to the harness invocation to match
  the autonomous `claude` verb; `vuln-reviewer` reclassified MUST_SUCCEED.
- **CLAUDE.md** (`a24bdb1`) — Core Value, Network constraint, and Network Policy section reconciled
  to the two-allowlist (claude + go) model.
- **`PLUGIN-AUDIT.md`** — interim/baseline report (see it for full per-plugin evidence).

## Verified live

- **Criterion #3 (telemetry suppression): PASS** — 0 `claude.exe` attempts to statsig/sentry under
  heavy plugin load, across all runs.
- **`go_egress` works** — with it in place, `lint-reviewer` (golangci-lint) resolves modules and
  passes; 7/11 reviewer agents pass; the network-blocked failures from the first run are gone.
- The harness's hard-fail discipline (D-10) is proven — it caught permission-stalls, network
  blocks, HANGs, and a verdict MISMATCH across iterations.

## Deferred (criterion #2 — NOT achieved this phase)

A full green single-pass audit of all 17 plugins was **intentionally deferred** for two reasons:

1. **Methodology (operator decision):** the toolkit **skills** assume a real codebase with an
   active change/PR context. Exercising them headless against a near-empty `/claudeshared` does
   not measure whether they work as intended. The full audit should be re-run once the sandbox
   is used for **real development work**.
2. **Harness-robustness gaps** surfaced by execution: the 120s per-invocation timeout is too low
   for tool-executing plugins under the autonomous flag (`vuln` govulncheck scan, `test` go test,
   `agent-readiness`, `full-review`), and 17 heavy back-to-back invocations trip the subscription's
   transient rate limit. Fixing these (raise timeout, retry/backoff, pacing, failing-output
   capture) is the revisit work.

## Revisit conditions

Re-run `./rebuild.sh audit-plugins` after the sandbox has a real codebase + workflow context;
apply the harness-robustness fixes; then lock the per-plugin expected-outcome table against real
results. Tracked in `.continue-here.md` and `PLUGIN-AUDIT.md`.

## Commits

- `ab3dffb` feat(04-03): headless plugin audit harness
- `e620b7a` feat(04-03): `audit-plugins` verb
- `2bd4dba` feat(04-03): go_egress allowlist + harness fix (flag + vuln reclassify + NET-04)
- `a24bdb1` docs(04-03): CLAUDE.md two-allowlist reconciliation
