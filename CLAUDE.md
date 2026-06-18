<!-- GSD:project-start source:PROJECT.md -->

## Project

**Claude Sandbox (Fedora 44 / OpenShell)**

A reproducible, network-isolated development sandbox — built as an NVIDIA OpenShell sandbox from a Fedora 44 image — for running Claude Code with `--dangerously-skip-permissions` safely. The sandbox bundles a Go toolchain and the claude-engineering-toolkit plugins, applies supply-chain cooldown pinning to its dependencies, and mounts `~/claudeshared` read-write so the operator can clone repos there and do development with Claude inside the sandbox. It is for a developer who wants to give Claude elevated, autonomous permissions without exposing the host or the open internet.

**Core Value:** Claude can run fully autonomous (`--dangerously-skip-permissions`) inside a sandbox that has **zero direct network egress** — all model inference is brokered through the OpenShell gateway — so elevated permissions can't be used to reach or exfiltrate to the open internet.

### Constraints

- **Platform**: Sandbox runtime must be NVIDIA OpenShell — built/managed via the `openshell` CLI on this host.
- **Build tool**: Container image must be built with podman (`podman build`), not the Docker daemon. The image reference is then handed to `openshell sandbox create --from <image-ref>`.
- **Base image**: Fedora 44 — base for the sandbox image.
- **Network**: Running sandbox must have zero direct internet egress; inference via OpenShell gateway only.
- **Supply chain**: govulncheck, gsd-core (+ all deps), and Claude Code CLI pinned to "latest as of 4 days before build" (rolling). Cooldown window default 4 days.
- **Install methods**: Go and golangci-lint via RPM; govulncheck via `go install`; gsd-core + Claude Code via their package managers (npm).
- **Reproducibility**: rebuild must be script-driven and repeatable.

<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->

## Technology Stack

## 1. NVIDIA OpenShell CLI

### How `sandbox create --from` works

| Form | Resolution |
|------|-----------|
| Bare name (e.g. `base`, `ollama`) | `ghcr.io/nvidia/openshell-community/sandboxes/<name>:latest` |
| Local directory path (e.g. `./my-sandbox-dir`) | Builds Dockerfile in that directory into the local Docker daemon, then creates sandbox |
| Explicit Dockerfile path | Builds that Dockerfile into the local Docker daemon |
| Full container image reference (e.g. `registry.io/img:tag`) | Pulls the image directly |

# 1. Build the image with podman (NOT the OpenShell-managed Docker-daemon build)

# 2. Create the sandbox from the podman-built image reference

### Host Directory Mounts (`~/claudeshared`)

| Field | Value |
|-------|-------|
| `type` | `bind` |
| `source` | Absolute host path (e.g. `/Users/patrickheckenlively/claudeshared`) |
| `target` | Path inside sandbox (e.g. `/claudeshared`) |
| `read_only` | `false` for read-write |

- `source` must be an absolute path, not `~`-prefixed. Expand `$HOME` in the build/run script.
- OpenShell rejects mount targets that overlap with `/etc/openshell`, `/etc/openshell-tls`, workspace root, or supervisor paths.
- Named volumes (`type: volume`) do NOT require `enable_bind_mounts = true` unless the named volume itself is bind-backed.

### Gateway Inference Brokering (`inference.local`)

- Strips any `Authorization` / API-key header the sandbox provides (the in-sandbox placeholder is never forwarded)
- Injects the real backend credential from the configured provider record (the `claude-code` subscription login)
- Rewrites the model to the gateway-configured model
- Forwards to the upstream Anthropic (or other) endpoint

# Register local gateway (already done on this machine):

# Configure inference provider using the existing Claude subscription login:

# ^ loads the existing Claude Code subscription credential from host state

#   (~/.claude/.credentials.json / macOS keychain) — NO api key involved.

#   `openshell provider refresh` handles OAuth token refresh host-side.

#   Exact --type/profile flag confirmed empirically in the inference phase.

# Point inference.local at the provider:

### Zero-Egress Policy

## 2. Fedora 44 Base Image

### RPM Packages

| Package | Fedora 44 version (from Koji) | Notes |
|---------|-------------------------------|-------|
| `golang` | 1.26.4-2.fc44 | Standard Go toolchain; installs to `/usr/bin/go`, sets `GOPATH` |
| `golangci-lint` | 2.11.3-1.fc44 | Confirmed in Koji (`f44` + `f44-updates-testing` tags) |
| `nodejs` | Available in F44 | Provides Node.js for npm-based installs |
| `npm` | Bundled with nodejs | npm 11 expected (matches host) |
| `git` | Standard | Required for cloning toolkit repo |
| `ca-certificates` | Standard | Required for HTTPS in container |

