# AGENTS.md

Agent-agnostic onboarding for any AI tool (Claude Code, Cursor, CodeRabbit, etc.) working in this repo. Read this first, then follow the linked guideline for the domain you're touching. For human-facing operator docs (verbs, login flow, validation checklist), see `README.md`.

## Project orientation

This is a **reproducible, network-isolated development sandbox** — an NVIDIA OpenShell sandbox built from a Fedora 44 image — for running Claude Code with `--dangerously-skip-permissions` safely. The sandbox bundles a Go toolchain plus the claude-engineering-toolkit plugins, applies rolling supply-chain cooldown pinning to its dependencies, and mounts `~/claudeshared` read-write so the operator can clone repos and develop with Claude inside it.

Networking is **Architecture B**: two binary-scoped, TLS-passthrough egress allowlists and nothing else reaches the internet.
- `claude_egress` — `api.anthropic.com:443`, `platform.claude.com:443`, `claude.ai:443`, scoped to the `claude` binary only (subscription OAuth; no `ANTHROPIC_API_KEY`, no gateway).
- `go_egress` — `proxy.golang.org:443`, `sum.golang.org:443`, `vuln.go.dev:443`, scoped to the Go binaries only.

The two scopes are isolated from each other — that isolation is the core security invariant (it's what keeps the in-sandbox OAuth token at `~/.claude/.credentials.json` safe). See `README.md` for the full rationale and trade-offs.

## Docs index (read the one for your domain)

| Guideline | Read it before you… |
|---|---|
| [`docs/security-guidelines.md`](docs/security-guidelines.md) | Edit `policy.yaml`, touch egress allowlists, change `read_write` grants, or write any code that handles the OAuth token. The fail-closed security playbook. |
| [`docs/error-handling-guidelines.md`](docs/error-handling-guidelines.md) | Write or modify any bash script. Covers `set -euo pipefail` footguns, fail-closed validation, traps, exit-code handling, tolerate-absent teardown. |
| [`docs/testing-guidelines.md`](docs/testing-guidelines.md) | Add or change anything under `tests/` or an audit harness. "Prove the guard, not the happy path"; seed tampered input, assert exact exit codes. |
| [`docs/integration-guidelines.md`](docs/integration-guidelines.md) | Touch any seam between podman, OpenShell CLI, npm registry, Go proxy, or the claude binary. Never-trust-raw-stdout, `exec` flags, binary-path matching. |
| [`docs/supply-chain-guidelines.md`](docs/supply-chain-guidelines.md) | Change a dependency, pin, the Dockerfile installs, or the resolve/verify/lock flow. The rolling cooldown discipline and required npm flag set. |

These five files hold the domain depth. This document only indexes them — do not duplicate their content into changes here.

## Cross-cutting conventions

These span multiple domains and aren't fully covered by any single guideline or the README:

- **Bash-only codebase.** Every script starts with `#!/usr/bin/env bash` and `set -euo pipefail`; paths resolve from `BASH_SOURCE`, never `$0`/`pwd`. Diagnostics go to **stderr**; stdout is reserved for machine-parsable output.
- **`rebuild.sh` is the single entry point.** Verb-first dispatch (`rebuild|status|connect|login|claude|down|audit|audit-plugins`); flags follow; unknown verbs/args fail with usage. The dispatcher is a thin wrapper — real logic lives in `scripts/*.sh` and is delegated to (D-05). Don't fatten the dispatcher.
- **Fail-closed by default.** A check that cannot prove success must `exit 1` (or increment a `VIOLATIONS` counter in audit harnesses). No WARN/soft-pass escape hatch. A swallowed/failed sub-fetch is itself a violation, never a silent pass.
- **podman, not docker, for builds.** Images are built with `podman build`; the reference is handed to `openshell sandbox create --from <image-ref>`. The **OpenShell CLI is the sandbox runtime** (create/exec/policy/logs).
- **Rolling cooldown pin discipline.** Every external dependency is frozen to "latest published on or before `today − 4 days`." You normally do not hand-edit versions — re-running the build re-pins. See `docs/supply-chain-guidelines.md` for depth; never use `@latest`, `npx --before`, or `--min-release-age`.
- **Requirement/decision IDs are load-bearing.** Code comments, commit messages, and tests reference IDs like `NET-04`, `RUN-02`, `T-04-07`, `D-05`, `CR-01`, `PIN-07`, `IN-01`, `WR-02`. When you add a guard, anchor it to the ID it defends. When you change a policy claim, change its matching assertion (NET-04) in the **same commit**.
- **Commit message convention** (from `git log`): `type(NN-PP): subject`, where `type` is `feat|fix|docs|…` and `NN-PP` scopes to the GSD phase/plan (e.g. `feat(04-03): …`, `docs(04-02): …`); quick/ad-hoc tasks use `type(quick-<slug>): …`. End every commit body with the trailer:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```

## Repo structure

```
rebuild.sh              # single entry point — verb-first dispatcher (build + lifecycle)
Dockerfile              # Fedora 44 image; zero literal versions (all via ARG)
policy.yaml             # OpenShell sandbox policy: Landlock filesystem + two egress allowlists
scripts/                # delegated logic (rebuild.sh wraps these)
  resolve-versions.sh   #   cooldown version resolver → KEY=VALUE on stdout
  build-and-lock.sh     #   end-to-end: resolve → podman build → extract → lock → verify
  verify-pins.sh        #   fail-closed PIN-07 gate (re-queries registries)
  audit-plugins.sh      #   strict hard-failing plugin/telemetry audit harness
tests/                  # bash negative-path guard tests (no runner, no CI)
  test-pin-held.sh      #   proves verifier rejects a tampered pin
  test-cache-bust.sh    #   proves cooldown-date ARG busts the layer cache
docs/                   # the five domain guidelines (see index above)
versions.lock           # committed reproducibility record: top-level pins + cooldown metadata
versions-npm.json       # committed transitive snapshot of what npm --before resolved
.planning/              # GSD planning workflow artifacts (see below)
CLAUDE.md               # large Claude-specific project doc + tech detail (not agent-agnostic)
README.md               # operator guide: verbs, OAuth login, audit, validation checklist
```

## The GSD planning workflow (process convention — important)

This repo uses the **GSD planning workflow**. Planning artifacts live in `.planning/`:
- `ROADMAP.md` — phases, success criteria, requirement coverage.
- `STATE.md` — current position, progress, recent context.
- `PROJECT.md`, `REQUIREMENTS.md` — project definition and requirement IDs.
- `phases/NN-<name>/` — per-phase PLAN/SUMMARY/RESEARCH/REVIEW/VERIFICATION docs.

Per CLAUDE.md's **"GSD Workflow Enforcement"**, file-changing work is expected to go through a GSD command so planning artifacts and execution context stay in sync:
- `/gsd-quick` — small fixes, doc updates, ad-hoc tasks.
- `/gsd-debug` — investigation and bug fixing.
- `/gsd-execute-phase` — planned phase work.

**Do not make ad-hoc direct edits outside a GSD workflow unless the operator explicitly asks to bypass it.** When you do change code, update the corresponding `.planning/` artifacts (ROADMAP/STATE and the phase SUMMARY) and reference the requirement/decision ID.

## Common pitfalls / anti-patterns (this repo)

Each is detailed in a guideline; these are pointers, not the full rule:

- **Don't add a `protocol` field to any `policy.yaml` egress endpoint** — omitting it = opaque TLS passthrough; `protocol: rest` would terminate TLS and expose the OAuth token. *(security / integration)*
- **Don't widen or cross-scope the egress allowlists** — no new hosts; never put a Go binary in `claude_egress` or `*/claude` in `go_egress`; `statsig.anthropic.com`/`sentry.io` stay absent. *(security)*
- **Keep NET-04 assertions in sync with `policy.yaml`** — every policy claim needs its matching fail-closed assertion in the same commit, or the invariant is assumed, not enforced. *(security / integration)*
- **Don't use `@latest`, `npx … --before`, or `--min-release-age`** — they bypass the cooldown pin or silently no-op on Fedora's npm. Use explicit `pkg@VER --before=DATE`. *(supply-chain)*
- **Never `eval` external/registry/plugin output** — allowlist-validate and assign via `printf -v`; grep plugin output, never execute it. *(security / integration)*
- **Mind `set -e` footguns** — no bare `var=$(cmd)` for fallible commands, no `(( x++ ))`, `grep -c` needs `|| true; ${x:-0}`. *(error-handling)*
- **Never hand-edit `versions.lock`** to advance a version past the cooldown window — the verifier re-checks the registry and fails closed. *(supply-chain)*
- **Use `sandbox exec … --workdir`, never `connect`** for in-sandbox commands; pick `--tty` (interactive) vs `--no-tty --timeout` (parsable). *(integration)*
- **Don't mutate real artifacts in tests** — seed tampered copies in `mktemp -d`, assert exact exit codes, clean up in a `trap … EXIT`. *(testing)*
