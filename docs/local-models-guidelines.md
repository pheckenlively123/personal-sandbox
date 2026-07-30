# Local-Models Guidelines

Repo-specific playbook for the opt-in path that lets the in-sandbox `claude` binary talk to a
host-side, locally hosted model (llama.cpp, via the operator's existing switcher) instead of
`api.anthropic.com`. This is the sixth domain guideline, alongside
[`docs/security-guidelines.md`](security-guidelines.md), [`docs/error-handling-guidelines.md`](error-handling-guidelines.md),
[`docs/testing-guidelines.md`](testing-guidelines.md), [`docs/integration-guidelines.md`](integration-guidelines.md), and
[`docs/supply-chain-guidelines.md`](supply-chain-guidelines.md).

**Scope note:** this feature is sandbox-side only. No host-side proxy code lives in, is run from,
or is tested by this repo (D-03) — the proxy is the operator's to build, in a separate session on
the host. This document is the written guide for that build.

## What this repo ships (sandbox side)

Everything below is delivered by this repo. The proxy itself is not — see the next section.

- **A commented-out `local_model_egress` template in `policy.yaml`.** It mirrors the `go_egress`
  block structurally: a third, independently binary-scoped allowlist, `claude`-scoped only, with
  no `protocol` field (opaque TCP/TLS passthrough). It ships fully commented so the default
  posture — exactly `claude_egress` + `go_egress` — is byte-identical until an operator opts in.
  The endpoint host is a deliberate placeholder, `REPLACE-ME-LOCAL-MODEL-HOST` — no IP is guessed.
- **The `claude-local` verb in `rebuild.sh`.** `./rebuild.sh claude-local --base-url <url>` (or the
  `LOCAL_MODEL_BASE_URL` environment variable as a fallback) launches Claude Code inside the
  sandbox with `ANTHROPIC_BASE_URL` set to `<url>` at exec time — via `env ANTHROPIC_BASE_URL=...
  claude ...` in argv form, so no shell re-parses the value. The value is validated by allowlist
  regex, reject-everything-else: `^https?://[A-Za-z0-9._-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$`.
  Validation runs **before** any podman/openshell call, so a bad URL fails closed immediately.
- **The `NET-06` conditional assertion**, `assert_local_model_egress_if_present()` in `rebuild.sh`,
  runs every rebuild right after the mandatory `NET-04` check. It is a PASS with nothing further to
  do if `local-model-egress` is absent from the live policy (the default posture). If present, it
  fails the rebuild closed unless all of the following hold:
  - `endpoints` is non-empty;
  - no endpoint carries a `protocol` field (passthrough only);
  - the `REPLACE-ME-LOCAL-MODEL-HOST` placeholder has been replaced with a real host;
  - every entry in `binaries[]` matches `.*/claude$` (no cross-scoping into a Go binary or anything
    else — this is the isolation guard).
- **`tests/test-local-model-guard.sh`** — a negative-path guard test that proves the `--base-url`
  validator fails closed on five cases (missing value, missing flag, shell-metacharacter
  injection, whitespace injection, and a `bogusverb` regression check) with no podman/openshell
  present.

That is everything the repo provides. The Anthropic<->local-model translation proxy that
`ANTHROPIC_BASE_URL` actually points at is **not** part of this repo — it is the operator's to
build on the host, in front of their existing llama.cpp switcher.

## Host-side proxy: what you must build

This section is advice for work done **outside** the sandbox, in a separate host-side session. The
sandbox has zero egress and cannot build, run, or test any of this itself.

**Upstream surface (what Claude Code speaks):** once `ANTHROPIC_BASE_URL` is repointed, Claude Code
talks the **Anthropic Messages API**, principally `POST /v1/messages` with SSE streaming. Your
proxy must expose this surface for Claude Code to work at all. `GET /v1/models` is also commonly
probed and worth stubbing.

**Downstream surface (what your switcher speaks) — the common case, D-02:** most llama.cpp
switcher/front-end setups (LiteLLM-style) expose an **OpenAI-compatible `POST
/v1/chat/completions`** endpoint. If that matches your switcher, the proxy's job is translating
Anthropic Messages requests/responses to and from that shape. The seams that actually bite:

- **System prompt handling** — Anthropic's top-level `system` field vs. an OpenAI `role: system`
  message inside `messages`.
- **Message content** — Anthropic's structured content blocks (`[{type: "text", text: "..."}]`,
  etc.) vs. OpenAI's plain string content.