## 3. govulncheck via `go install`

### Version Selection (Rolling Cooldown)

| Version | Published |
|---------|-----------|
| v0.1.0 | 2023-04-24 |
| v0.2.0 | 2023-06-30 |
| v1.0.0 | 2023-07-13 |
| v1.0.1 | 2023-08-17 |
| v1.0.2 | 2024-01-16 |
| v1.0.3 | 2024-01-22 |
| v1.0.4 | 2024-02-06 |
| v1.1.0 | 2024-04-15 |
| v1.1.1 | 2024-05-21 |
| v1.1.2 | 2024-06-06 |
| v1.1.3 | 2024-07-16 |
| v1.1.4 | 2025-01-06 |
| v1.2.0 | 2026-04-10 |
| v1.3.0 | 2026-04-22 |

### How to Determine the Version in a Build Script

# List all versions, fetch timestamps, pick latest before cutoff

## 4. gsd-core Install

### Version Selection (Rolling Cooldown)

| Version | Published |
|---------|-----------|
| 1.2.0 | 2026-05-31 |
| 1.3.0 | 2026-06-04 |
| 1.3.1 | 2026-06-04 |
| 1.4.0-rc.1 | 2026-06-07 |
| 1.4.0-rc.2 | 2026-06-08 |
| 1.4.0 | 2026-06-08T18:34:56Z |
| 1.4.1 | 2026-06-09T04:09:36Z (AFTER cutoff) |

### gsd-core Dependencies (for cooldown analysis)

| Package | Version range | Latest before cooldown |
|---------|---------------|------------------------|
| `ws` | `8.20.1` (exact pin) | `8.21.0` (2026-05-22) |
| `@anthropic-ai/claude-agent-sdk` | `^0.2.84` | `0.3.169` (2026-06-08T18:11:18Z) |

### Install Mechanism

- `gsd-core` → `bin/install.js` (the interactive installer)
- `gsd-tools` → `gsd-core/bin/gsd-tools.cjs` (runtime CLI used by agents)

# Step 1: Install the package and all transitive deps pinned to versions before cutoff

# Step 2: Run the installer to deploy hooks/commands into ~/.claude

- `npm install -g @opengsd/gsd-core --min-release-age=${COOLDOWN_DAYS} --ignore-scripts --allow-git=none --allow-remote=none --allow-directory=none` installs the package and pins all transitive deps to versions older than `COOLDOWN_DAYS` days. `--min-release-age` applies to direct and transitive dependencies (npm 11 native cooldown).
- `gsd-core --claude --global` then runs `bin/install.js` which writes the actual Claude Code integration files (commands, hooks, agent definitions) into `~/.claude/`.
- `npx` does not support `--min-release-age`. Pinning transitive deps requires `npm install`.
- `--ignore-scripts` is safe for gsd-core 1.4.0 — it has no `install`/`preinstall`/`postinstall` scripts; `prepare` does not run for registry installs; real setup is the explicit `gsd-core --claude --global`.

### npm --min-release-age: What It Actually Does

- Resolves the latest dist-tag version older than the specified number of days
- Rebuilds the entire dependency tree using only versions satisfying that age requirement
- Applies to **all** transitive dependencies, not just direct dependencies
- If no version satisfies the age requirement for a required package, `npm install` errors
- Reproducibility trade-off: the resolved versions are relative to build wall-clock time; `versions.lock` records the actual resolved versions post-build; `verify-pins.sh` re-checks all resolved packages against the absolute `COOLDOWN_DATE` and is the absolute backstop

## 5. Claude Code CLI

### Version Selection (Rolling Cooldown)

- `latest`: 2.1.177 (published 2026-06-13)
- `stable`: 2.1.153 (published 2026-05-27)
- `next`: 2.1.177

| Version | Published |
|---------|-----------|
| 2.1.165 | 2026-06-05T05:22:42Z |
| 2.1.166 | 2026-06-05T19:01:59Z |
| 2.1.167 | 2026-06-06T01:18:42Z |
| 2.1.168 | 2026-06-06T23:32:52Z |
| 2.1.169 | 2026-06-08T18:11:20Z |

### Install Command in Dockerfile

