---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
status: Ready to execute
last_updated: "2026-06-20T00:43:16.626Z"
progress:
  total_phases: 4
  completed_phases: 3
  total_plans: 10
  completed_plans: 9
  percent: 75
---

# Project State: Claude Sandbox (Fedora 44 / OpenShell)

---

## Project Reference

**Core Value**: Claude can run fully autonomous (`--dangerously-skip-permissions`) inside a sandbox that has zero direct network egress — all model inference is brokered through the OpenShell gateway — so elevated permissions can't be used to reach or exfiltrate to the open internet.

**Current Focus**: Phase 2 — Rebuild Script and Sandbox Lifecycle

---

## Current Position

Phase: 04 (claude-code-launch-and-mcp-audit) — PARTIAL / audit DEFERRED
Plan: 3 of 3 (04-03 partial)
**Status**: 04-01 ✓ (blocker fixes), 04-02 ✓ (`claude` verb + Architecture B docs), 04-03 PARTIAL —
harness + `audit-plugins` verb + `go_egress` allowlist shipped and committed; criterion #1 (launch)
and criterion #3 (telemetry suppression) verified. **Criterion #2 (full plugin-audit green) DEFERRED**
by operator decision: the toolkit skills need a real-codebase/PR context to be meaningfully audited, and
the harness needs robustness fixes (raise 120s timeout; rate-limit retry/backoff + pacing; capture
failing-invocation output). Revisit after real sandbox usage — see
`.planning/phases/04-claude-code-launch-and-mcp-audit/.continue-here.md`.

**Key decision (2026-06-20):** added a second binary-scoped egress allowlist `go_egress`
(proxy.golang.org / sum.golang.org / vuln.go.dev → Go toolchain) so the Go-tool reviewers resolve
modules + vuln DB; the project's egress posture is now two allowlists (claude + go), not Claude-only.
CLAUDE.md Core Value + Network Policy reconciled.

**Overall Progress**:

```
[Phase 1] [Phase 2] [Phase 3] [Phase 4]
[ DONE ✓ ] [  ....  ] [  ....  ] [  ....  ]
  100%        0%          0%          0%
```

**Phase Progress**: 1 of 4 phases complete (25%)

---

## Performance Metrics

**Plans executed**: 3
**Plans succeeded first try**: 3
**Repair cycles used**: 0
**Phases complete**: 1 / 4

---

## Accumulated Context

### Key Decisions Made

| Decision | Phase | Rationale |
|----------|-------|-----------|
| 4 phases at coarse granularity | Roadmap | Research's suggested 4-phase structure maps cleanly to the 4 requirement clusters; phases have distinct failure modes worth isolating |
| RUN-03/RUN-04 (bind mount) in Phase 2 | Roadmap | Bind mount is configured at `openshell sandbox create` time, not at Claude launch time — belongs with lifecycle, not Claude config |
| RUN-01/RUN-02 (Claude launch flags) in Phase 4 | Roadmap | MCP audit only meaningful after zero-egress confirmed (Phase 3); blocked plugins look like policy failures otherwise |
| Phase 01 P01 | 427 | 3 tasks | 5 files |
| Phase 01 P02 | 254 | 2 tasks | 4 files |
| Phase 01-dockerfile-and-supply-chain-pinning P03 | 7min | 2 tasks | 5 files |
| Phase 02 P01 | 20min | 3 tasks | 2 files |
| Phase 03 P01 | 3min | 2 tasks | 1 files |
| Phase 04 P01 | 30min | 2 tasks | 2 files |
| Phase 04 P02 | 20min | - tasks | - files |

### Open Questions / Risks

- **BLD-06 (podman → OpenShell image handoff)**: How OpenShell resolves a podman-built image across separate image stores is an open research item. Must be confirmed empirically in Phase 2.
- **NET-03 exact provider flags**: Exact `openshell provider create ... --from-existing` and `openshell inference set` invocations to be confirmed during Phase 3 execution.
- **OpenShell issue #759 (290s hang)**: Root cause unknown. Preflight check mitigates but may still affect interactive sessions.
- **`--userns=keep-id` support in OpenShell `sandbox create`**: Whether OpenShell exposes this Podman flag is unconfirmed. Fallback: run container as UID 0.
- **claude-engineering-toolkit MCP network calls**: Fork not yet audited for outbound HTTP at agent load time or tool invocation. Audit is the primary task of Phase 4.

### Implementation Notes

*(Populated during execution)*

### Blockers

