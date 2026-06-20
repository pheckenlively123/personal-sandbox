# Claude Sandbox (Fedora 44 / OpenShell)

## What This Is

A reproducible, network-isolated development sandbox — built as an NVIDIA OpenShell sandbox from a Fedora 44 image — for running Claude Code with `--dangerously-skip-permissions` safely. The sandbox bundles a Go toolchain and the claude-engineering-toolkit plugins, applies supply-chain cooldown pinning to its dependencies, and mounts `~/claudeshared` read-write so the operator can clone repos there and do development with Claude inside the sandbox. It is for a developer who wants to give Claude elevated, autonomous permissions without exposing the host or the open internet.

## Core Value

Claude can run fully autonomous (`--dangerously-skip-permissions`) inside a sandbox with a **three-host, binary-scoped, TLS-passthrough egress allowlist** — `api.anthropic.com:443` (inference), `platform.claude.com:443` (Console auth), and `claude.ai:443` (auth) — and nothing else reaches the open internet (Architecture B). Claude authenticates via in-sandbox subscription OAuth (`./rebuild.sh login`); there is no gateway, no `ANTHROPIC_API_KEY`, no host-side provider setup.

## Requirements

### Validated

<!-- Shipped and confirmed valuable. -->

- [x] Sandbox image is built with podman (`podman build`) from a Fedora 44 base, then run as an OpenShell sandbox (`openshell sandbox create --from <image-ref>`) — *Validated in Phase 2: rebuild.sh creates claude-sandbox from the podman-built `localhost/claude-sandbox:<date>` ref and it reaches Ready (BLD-06)*
- [x] `~/claudeshared` mounted read-write into the sandbox for cloning and developing repos — *Validated in Phase 2: bind mount + policy.yaml; in-sandbox write to /claudeshared lands host-owned (RUN-03/RUN-04)*
- [x] A script rebuilds the sandbox on demand (re-applies the rolling cooldown each run) — *Validated in Phase 2: idempotent `./rebuild.sh` runs cleanly twice (BLD-01/BLD-02)*
- [x] Cooldown is a rolling window: each rebuild pins to "latest as of 4 days before build" — *Validated in Phases 1–2: build-and-lock.sh resolves the rolling cooldown, invoked fresh by each rebuild.sh run*

### Active

<!-- Current scope. Building toward these. -->

- [ ] All RPM updates applied during build (`dnf update -y`)
- [ ] Go toolchain installed via RPM (`golang`)
- [ ] golangci-lint installed via RPM
- [ ] govulncheck installed via `go install`, pinned to the latest version as of the cooldown date
- [ ] gsd-core installed, pinned to the latest version as of the cooldown date, with the same cooldown pinning extended to all of its dependencies
- [ ] Claude Code CLI installed, pinned to the latest version as of the cooldown date
- [ ] claude-engineering-toolkit fork cloned (`https://github.com/pheckenlWork/claude-engineering-toolkit.git`, default branch, latest HEAD)
- [ ] Claude launched with `--plugin-dir` pointed at the cloned toolkit so its agents and skills are available
- [ ] Claude launched with `--dangerously-skip-permissions`
- [x] Sandbox runtime enforces a 3-host TLS-passthrough egress allowlist (api.anthropic.com / platform.claude.com / claude.ai, binary-scoped to claude); all other egress denied (Architecture B) *(Phase 3)*

### Out of Scope

<!-- Explicit boundaries. Includes reasoning to prevent re-adding. -->

- Cooldown pinning for the claude-engineering-toolkit — operator maintains the fork, so latest HEAD is trusted
- Unconstrained open internet egress from the running sandbox beyond the three Claude auth/API hosts — the Architecture B 3-host allowlist is the egress boundary; no additional hosts permitted
- GPU allocation — not required for this workload unless surfaced later
- Multi-user / shared-host hardening beyond the single operator — single-developer tool

## Context