- `npm install -g @anthropic-ai/claude-code --min-release-age=${COOLDOWN_DAYS} --allow-scripts @anthropic-ai/claude-code --allow-git=none --allow-remote=none --allow-directory=none` installs claude-code and pins the transitive tree to the age window.
- `--allow-scripts @anthropic-ai/claude-code` is required — claude-code has a first-party `postinstall: node install.cjs` (confirmed on 2.1.169); this permits only its own script and blocks all transitive-dep scripts.
- `--min-release-age` selects the latest `@latest` dist-tag version older than `COOLDOWN_DAYS` days; no explicit `@VERSION` pin needed at install time.
- Claude Code ships frequently (daily releases); without `--min-release-age`, `@latest` would resolve to a post-cooldown version.
- The native installer at `https://claude.ai/install.sh` (or `npx @anthropic-ai/claude-code`) runs interactively and cannot enforce a transitive age window.
- `npm install -g @anthropic-ai/claude-code` with `--min-release-age` is the correct containerized approach (no interactive prompts, reproducible, version recorded post-build in versions.lock)

### Runtime Configuration

## 6. Plugin Loading (`--plugin-dir`)

# Clone the toolkit during image build

## Summary: Complete Dockerfile Pattern

# Build args (computed by rebuild script from rolling cooldown)

# 1. System packages

# 2. govulncheck (pinned, via go install)

# 3. gsd-core (pinned, with transitive dep pinning)

# 4. Claude Code CLI (pinned, with transitive dep pinning)

# 5. Plugin toolkit (latest HEAD, no cooldown — operator trusts the fork)

# Entry point — override ANTHROPIC_BASE_URL at runtime or in CMD

#!/usr/bin/env bash

# Query cooldown versions from registries

## Alternatives Considered

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| `npm install -g pkg --min-release-age=N` (npm 11 native cooldown) | `npm install -g pkg@VERSION --before=DATE` (pre-resolved pin) | Both work; `--min-release-age` is simpler (no host-side npm registry query needed) and keeps the rolling cooldown fully automated. govulncheck still uses Go-proxy date selection because it is not an npm package. |
| `npm install -g pkg --min-release-age=N` | pnpm/yarn date pinning | Neither pnpm nor yarn has an equivalent age-window flag that pins transitive deps |
| `npm install -g pkg --min-release-age=N` | Committing `package-lock.json` | Works but is cumbersome for rolling cooldown: requires re-running install and committing a new lockfile each rebuild |
| `npm install -g pkg --min-release-age=N` | Registry time-travel proxy (Verdaccio `--snapshot`) | Verdaccio snapshot support exists but adds operational complexity; npm `--min-release-age` is sufficient and built-in |
| `go install pkg@vX.Y.Z` (explicit tag) | `go install pkg@latest` | `@latest` ignores cooldown; always use explicit tag computed from Go proxy timestamps |
| `openshell sandbox create --policy ./policy.yaml` (empty `network_policies`) | `openshell policy update --add-endpoint ...` post-create | Policy must be set at create time for static sections; zero-egress requires empty `network_policies` from the start |
| Podman driver | Docker driver | Gateway config already uses Podman; switching to Docker driver would require config change; both support bind mounts with `enable_bind_mounts` |
| Clone toolkit at image build time | Clone at sandbox start via entrypoint | Sandbox has zero egress at runtime; git clone cannot reach github.com from inside the running sandbox |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `npx @opengsd/gsd-core@latest --claude --global` | `npx` does not support `--min-release-age`; `@latest` resolves to whatever is current | `npm install -g @opengsd/gsd-core --min-release-age=${COOLDOWN_DAYS} --ignore-scripts ... && gsd-core --claude --global` |
| npm install without `--ignore-scripts` for gsd-core | gsd-core 1.4.0 has no install scripts; omitting the flag relies on npm's implicit warn-and-skip default which may change across npm versions | `--ignore-scripts` (explicit and durable) |
| npm install without `--allow-scripts @anthropic-ai/claude-code` for claude-code | claude-code requires its first-party `postinstall: node install.cjs`; omitting the flag may fail silently if npm defaults change | `--allow-scripts @anthropic-ai/claude-code` (permits only first-party script) |
| npm install without `--allow-git=none --allow-remote=none --allow-directory=none` | These flags default to `all` (permissive); omitting them leaves git-ref, tarball-URL, and local-directory dependency sources allowed — only registry semver ranges are acceptable in a supply-chain-hardened sandbox | Pass `--allow-git=none --allow-remote=none --allow-directory=none` on every npm install |
| `claude --allow-dangerously-skip-permissions` | Prompts the user on each risky action; designed for interactive opt-in not autonomous operation | `claude --dangerously-skip-permissions` |
| `ANTHROPIC_BASE_URL=https://inference.local/v1` | Claude Code appends `/v1/messages`; adding `/v1` in the base URL creates `/v1/v1/messages` (double path) | `ANTHROPIC_BASE_URL=https://inference.local` (no trailing `/v1`) |
| `--from-existing` provider flag in Dockerfile | Reads from host keychain/environment, not available inside container build | Set credentials via `openshell provider create` on the host before sandbox creation |
| `golangci-lint` via `go install` (from upstream) | Bypasses dnf cooldown mechanism; version not controlled by RPM package manager | `dnf install golangci-lint` in Fedora 44 (provides 2.11.3) |
| `openshell policy update --add-endpoint api.anthropic.com:443` | Defeats zero-egress guarantee; opens direct path to Anthropic bypassing inference.local privacy routing | Use `inference.local` via gateway; no direct egress allowlist needed |