*(None — Phase 1 shipped clean; the jq-missing build blocker was fixed and re-verified)*

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|
| 260618-p6b | npm cooldown via --min-release-age + explicit script/source flags | 2026-06-18 | a930856 | [260618-p6b-npm-cooldown-via-min-release-age-plus-ex](./quick/260618-p6b-npm-cooldown-via-min-release-age-plus-ex/) |
| fast | rebuild.sh: distinguish gateway-unreachable from not-configured (silent-exit fix) | 2026-06-18 | b25afdd | — |
| fast | rebuild.sh: check only Gateway inference route (ignore System/sandbox-system) in provider gate | 2026-06-18 | d166241 | — |
| 260618-qr4 | Automate inference provider setup in rebuild.sh (--model default opus-4-8, --set-model fast-switch, podman autostart, create-or-update) | 2026-06-18 | 4b4337d | [260618-qr4-automate-inference-provider-setup-in-reb](./quick/260618-qr4-automate-inference-provider-setup-in-reb/) |
| 260619-e0p | Architecture B-hardened redesign: verb-first rebuild.sh, subscription OAuth login, api.anthropic.com-only TLS-passthrough egress (claude-binary-scoped), inverted NET gates; removed inference.local/--model machinery | 2026-06-19 | 4f99856 | [260619-e0p-implement-architecture-b-hardened-rebuil](./quick/260619-e0p-implement-architecture-b-hardened-rebuil/) |
| 260619-eow | Revert npm cooldown --min-release-age → --before + explicit pins (image npm too old for --min-release-age; it silently installed @latest → verify-pins PIN-07 failed) | 2026-06-19 | e9b05a2 | [260619-eow-revert-npm-cooldown-to-before-mechanism](./quick/260619-eow-revert-npm-cooldown-to-before-mechanism/) |
| fast | rebuild.sh: tolerate wrapped "sandbox not found" in idempotent teardown (openshell miette line-wraps the phrase) | 2026-06-19 | d03d324 | — |
| 260619-fbi | Add claude.ai + platform.claude.com to egress allowlist (subscription OAuth needs them, not just api.anthropic.com); ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1; NET-04 checks 3 hosts; NET-05 deny-posture-only (curl can't test binary-scoped allows) | 2026-06-19 | a6c8e83 | [260619-fbi-add-claude-auth-hosts-to-egress-allowlis](./quick/260619-fbi-add-claude-auth-hosts-to-egress-allowlis/) |
| fast | policy.yaml: grant /home/sandbox in filesystem_policy so claude can persist ~/.claude OAuth token (Landlock default-deny blocked runtime home → login didn't persist) | 2026-06-19 | 851eae4 | — |
| fast | rebuild.sh: connect/login land in /claudeshared via exec --tty --workdir (connect verb has no cwd flag; / is not Landlock-listable) | 2026-06-19 | 6338120 | — |
| 260620-sxf | Fix missing GSD skills in sandbox: gsd-core --claude --global ran as root (→ /root/.claude) but runtime user is 'sandbox' (→ /home/sandbox/.claude); move useradd before install, run integration as sandbox user, add fail-closed build guard | 2026-06-20 | a6e724e | [260620-sxf-fix-missing-gsd-skills-in-sandbox-by-dep](./quick/260620-sxf-fix-missing-gsd-skills-in-sandbox-by-dep/) |
| 260622-omo | RUN-05 fail-closed gateway bind-mount preflight: rebuild.sh verifies enable_bind_mounts=true under [openshell.drivers.podman] in gateway.toml before sandbox create (read-only, never edits host config); makes the repo portable to fresh hosts (e.g. Fedora) instead of failing mid-build with a cryptic podman error | 2026-06-22 | f9b834f | [260622-omo-make-openshell-gateway-enable-bind-mount](./quick/260622-omo-make-openshell-gateway-enable-bind-mount/) |

---

## Session Continuity

**Last updated**: 2026-06-20 (Quick task 260620-sxf complete — GSD integration now deployed into the runtime sandbox user's home)
**Last action**: Quick task 260620-sxf committed (a6e724e) — Dockerfile: sandbox user created before GSD install; gsd-core --claude --global runs as 'sandbox' into /home/sandbox/.claude; fail-closed build guard (Step 4c)
**Next action**: Operator runs ./rebuild.sh (Step 4c guards the fix), then ./rebuild.sh claude to confirm GSD commands/skills load
**Stopped at**: Phase 3 complete + quick task 260620-sxf complete
**Resume file**: None

---
*State initialized: 2026-06-13*

## Decisions

- [Phase ?]: re-query not cached dates
- [Phase ?]: associative array cache
- [Phase ?]: CUTOFF_EXCL exclusive next-day-midnight bound replaces T23:59:59Z for all publish-date comparisons in verifier and resolver (CR-01 fix)
- [Phase 02]: ARG BUILD_DATE + five LABEL lines added to Dockerfile via D-04 pattern (LABEL-via-ARG for portability — provenance travels with image regardless of build entry point)
- [Phase 03]: check_inference_provider detects unconfigured provider via ANSI-stripped output grep (not exit code — exits 0 in both states); inverted jq -e for NET-04 policy assertion; two-target smoke test (api.anthropic.com + example.com) proves deny-all not just Anthropic-specific block
- [Phase 02]: build-and-lock.sh --build-date flag added with T-02-01 YYYY-MM-DD allowlist validation before podman build invocation
- [Phase ?]: [Phase 02]: T-02-01 mitigation — BUILD_DATE allowlist-validated against YYYY-MM-DD regex before podman build invocation; no eval
- [Phase ?]: Add /opt to policy.yaml read_only only (Blocker 1 / T-04-02 mitigated): toolkit is operator fork, no runtime writes
- [Phase ?]: Copy govulncheck from /root/go/bin to /usr/local/bin at build time (Blocker 2): Landlock default-deny blocks GOPATH for sandbox user
- [Phase ?]: CMD repointed to /bin/bash (D-03): OpenShell supervisor is PID 1 and never executes image CMD; canonical launch is ./rebuild.sh claude (04-02)
- [Phase ?]: D-01 resolved: claude verb ships in rebuild.sh reusing the connect/login exec --tty --workdir /claudeshared pattern (04-02)
- [Phase ?]: D-02 resolved: no OAuth precondition check in claude verb — claude handles unauthenticated case itself (04-02)
- [Phase ?]: D-13 resolved: ROADMAP/REQUIREMENTS/PROJECT.md reconciled to Architecture B; inference.local/gateway/zero-egress references removed; 3-host TLS-passthrough allowlist wording now consistent (04-02)
