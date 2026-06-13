# Project Research Summary

**Project:** Claude Sandbox (Fedora 44 / OpenShell)
**Domain:** Reproducible network-isolated AI coding agent container sandbox
**Researched:** 2026-06-13
**Confidence:** HIGH

## Executive Summary

This project is a single-developer local sandbox for running Claude Code with `--dangerously-skip-permissions` safely. The pattern is well-established: a Dockerfile defines an immutable image built during a network-allowed phase, and an NVIDIA OpenShell sandbox applies a zero-egress runtime policy so the running container cannot reach the open internet directly. All model inference is brokered through the OpenShell gateway's `inference.local` endpoint, which injects credentials without exposing them in the image. This is not a Docker-only container — it is an OpenShell-managed sandbox, meaning the `openshell` CLI handles lifecycle, policy enforcement, and gateway credential brokering.

The recommended approach is a `Dockerfile` (Fedora 44 base) plus an idempotent `rebuild.sh` that computes a rolling 4-day cooldown date, queries npm and Go module proxy registries to resolve pinned versions, passes them as podman build args, then tears down and recreates the sandbox. RPM packages (`golang`, `golangci-lint`) are installed during `dnf update -y`; cooldown-sensitive packages (`govulncheck`, `gsd-core`, Claude Code CLI) are pinned to the latest version published before the cooldown date. The `claude-engineering-toolkit` fork is cloned at HEAD during build (no cooldown) since the operator maintains it. A `~/claudeshared` host directory is bind-mounted read-write into the sandbox for repo work.

The key risks are: (1) the inference gateway misconfigured before sandbox creation causes Claude to hang for ~290 seconds per call, (2) adding `api.anthropic.com` to the egress policy defeats the zero-egress guarantee, (3) podman layer caching of `dnf update -y` silently reuses stale packages unless a changing ARG precedes the layer, and (4) UID mismatch between the macOS host user and the container user can make the bind mount read-only from Claude's perspective. All of these have clear prevention strategies documented in the research.

## Key Findings

### Recommended Stack

The complete, version-verified stack is: Fedora 44 base image (`docker.io/library/fedora:44`, available for amd64 and arm64); Go 1.26.4 and golangci-lint 2.11.3 via Fedora 44 RPM; govulncheck v1.3.0 via `go install` (pinned); `@opengsd/gsd-core@1.4.0` and `@anthropic-ai/claude-code@2.1.169` via npm with `--before=2026-06-09`; claude-engineering-toolkit cloned at HEAD via `git clone`. The `npm --before=<date>` flag (npm v11, bundled with Node on this host) applies cooldown pinning to all transitive dependencies, which is not achievable with yarn or pnpm. Go has no equivalent native flag — version resolution must happen in the rebuild script before `podman build` by querying `proxy.golang.org` timestamps. The OpenShell CLI (v0.0.62) is already installed and the gateway's Podman driver already has `enable_bind_mounts = true`.

**Core technologies:**
- **Fedora 44 (`fedora:44`):** Base image — official, multi-arch, ships Go 1.26 and golangci-lint 2.11.3 in standard repos
- **NVIDIA OpenShell v0.0.62:** Sandbox lifecycle, policy enforcement, gateway inference brokering — the non-negotiable runtime platform
- **`@anthropic-ai/claude-code@2.1.169`:** The AI agent; requires `--dangerously-skip-permissions` + `--plugin-dir` for autonomous operation
- **`@opengsd/gsd-core@1.4.0`:** GSD project tooling; installed with `npm install -g ... && gsd-core --claude --global`
- **govulncheck v1.3.0:** Go supply-chain auditing; installed via `go install` with explicit version tag
- **`npm --before=<cooldown-date>`:** Transitive dependency cooldown pinning for all npm packages; critical for supply-chain hygiene

### Expected Features