## Version Compatibility

| Package | Version | Compatible With | Notes |
|---------|---------|-----------------|-------|
| `golang` (RPM) | 1.26.4 (fc44) | `govulncheck@v1.3.0` requires Go 1.25+ (from go.mod) | Go 1.26 satisfies the requirement |
| `golangci-lint` (RPM) | 2.11.3 (fc44) | `golang@1.26` | Upstream golangci-lint 2.x supports Go 1.22+ |
| `@anthropic-ai/claude-code` | 2.1.169 | Node.js 18+ | Fedora 44 nodejs will provide a compatible version |
| `@opengsd/gsd-core` | 1.4.0 | `@anthropic-ai/claude-code@2.1.169` | gsd-core is runtime-agnostic; installs hooks/commands into `~/.claude` |
| OpenShell CLI | 0.0.62 | Podman driver (configured) | `enable_bind_mounts = true` already set |

## Sources

- `openshell --help`, `openshell sandbox --help`, `openshell sandbox create --help`, `openshell policy --help`, `openshell policy update --help`, `openshell inference --help`, `openshell inference set --help`, `openshell gateway --help`, `openshell settings --help` — verified live on installed binary v0.0.62 (HIGH confidence)
- `/opt/homebrew/Library/Taps/nvidia/homebrew-openshell/Formula/openshell.rb` — live formula confirming v0.0.62 (HIGH confidence)
- `~/.config/openshell/gateway.toml` — live config confirming `compute_drivers = ["podman"]` and `enable_bind_mounts = true` (HIGH confidence)
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/reference/sandbox-compute-drivers.mdx` — bind mount schema and `enable_bind_mounts` config (HIGH confidence)
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/sandboxes/manage-sandboxes.mdx` — `--from`, `--driver-config-json`, `--policy` usage (HIGH confidence)
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/sandboxes/inference-routing.mdx` — `inference.local` URL, `ANTHROPIC_BASE_URL`, Claude Code example (HIGH confidence)
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/sandboxes/policies.mdx` — zero-egress via empty `network_policies` (HIGH confidence)
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/reference/gateway-config.mdx` — full TOML schema for Docker/Podman drivers (HIGH confidence)
- `https://registry.npmjs.org/@anthropic-ai/claude-code` — live registry query, 439 versions, cooldown version confirmed as 2.1.169 (HIGH confidence)
- `https://registry.npmjs.org/@opengsd/gsd-core` — live registry query, cooldown version confirmed as 1.4.0 (HIGH confidence)
- `https://proxy.golang.org/golang.org/x/vuln/@v/<tag>.info` — live Go proxy, all 14 versions with dates, cooldown version confirmed as v1.3.0 (HIGH confidence)
- `https://koji.fedoraproject.org/koji/buildinfo?buildID=2957394` — golangci-lint-2.11.3-1.fc44 confirmed in f44 tag (HIGH confidence)
- `https://koji.fedoraproject.org/koji/packageinfo?packageID=golang` — golang-1.26.4-2.fc44 confirmed (HIGH confidence)
- `https://hub.docker.com/_/fedora/tags` — fedora:44 confirmed available, last pushed 2026-05-28 (HIGH confidence)
- `https://docs.npmjs.com/cli/v11/commands/npm-install#before` — `--before` applies to all transitive deps (HIGH confidence)
- `claude --help` — `--dangerously-skip-permissions` and `--plugin-dir` flags verified (HIGH confidence)
- `https://raw.githubusercontent.com/open-gsd/gsd-core/main/bin/install.js` — `--claude` and `--global` arg parsing confirmed at line 349-352 (HIGH confidence)

<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->

## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->

## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->

## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->

## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:

- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->

## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
