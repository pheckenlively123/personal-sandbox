---
phase: quick-260730-v3j
plan: "01"
subsystem: local-model-egress-and-launch-verb
tags:
  - local-model
  - llama-cpp
  - policy-yaml
  - rebuild-sh
  - opt-in-egress
  - net-06
  - run-07
status: complete
dependency_graph:
  requires: []
  provides:
    - "policy.yaml: commented-out local_model_egress template (opt-in, claude-scoped, no protocol field)"
    - "rebuild.sh: claude-local verb (--base-url / LOCAL_MODEL_BASE_URL) — RUN-07"
    - "rebuild.sh: assert_local_model_egress_if_present() — NET-06 fail-closed conditional assertion"
    - "tests/test-local-model-guard.sh — negative-path guard test"
    - "docs/local-models-guidelines.md — sixth domain guideline (host-side proxy build guide)"
  affects:
    - policy.yaml
    - rebuild.sh
    - tests/test-local-model-guard.sh
    - docs/local-models-guidelines.md
    - docs/security-guidelines.md
    - AGENTS.md
    - README.md
tech_stack:
  added: []
  patterns:
    - independently-scoped-third-allowlist (local_model_egress follows the go_egress precedent — new block, never a widening of claude_egress)
    - opt-in-commented-template (policy addition ships fully commented-out so the default posture is byte-identical until deliberately uncommented)
    - validate-before-podman (claude-local's --base-url allowlist-regex validation runs before ensure_podman_ready, so a bad URL fails closed with no host tool invoked)
    - conditional-fail-closed-assertion (assert_local_model_egress_if_present: PASS if the policy block is absent, fail-closed assertions only fire if present)
key_files:
  created:
    - tests/test-local-model-guard.sh
    - docs/local-models-guidelines.md
  modified:
    - policy.yaml
    - rebuild.sh
    - docs/security-guidelines.md
    - AGENTS.md
    - README.md
decisions:
  - "D-01 (proxy location): proxy runs on the host; sandbox reaches it via ANTHROPIC_BASE_URL set at exec time under the opt-in claude-local verb; egress addition follows docs/security-guidelines.md fail-closed discipline"
  - "D-02 (switcher protocol): unconfirmed at plan time — docs/local-models-guidelines.md builds guidance around the common OpenAI-compatible /v1/chat/completions case and documents the llama.cpp-native /completion fork explicitly"
  - "D-03 (scope): sandbox-side policy.yaml + rebuild.sh + docs only; no host-side proxy code written, run, or tested; host reachability documented as an open question with candidates to verify empirically, no IP guessed"
  - "D-04 (discretion): new independently-scoped policy block local_model_egress (go_egress precedent, not a claude_egress widening); verb claude-local; flag --base-url with LOCAL_MODEL_BASE_URL env fallback; doc at docs/local-models-guidelines.md as the sixth guideline"
metrics:
  duration: "~45 minutes (3 tasks, fully autonomous, static verification only)"
  completed_date: "2026-07-30"
  tasks_completed: 3
  files_modified: 7
---

# Quick Task 260730-v3j: Add Support for Locally Hosted llama.cpp Summary

Added sandbox-side, opt-in support for routing the in-sandbox Claude Code at a host-side Anthropic-compatible translation proxy fronting the operator's llama.cpp switcher — a commented-out `local_model_egress` policy template, a `claude-local` launch verb, a fail-closed `NET-06` assertion, a negative-path guard test, and a full host-side setup guide — with the default two-allowlist posture provably unchanged.

## What Was Built

### Task 1: `policy.yaml` — opt-in `local_model_egress` template (commit `b66be21`)

Appended a fully commented-out `local_model_egress` block to the end of `network_policies:`, mirroring `go_egress`'s structure exactly: 2-space-indented `local_model_egress:` key, 4-space `name: local-model-egress`, 4-space `endpoints:` with a 6-space `- host: REPLACE-ME-LOCAL-MODEL-HOST` entry and its `port: 8787`, and 4-space `binaries:` scoped to the two `claude` paths only. No `protocol` field anywhere in the template (opaque TCP/TLS passthrough). Every template line is prefixed `# ` at column 0 so stripping the leading two characters yields correctly indented YAML — verified by extracting and dedenting the block. Extensive prose comments explain the placeholder host, the fail-closed guard, and point to `docs/local-models-guidelines.md`. The top-of-file Architecture B header comment gained one short paragraph noting the optional third allowlist so a reader isn't surprised by the block at the bottom.

Verified: the comment-stripped `network_policies` region still contains exactly `claude_egress` and `go_egress` — the active/default posture is byte-identical to before this change.

### Task 2: `rebuild.sh` — `claude-local` verb, `--base-url` validation, `NET-06` assertion, guard test (commit `1736f92`)

Two deliverables, both TDD-flavored with the `<behavior>` cases proven by a dedicated test:

**`claude-local` verb (RUN-07).** Wired at all required sites: header usage block, verb allowlist (`case "$1"`), both usage strings, the flag loop (new `--base-url` / `--base-url=*` arms mirroring the existing `--since` pattern, with `LOCAL_MODEL_BASE_URL="${LOCAL_MODEL_BASE_URL:-}"` initialized alongside `AUDIT_SINCE=""`), a new dispatch arm placed immediately after the `claude)` arm, and the closing "Other verbs" summary. The dispatch arm validates `LOCAL_MODEL_BASE_URL` is non-empty and matches the allowlist regex `^https?://[A-Za-z0-9._-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$` **before** calling `ensure_podman_ready` — this ordering is what makes the guard testable with no podman/openshell present and is exactly what the guard test asserts. On success it execs `openshell sandbox exec --name ... --tty --workdir ... -- env ANTHROPIC_BASE_URL="${LOCAL_MODEL_BASE_URL}" claude --dangerously-skip-permissions --plugin-dir /opt/claude-engineering-toolkit`, wrapped in `set +e`/`set -e` to preserve the real exit code (mirrors the `claude` verb exactly). A comment above the arm anchors it to RUN-07 and explicitly distinguishes this exec-time env var from the Dockerfile `ENV ANTHROPIC_BASE_URL` that `CLAUDE.md`'s What-NOT-to-Use table forbids.

**`assert_local_model_egress_if_present()` (NET-06).** Defined immediately after `assert_claude_egress_allowlist` and called from the rebuild path right after it (new Step 5.5, before NET-05). Uses the same two-step guarded-fetch pattern as NET-04 (`openshell policy get` → `jq empty`, both fatal on failure). Presence probe: if no policy entry has `name == "local-model-egress"`, logs the default-posture info line and returns 0 (PASS, nothing further to check). If present, asserts endpoints non-empty, no endpoint carries a `protocol` field, the `REPLACE-ME-LOCAL-MODEL-HOST` placeholder does not survive, and every `binaries[].path` matches `.*/claude$` — each violation exits 1 with a `NET-06 VIOLATION:` message.

**`tests/test-local-model-guard.sh`.** Follows `tests/test-pin-held.sh` house style (`set -euo pipefail`, `BASH_SOURCE`-derived paths, `PASS:`/`FAIL:` stderr lines, a `VIOLATIONS` counter with a single hard gate at the end). Covers all five `<behavior>` cases: missing `--base-url`/env var (with `LOCAL_MODEL_BASE_URL` explicitly cleared via `env -u` so an operator's set env var can't make the test pass vacuously), `--base-url` with a missing value, a shell-metacharacter injection attempt, a whitespace-injection attempt, and a `bogusverb` regression check. All five exit 1 in this sandbox, where neither `podman` nor `openshell` is on `PATH` — proving the validator fires before any host-tool call. Made executable.

### Task 3: `docs/local-models-guidelines.md` + doc-index reconciliation (commit `7693ce7`)

New sixth domain guideline with the six required `##` headings in order: *What this repo ships (sandbox side)*, *Host-side proxy: what you must build*, *Host reachability from the sandbox*, *Enabling the opt-in egress allow*, *Security posture and trade-offs*, and *Unconfirmed — verify before relying on this*. Covers the Anthropic Messages API (`POST /v1/messages`, SSE) as the upstream surface Claude Code speaks; the common OpenAI-compatible `POST /v1/chat/completions` downstream translation (system prompt handling, content blocks, tool calling, stop-reason/finish-reason, usage field names, SSE event-name differences) with an explicit fork-in-the-road subsection for llama.cpp's native `/completion` alternative; the unconfirmed host-reachability gap with candidates to verify empirically (no IP guessed); the full operator enable runbook; the honest OAuth-token-isolation trade-off and an explicit reconciliation with `CLAUDE.md`'s What-NOT-to-Use table and `.planning/PROJECT.md`'s Architecture B description; and an Unconfirmed table (switcher protocol, host address/port, possible auth-env-var requirement, model identifier strings).

`docs/security-guidelines.md` gained rule 6 under "Editing `policy.yaml`" documenting `local_model_egress` as the single sanctioned, opt-in exception to "never widen an allowlist," plus a matching pre-merge checklist item. `AGENTS.md` gained a docs-index row and one sentence in the networking paragraph. `README.md` gained a Documentation table row, `claude-local` in the Available verbs block with a descriptive bullet, and a new "Running against a local model (opt-in)" section with a three-line summary deferring to the guideline.

## Acceptance Criteria Status

| Criterion | Status |
|-----------|--------|
| Default posture unchanged — active `network_policies` exactly `claude_egress`/`go_egress` | PASS |
| `policy.yaml` carries commented, correctly indented, claude-scoped, protocol-free template with a placeholder host | PASS |
| `./rebuild.sh claude-local` validates `--base-url` fail-closed before any host tool | PASS |
| `assert_local_model_egress_if_present` defined **and** called from the rebuild path | PASS |
| `tests/test-local-model-guard.sh` passes, covers five negative cases | PASS |
| `docs/local-models-guidelines.md` — all six sections, actionable build guide, unconfirmed items marked operator-verified | PASS |
| `AGENTS.md`/`README.md`/`docs/security-guidelines.md` reference the guideline and verb; no dangling doc links | PASS |
| No host-side proxy code written, run, or tested (D-03) | PASS |
| `bash -n rebuild.sh && bash -n tests/test-local-model-guard.sh` | PASS |
| `./rebuild.sh bogusverb` and `./rebuild.sh status` — no regression to existing dispatch | PASS |

## Deviations from Plan

None — plan executed exactly as written. All decisions (D-01 through D-04) resolved as specified in the plan's frontmatter.

## Auth Gates

None encountered — this task is entirely sandbox-side static/structural changes; no `podman`/`openshell` invocation was attempted (both absent from `PATH` in this executor environment, as noted in the plan).

## Threat Surface Scan

All new surface introduced by this plan is already modeled in the plan's own `<threat_model>` (T-V3J-01 through T-V3J-07) and mitigated as specified:

- T-V3J-01 (OAuth token reachable by a process now also talking to an operator-controlled endpoint): mitigated — opt-in, commented-out by default, claude-binary-scoped, explicit launch-time warning logged, documented trade-off with a non-OAuth'd-sandbox recommendation in `docs/local-models-guidelines.md`.
- T-V3J-02 (`--base-url` injection into `openshell sandbox exec` argv): mitigated — allowlist regex, argv form after `--`, no `eval`, two injection-shaped cases in the guard test (Cases 3 and 4).
- T-V3J-03 (operator uncomments template without filling the host): mitigated — `NET-06` aborts on a surviving `REPLACE-ME-LOCAL-MODEL-HOST` or empty `endpoints`.
- T-V3J-04 (`protocol: rest` added to the endpoint): mitigated — template omits it with explanation; `NET-06` fails closed on any `protocol` field.
- T-V3J-05 (cross-scoping a non-`claude` binary): mitigated — `NET-06` asserts every `binaries[].path` matches `.*/claude$`.
- T-V3J-06 (plaintext HTTP hop, sandbox→host proxy): accepted — documented in `docs/local-models-guidelines.md` (traffic never leaves the host machine).
- T-V3J-07 (supply chain): accepted — no new package installs introduced.

No surface beyond what the plan's threat register modeled.

## Known Stubs

None. All deliverables are fully wired: the `policy.yaml` template is inert-but-correct (commented out, verified strippable to valid YAML), the `claude-local` verb and `NET-06` assertion are both defined and called (verified by grep count ≥ 2 and ≥ 4 respectively), the guard test is green, and the guideline doc has no placeholder sections. The host-side proxy itself is intentionally out of scope (D-03) and is documented as such, not stubbed.

## Self-Check: PASSED

- Commit `b66be21` (Task 1, policy.yaml) exists: confirmed via `git log --oneline --all`
- Commit `1736f92` (Task 2, rebuild.sh + guard test) exists: confirmed via `git log --oneline --all`
- Commit `7693ce7` (Task 3, docs) exists: confirmed via `git log --oneline --all`
- `policy.yaml`, `rebuild.sh`, `tests/test-local-model-guard.sh`, `docs/local-models-guidelines.md`, `docs/security-guidelines.md`, `AGENTS.md`, `README.md` all found on disk
- `bash -n rebuild.sh && bash -n tests/test-local-model-guard.sh`: PASS
- `bash tests/test-local-model-guard.sh`: exit 0, all 5 cases PASS
- Active `network_policies` (comment-stripped): `claude_egress go_egress` — unchanged
- `./rebuild.sh bogusverb` → exit 1; `./rebuild.sh status` → reaches `preflight_tools` failure (podman not found), not an arg-parsing failure
- All six `docs/local-models-guidelines.md` headings present; no dangling `docs/*.md` link in any touched file