- **Tool calling** — Anthropic's `tool_use` / `tool_result` content blocks vs. OpenAI's
  `tool_calls` array and `role: tool` messages.
- **Stop reasons** — Anthropic's `stop_reason` values (`end_turn`, `tool_use`, `max_tokens`, ...)
  vs. OpenAI's `finish_reason` values (`stop`, `tool_calls`, `length`, ...) — these do not map 1:1.
- **Usage fields** — Anthropic's `usage.input_tokens` / `usage.output_tokens` vs. OpenAI's
  `usage.prompt_tokens` / `usage.completion_tokens`.
- **SSE event names** — Anthropic's event stream (`message_start`, `content_block_delta`,
  `message_delta`, `message_stop`, ...) vs. OpenAI's `chat.completion.chunk` delta stream. These do
  not share an event vocabulary; the proxy must re-emit Anthropic-shaped SSE regardless of what it
  receives downstream.

**Bind the listener to loopback** (`127.0.0.1` / `localhost`) on the host — see "Security posture
and trade-offs" below for why.

**The fork in the road — if your switcher is llama.cpp-native instead (D-02):** if, after checking
your switcher, it turns out to expose llama.cpp's own native `/completion` endpoint rather than an
OpenAI-compatible one, the proxy's **downstream** half changes: instead of translating to
`/v1/chat/completions`, it must assemble llama.cpp's own prompt-template format and handle its own
(different) streaming shape. The **upstream** half — the Anthropic Messages API surface Claude Code
talks to — is unchanged either way. Check your switcher's actual configuration first; do not assume
the OpenAI-compatible case.

## Host reachability from the sandbox

This is a known, deliberately unresolved gap (D-03). The address the sandbox can use to reach a
host-side listener, running under Podman + OpenShell, is **unconfirmed** — this plan guesses
nothing here, and neither should you.

Candidates worth testing empirically once the `local_model_egress` block is enabled (these are
things to verify, not recommendations to follow blindly):

- A `host.containers.internal`-style DNS alias, if the Podman driver provides one.
- The Podman bridge network's gateway address (typically visible via `podman network inspect` on
  the relevant network from the host side).
- An explicitly published host interface/IP that the proxy binds beyond loopback (weakens the
  "traffic never leaves the machine" property below — prefer the other two options first).

**How to confirm empirically:** with the sandbox running and the proxy listening on the host, use
`./rebuild.sh connect` to get an in-sandbox shell, then attempt a raw TCP connection (once
`local_model_egress` is enabled and the sandbox rebuilt) to each candidate host:port and see which
one reaches the proxy.

**Whatever you confirm must be written into two places, and the two must agree:**

1. The `host:` field inside the uncommented `local_model_egress` block in `policy.yaml`.
2. The `--base-url` value (or `LOCAL_MODEL_BASE_URL`) passed to `./rebuild.sh claude-local`.

If they disagree, `claude` will either be denied by the policy (host mismatch) or unable to reach
the address it's given — neither fails loudly in an obvious way, so double-check both by hand.

## Enabling the opt-in egress allow

The full operator runbook, in order:

1. **Confirm the switcher protocol** (see "Host-side proxy" above, D-02) — OpenAI-compatible
   `/v1/chat/completions` or llama.cpp-native `/completion`.
2. **Build and run the proxy on the host**, in a separate host-side session (not this sandbox).
   Bind it to loopback.
3. **Confirm the reachable host address** (see "Host reachability from the sandbox" above) —
   empirically, do not guess.
4. **Edit `policy.yaml`**: uncomment the `local_model_egress` block by stripping the leading `# `
   from every template line, replace `REPLACE-ME-LOCAL-MODEL-HOST` with the confirmed address, and
   replace the example port `8787` with your proxy's actual port.
5. **Re-run `./rebuild.sh`** and confirm the `NET-06 PASS` line in the output (alongside the
   existing `NET-04 PASS` / `NET-05 PASS` lines). If `NET-06` fails, re-read its error message — it
   names exactly which condition (placeholder host, empty endpoints, a `protocol` field, or
   cross-scoping) was not satisfied.
6. **Launch:** `./rebuild.sh claude-local --base-url <url>` (matching what you put in
   `policy.yaml`, step 4).

`NET-05`'s deny-posture assertions are unaffected by any of this — they still assert that
non-allowlisted hosts (`statsig.anthropic.com`, `sentry.io`, `www.google.com`) are blocked.
`./rebuild.sh down` followed by re-commenting the `policy.yaml` block (or simply not uncommenting
it on the next rebuild) restores the default two-allowlist posture.

## Security posture and trade-offs