- **Host:** macOS (darwin), with `openshell` + `openshell-gateway` (`/opt/homebrew/bin`), `podman`, `docker` (Rancher Desktop), `nerdctl`, Node v26 / npm 11 already installed.
- **OpenShell model:** `sandbox create --from <Dockerfile|dir|image>` accepts a Dockerfile/dir (built via the local Docker daemon) **or a full image reference**. This project builds the image with `podman build` and passes the resulting image reference to `--from`, avoiding the Docker daemon. OpenShell sandboxes are themselves Podman-backed at runtime; the build-phase plan must confirm the podman-built image is visible to OpenShell (separate docker/podman image stores). Network egress is governed by a sandbox **policy** (endpoint allowlist); the Architecture B 3-host allowlist (api.anthropic.com / platform.claude.com / claude.ai) is set via `policy.yaml` at create time; all other egress is denied.
- **Build vs runtime networking:** the podman build phase has network (needed for `dnf update`, `go install`, npm install, git clone); the 3-host allowlist requirement applies to the *running* sandbox via policy (Architecture B).
- **`~/claudeshared`** already exists on the host and is the shared workspace for cloned repos.
- **Supply-chain intent:** pin third-party packages to versions that existed before a cooldown window (default 4 days) to avoid pulling freshly published (potentially malicious) releases.

## Constraints

- **Platform**: Sandbox runtime must be NVIDIA OpenShell — built/managed via the `openshell` CLI on this host.
- **Build tool**: Container image must be built with podman (`podman build`), not the Docker daemon. The image reference is then handed to `openshell sandbox create --from <image-ref>`.
- **Base image**: Fedora 44 — base for the sandbox image.
- **Network**: Running sandbox allows ONLY `api.anthropic.com:443`, `platform.claude.com:443`, and `claude.ai:443` (all TLS passthrough, binary-scoped to claude); all other egress denied (Architecture B). No gateway, no `ANTHROPIC_BASE_URL` override.
- **Supply chain**: govulncheck, gsd-core (+ all deps), and Claude Code CLI pinned to "latest as of 4 days before build" (rolling). Cooldown window default 4 days.
- **Install methods**: Go and golangci-lint via RPM; govulncheck via `go install`; gsd-core + Claude Code via their package managers (npm).
- **Reproducibility**: rebuild must be script-driven and repeatable.

## Key Decisions

<!-- Decisions that constrain future work. Add throughout project lifecycle. -->

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Run as an OpenShell sandbox built from a Fedora 44 Dockerfile | "nvidia openshell" resolves to the installed OpenShell CLI, which builds from a Dockerfile/dir and runs as a sandbox | — Pending |
| Build the image with podman, hand the image reference to `openshell sandbox create --from <image-ref>` | Operator prefers podman over the Docker daemon for image builds; OpenShell `--from` accepts a full image reference | ✓ Confirmed (Phase 2): OpenShell creates the sandbox from the podman-built `localhost/claude-sandbox:<date>` ref (image_pull_policy `missing` uses the local store). NOTE: OpenShell sandbox images MUST contain a `sandbox` user+group and `iproute`, and `--policy` OVERRIDES the built-in default (a custom policy must reproduce the full default + added paths) |
| Claude Code connects directly to api.anthropic.com via a 3-host TLS-passthrough allowlist (Architecture B), not through an OpenShell gateway | Phase 3 quick-task pivot: the original gateway/zero-egress model was replaced; Architecture B gives the same containment with simpler auth (in-sandbox OAuth) and no host-side provider setup | ✓ Confirmed (Phase 3): egress allowlist in policy.yaml; NET-04/NET-05 assertions pass; claude reaches api.anthropic.com directly |
| Authenticate via in-sandbox subscription OAuth (`./rebuild.sh login` → browser URL outside → paste code) instead of an `ANTHROPIC_API_KEY` or host-side provider injection | Architecture B — no gateway to inject credentials; subscription OAuth token lives at `~/.claude/.credentials.json` inside the sandbox; egress is restricted to the three Claude auth/API hosts only (mitigates token exfiltration) | ✓ Confirmed (Phase 3): in-sandbox login flow works; token stored in-sandbox only |
| Rolling cooldown (build date − 4 days), window configurable | Keeps a constant supply-chain cooldown gap across periodic rebuilds | — Pending |
| Cooldown applies to govulncheck, gsd-core (+deps), and Claude Code CLI | Consistent supply-chain mitigation for network-installed components | — Pending |
| claude-engineering-toolkit cloned at latest HEAD (no cooldown) | Operator maintains the fork, so it's trusted | — Pending |
| Network needed at build time, zero egress enforced only at runtime | dnf/go/npm/git need network to build; policy enforces isolation when running | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-06-15 — Phase 2 complete (rebuild.sh + sandbox lifecycle)*
