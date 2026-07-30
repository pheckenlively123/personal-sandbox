# Quick Task 260730-v3j: Add support for locally hosted llama.cpp models - Context

**Gathered:** 2026-07-30
**Status:** Ready for planning

<domain>
## Task Boundary

Add the ability for Claude Code (running inside this zero-egress sandbox) to use
locally hosted models served via llama.cpp on the host, through a host-side
translation proxy that sits in front of an existing "switcher" the operator
already has configured in front of llama.cpp. The operator set up that switcher
in a separate Claude Code session running directly on the host (not this sandbox).

This sandbox cannot build, run, or test anything on the host — it has zero
egress and no visibility into host-side processes. This task is scoped to
**sandbox-side repo changes only**, plus written advice for host-side setup
that the operator will execute themselves outside the sandbox.

</domain>

<decisions>
## Implementation Decisions

### Proxy location
- The Anthropic<->llama.cpp translation proxy runs **on the host**, in front of
  the existing switcher. Claude Code inside the sandbox reaches it via
  `ANTHROPIC_BASE_URL` pointed at a host address; the sandbox does not run the
  proxy itself.
- Consequence: this repo's egress model changes from "3 fixed Claude hosts,
  binary-scoped" to something that must also allow the `claude` binary to reach
  a host-side endpoint. This is a new, security-relevant addition to
  `policy.yaml` — must follow `docs/security-guidelines.md` (fail-closed,
  explicit scoping, no accidental widening of `go_egress`).

### Switcher protocol
- Unknown/unconfirmed by the operator at task time. Build guidance around the
  common case — an OpenAI-compatible `/v1/chat/completions` endpoint — since
  that's what most llama.cpp switcher/front-end setups (e.g. LiteLLM-style)
  expose. Flag explicitly in the advice that this must be confirmed against the
  operator's actual switcher before wiring anything up, and note what changes
  if it turns out to be llama.cpp's native `/completion` endpoint instead.

### Scope of this quick task
- **Sandbox-side changes only**:
  - `policy.yaml`: a new, narrowly-scoped egress allowlist entry (or an
    addition to `claude_egress`, TBD by planner/executor) permitting the
    `claude` binary to reach the host-side proxy endpoint.
  - `rebuild.sh`: a mechanism to set `ANTHROPIC_BASE_URL` (or equivalent) when
    launching Claude Code so it targets the local-model proxy instead of
    `api.anthropic.com` — likely a new verb or flag (e.g. `./rebuild.sh claude
    --local`), following the existing verb-dispatch pattern.
  - Docs (`README.md`, `CLAUDE.md`, `AGENTS.md` as appropriate): document the
    new local-model path, its security posture, and the fact that it's opt-in.
- **Explicitly out of scope for this task**: writing, running, or testing any
  host-side proxy code. That is delivered as a written setup guide (endpoints
  to expose, translation shape needed, how to point it at the switcher) for
  the operator to implement in their host-side session — not as executable
  code from inside this sandbox.
- Host reachability specifics (what host address/port the sandbox uses to
  reach the host loopback/gateway under Podman + OpenShell) are a known gap —
  flag as an open question / TODO for the operator to confirm, don't guess a
  specific IP.

### Claude's Discretion
- Exact verb/flag naming in `rebuild.sh` for invoking the local-model path.
- Whether the new egress entry is a variant of `claude_egress` or a new
  independently-scoped policy block (follow the existing binary-scoping
  pattern either way — this repo's established convention per
  `docs/security-guidelines.md` and the `go_egress` precedent).
- Structure/location of the host-side proxy advice doc (e.g. new
  `docs/local-models-guidelines.md` following the existing five-guideline
  pattern, or a section in README.md).

</decisions>

<specifics>
## Specific Ideas

No specific proxy implementation was referenced — this is greenfield within
this repo. The existing `go_egress` allowlist (added in Phase 4 for the Go
toolchain reviewers) is the closest precedent for "add a second, independently
binary-scoped egress allow without widening `claude_egress`," and should be
used as the pattern to follow structurally, even though this is a different
binary/purpose.

</specifics>

<canonical_refs>
## Canonical References

- `policy.yaml` — current two-allowlist Architecture B egress model
  (`claude_egress`, `go_egress`), both binary-scoped, opaque TLS passthrough.
- `docs/security-guidelines.md` — fail-closed playbook for editing
  `policy.yaml` / egress allowlists / OAuth-token-adjacent code.
- `docs/integration-guidelines.md` — seam-crossing conventions (podman /
  OpenShell CLI / binary-path matching) relevant to how `rebuild.sh` execs
  `claude` with new env/flags.
- `rebuild.sh` `claude` verb (around line 446) — existing pattern for how
  Claude Code is launched inside the sandbox; the local-model path should
  extend this, not duplicate it.

</canonical_refs>