**Must have (table stakes):**
- Dockerfile with all tooling baked in at build time — no network at runtime
- `rebuild.sh` that is idempotent: stops/removes old sandbox, rebuilds image, recreates sandbox
- Image tagged with build date for rollback and audit
- Rolling 4-day cooldown window computed at rebuild time (not hardcoded)
- Zero-egress OpenShell policy (`network_policies: {}` in `policy.yaml`) applied at sandbox create time
- Inference gateway routing via `ANTHROPIC_BASE_URL=https://inference.local`
- `~/claudeshared` bind-mounted read-write with correct UID alignment
- Claude launched with `--dangerously-skip-permissions --plugin-dir /toolkit`
- Network egress smoke test after sandbox creation (assert `curl https://example.com` fails)
- Go toolchain, golangci-lint, govulncheck installed and functional

**Should have (differentiators):**
- `COOLDOWN_DATE` ARG before `dnf update` layer to bust the podman build cache on each rebuild
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` in entrypoint to suppress telemetry noise
- `versions.lock` artifact recording exact resolved versions with publish dates
- Preflight check in rebuild script: assert `openshell inference get` shows configured provider before `sandbox create`
- Structured timestamped log output from rebuild script
- Parameterized cooldown window via `--cooldown-days` argument

**Defer (v2+):**
- `policy prove` formal verification (not confirmed in OpenShell public docs)
- Makefile wrapper targets
- Pin-held post-build verification comparing installed version publish dates against cooldown date
- `openshell logs` post-session egress audit automation

### Architecture Approach

The architecture separates concerns into two strict phases: build-time (unrestricted network; all packages downloaded and baked into the image) and runtime (zero direct egress; gateway brokers inference via gRPC mTLS). The `openshell-sandbox` supervisor process runs inside the container as a sidecar — it fetches an `InferenceBundle` from the gateway at startup, acts as a local L7 inference proxy for Claude Code, and injects the `ANTHROPIC_API_KEY` via `GetSandboxProviderEnvironment` RPC so the key never appears in the image. Claude Code's inference calls go to `localhost` (the supervisor), not to the internet.

**Major components:**
1. **Dockerfile** — defines the immutable image; all install steps run here; accepts cooldown version build args
2. **rebuild.sh** — orchestrator: computes cooldown date, resolves pinned versions, builds image, deletes old sandbox, creates new sandbox with policy and bind mount
3. **policy.yaml** — zero-egress network policy with empty `network_policies`; passed via `--policy` at `sandbox create` time
4. **versions.lock** — generated artifact recording exact resolved versions + publish dates; written by rebuild.sh before `podman build`
5. **OpenShell gateway** — host-side broker: holds credentials, proxies inference, enforces L7 policy
6. **openshell-sandbox supervisor** — in-container sidecar: L7 inference proxy and credential injector

### Critical Pitfalls

1. **Inference gateway not configured before sandbox creation** — Claude hangs ~290 seconds per API call in interactive sessions (OpenShell issue #759). Prevention: rebuild.sh must run `openshell inference get` as a preflight check and fail fast if the provider is not registered.

2. **Allowlisting `api.anthropic.com` in the egress policy** — voids the zero-egress guarantee; Claude with `--dangerously-skip-permissions` can exfiltrate data via API payloads. Prevention: policy must have zero Anthropic endpoint entries; inference routes only through `inference.local`.

3. **podman layer caching `dnf update -y`** — rebuilds silently reuse stale RPM packages, defeating the rolling cooldown. Prevention: place `ARG COOLDOWN_DATE` before the `dnf update` line so a changed date busts the cache.

4. **`~/claudeshared` UID mismatch on macOS** — rootless Podman maps non-root container UIDs into subordinate host UID ranges, making the bind mount effectively read-only for Claude. Prevention: run the container process as UID 0 (which rootless Podman maps to the actual macOS user) or use `--userns=keep-id`.

5. **`go install ...@latest` ignoring cooldown** — Go has no `--before` equivalent; `@latest` always resolves to newest at build time. Prevention: query `proxy.golang.org` timestamps in rebuild.sh to resolve the correct version tag, then pass as `--build-arg GOVULNCHECK_VERSION=vX.Y.Z`.

## Implications for Roadmap

Based on research, suggested phase structure:

### Phase 1: Dockerfile and Supply-Chain Pinning
**Rationale:** Everything else depends on a correctly built image. The cooldown pinning logic and podman cache-busting must be established first — they are the foundation for reproducibility claims.
**Delivers:** A working Dockerfile that installs all tools from the verified stack with cooldown pinning; a `versions.lock` artifact.
**Addresses:** All P1 tooling features (Go, golangci-lint, govulncheck, gsd-core, Claude Code CLI, claude-engineering-toolkit)
**Avoids:** Pitfall 5 (npm lockfile), Pitfall 6 (go install @latest), Pitfall 7 (podman cache / dnf stale packages)

### Phase 2: Rebuild Script and Sandbox Lifecycle
**Rationale:** With the Dockerfile in place, the rebuild orchestration layer can be built. This phase produces the `rebuild.sh` that ties together version resolution, image build, sandbox teardown-and-recreate, policy application, and bind mount configuration.
**Delivers:** Idempotent `rebuild.sh`; `policy.yaml`; tagged image artifacts; bind mount configured correctly
**Addresses:** Teardown-and-recreate, image tagging, rolling cooldown computation, `~/claudeshared` mount, UID alignment
**Avoids:** Pitfall 9 (UID mismatch), Pitfall 7 (cache busting via COOLDOWN_DATE ARG), Pitfall 10 (lockfile drift)

### Phase 3: Network Policy and Inference Gateway Validation
**Rationale:** The zero-egress policy and gateway inference routing must be validated together — they are interdependent and the most likely source of subtle failures. This phase cannot be fully tested until Phase 2 produces a running sandbox.
**Delivers:** Confirmed zero-egress sandbox with working inference through `inference.local`; egress smoke test passing; preflight check in rebuild.sh
**Addresses:** Zero-egress policy, inference gateway routing, network egress smoke test
**Avoids:** Pitfall 1 (silent egress denial logs), Pitfall 2 (allowlisting Anthropic), Pitfall 3 (inference gateway misconfigured / 290s hang)

### Phase 4: Claude Code Configuration and MCP Audit
**Rationale:** Once the sandbox is confirmed to have working inference and zero egress, Claude Code's full configuration — `--dangerously-skip-permissions`, `--plugin-dir`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, and MCP plugin network behavior — can be validated without network noise.
**Delivers:** Claude Code running autonomously with toolkit plugins; all MCP tools either functional or cleanly failing; telemetry noise suppressed
**Addresses:** `--dangerously-skip-permissions` + `--plugin-dir` launch, MCP plugin audit, `DISABLE_NONESSENTIAL_TRAFFIC`
**Avoids:** Pitfall 4 (Claude Code runtime network calls), Pitfall 8 (build-phase vs. runtime network confusion)

### Phase Ordering Rationale

- Phase 1 before Phase 2: the rebuild script needs a Dockerfile to build; version resolution logic belongs in the script, not the Dockerfile.
- Phase 2 before Phase 3: policy and inference validation require an actual running sandbox, which the rebuild script produces.
- Phase 3 before Phase 4: MCP plugin audit is only meaningful once zero-egress is confirmed; otherwise blocked connections look like plugin failures.
- Phases are deliberately narrow to isolate failure modes — if the inference gateway hangs, it is unambiguously a Phase 3 issue, not a Phase 4 Claude configuration issue.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 3:** OpenShell inference routing has a known silent-logging bug (issue #704) and a 290-second hang bug (issue #759); the exact invocation for `openshell inference get` preflight and the correct `ANTHROPIC_BASE_URL` scheme may need live CLI verification during planning.
- **Phase 4:** MCP plugin network behavior in a zero-egress context is not fully documented; the claude-engineering-toolkit fork content is not yet audited for outbound calls.

Phases with standard patterns (skip research-phase):
- **Phase 1:** Stack is fully verified with live registry queries; all version pins are confirmed. No additional research needed.
- **Phase 2:** Rebuild script pattern is well-documented in ARCHITECTURE.md with exact CLI invocations and flag schemas. Standard bash scripting.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All version pins verified against live npm registry, Go module proxy, Koji, and Docker Hub queries; OpenShell CLI flags verified against installed v0.0.62 binary |
| Features | MEDIUM | P1 features are HIGH confidence; `policy prove` command is LOW confidence (not found in public docs); npm `--before` has a known ETARGET bug with pre-existing lockfiles |
| Architecture | HIGH | Derived from live CLI introspection and binary symbol analysis of the installed OpenShell binaries; gateway gRPC data flow confirmed |
| Pitfalls | HIGH | Core claims verified against OpenShell GitHub issues, npm docs, Go module proxy docs, and Claude Code issue tracker; specific issue numbers cited |

**Overall confidence:** HIGH

### Gaps to Address

- **`policy prove` command:** Not confirmed in public OpenShell docs as of 2026-06-13. Plan around `openshell logs` + curl smoke test as the primary egress verification path.
- **claude-engineering-toolkit network calls:** The fork has not been audited for outbound HTTP calls in agents/plugins. Must be done during Phase 4 execution before enabling the sandbox for real development work.
- **`--userns=keep-id` support in OpenShell sandbox create:** Standard Podman flag for UID mapping, but whether OpenShell's `--driver-config-json` exposes an equivalent is not confirmed. May require running as UID 0 as the fallback.
- **OpenShell issue #759 (290s hang):** Root cause unknown as of research date. Preflight check prevents the failure, but the underlying bug may affect interactive sessions unpredictably.

## Sources

### Primary (HIGH confidence)
- `openshell --help`, `openshell sandbox create --help`, `openshell policy --help`, `openshell inference --help` — verified on installed v0.0.62
- `~/.config/openshell/gateway.toml` — live config confirming `enable_bind_mounts = true`
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/sandboxes/inference-routing.mdx` — `inference.local`, `ANTHROPIC_BASE_URL`, Claude Code example
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/sandboxes/policies.mdx` — zero-egress via empty `network_policies`
- `https://registry.npmjs.org/@anthropic-ai/claude-code` — live registry query, cooldown version 2.1.169 confirmed
- `https://registry.npmjs.org/@opengsd/gsd-core` — live registry query, cooldown version 1.4.0 confirmed
- `https://proxy.golang.org/golang.org/x/vuln/@v/v1.3.0.info` — cooldown version v1.3.0 confirmed
- Binary symbol analysis of `/opt/homebrew/bin/openshell-gateway` and `openshell-sandbox` — confirmed gRPC inference proxy architecture
- `https://docs.npmjs.com/cli/v11/commands/npm-install#before` — `--before` applies to all transitive deps
- `claude --help` — `--dangerously-skip-permissions` and `--plugin-dir` flags verified

### Secondary (MEDIUM confidence)
- [NVIDIA/OpenShell issue #704](https://github.com/NVIDIA/OpenShell/issues/704) — silent deny logging at INFO level
- [NVIDIA/OpenShell issue #759](https://github.com/NVIDIA/OpenShell/issues/759) — 290s hang in interactive sessions
- [anthropics/claude-code issue #53899](https://github.com/anthropics/claude-code/issues/53899) — `DISABLE_NONESSENTIAL_TRAFFIC` bundles `DISABLE_AUTOUPDATER`
- [npm/cli#9277](https://github.com/npm/cli/issues/9277) — `--before` ETARGET bug with pre-existing lockfiles
- [OpenShell MCP protocol layer (deconvoluteai)](https://deconvoluteai.com/blog/nvidia-openshell-mcp-protocol-layer) — sandbox cannot inspect request bodies at MCP level

### Tertiary (LOW confidence)
- `policy prove` command — referenced in project context but not found in public OpenShell docs; treat as aspirational until confirmed in a future OpenShell release

---
*Research completed: 2026-06-13*
*Ready for roadmap: yes*