**Why a third, independently scoped allowlist, not a widening of `claude_egress` (D-01):** this
repo's established convention — set by the `go_egress` precedent — is that a new binary/purpose
gets its own independently-scoped policy block, never an addition to an existing one. Widening
`claude_egress` would mean every host in that list shares the same trust boundary; keeping
`local_model_egress` separate means the `NET-06` assertion (and any future review) can reason about
it in isolation, and a mistake in one block cannot silently expand another.

**Why it ships commented-out:** the default posture — the thing every fresh clone of this repo
gets — must remain exactly the two-allowlist Architecture B model with no operator-controlled
endpoint reachable by `claude`. Opt-in means an explicit, deliberate edit is required before this
surface exists at all.

**The honest trade-off:** allowing the `claude` binary to reach an operator-controlled endpoint
means the subscription OAuth token at `~/.claude/.credentials.json` is now present inside a sandbox
whose `claude` process also talks to a non-Anthropic host. The default model's isolation argument —
"the OAuth token transits `claude_egress` only, and `claude_egress` reaches only Anthropic's own
auth/API hosts" — no longer holds unmodified once `local_model_egress` is enabled; the token is not
sent to the local-model host, but it is present in the same process that can now reach it. This is
weaker than the default posture, and it is why this allow is opt-in and clearly separated rather
than assumed safe.

**Mitigations and recommendations:**

- Where practical, run local-model sessions on a sandbox that has **not** completed OAuth login
  (`./rebuild.sh login`) — i.e., no token present at all for that session.
- Keep the proxy on loopback (see "Host-side proxy" above) so the endpoint is not reachable from
  outside the host machine.
- The connection from the sandbox to the host-side proxy is likely **plaintext HTTP** (no TLS
  hop to loopback) — prompt content is unencrypted on that hop. This is accepted because it never
  leaves the host machine; it is a materially different exposure than a plaintext hop over an
  actual network would be.

**Reconciling this with `CLAUDE.md` and `.planning/PROJECT.md` — read this if you're a future
agent auditing this change:** `CLAUDE.md`'s What-NOT-to-Use table forbids `ENV
ANTHROPIC_BASE_URL=https://inference.local` in the Dockerfile, and `.planning/PROJECT.md` describes
Architecture B as having no base-URL override. **This feature does not violate either of those.**
It sets `ANTHROPIC_BASE_URL` **only** at exec time, under an explicit opt-in verb (`claude-local`)
that the operator must invoke by name — the default `claude` verb is completely untouched and still
sets nothing. This feature also does not introduce an `ANTHROPIC_API_KEY`, an `inference.local`
gateway, or a host-side `openshell provider create` step — none of the things Architecture B
specifically rules out. If you are reviewing this repo for Architecture B compliance, `claude-local`
is a deliberate, documented, default-off exception, not a regression.

## Unconfirmed — verify before relying on this

None of the rows below are repo-verified. Each is something the operator must confirm before
`claude-local` can be trusted to work.

| Item | What to check | Consequence if wrong |
|------|----------------|-----------------------|
| Switcher protocol (D-02) | Is your existing switcher OpenAI-compatible (`/v1/chat/completions`) or llama.cpp-native (`/completion`)? Check its actual config/docs, don't assume. | Building the proxy's downstream half against the wrong API means it never successfully calls the switcher — requests fail even though the sandbox-side plumbing (policy, verb, NET-06) is all green. |
| Host-reachable address and port (D-03) | Confirm empirically from inside the sandbox (see "Host reachability from the sandbox" above) which address reaches the host-side proxy under your Podman + OpenShell setup. | A wrong or guessed host means `claude-local` either gets denied by `local_model_egress` (mismatch with `policy.yaml`) or times out trying to reach an address nothing is listening on. |
| Whether Claude Code needs an auth env var alongside `ANTHROPIC_BASE_URL` | Untested from inside this sandbox: some non-Anthropic-endpoint setups additionally require an `ANTHROPIC_AUTH_TOKEN`-style value for Claude Code to send requests at all. Check Claude Code's current behavior against a non-default base URL, and how that interacts with the subscription OAuth credential already stored in the sandbox. | If a second credential is required and absent, `claude-local` may fail at the client level even with a working proxy and a correct URL — indistinguishable at first from a policy or reachability problem. |
| Model identifier strings the proxy must accept | Which model name(s) Claude Code sends in requests, and what your proxy/switcher needs to map them to on the llama.cpp side. | A model-name mismatch causes the proxy (or switcher) to reject the request or silently route to the wrong local model. |
