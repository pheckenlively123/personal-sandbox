@AGENTS.md

<!-- The line above imports the agent-agnostic guide (project orientation, the docs/ index,
     cross-cutting conventions, and common pitfalls). This CLAUDE.md adds the fuller project
     reference + Claude Code-specific context below. Domain depth lives in docs/*-guidelines.md. -->

<!-- GSD:project-start source:PROJECT.md -->

## Project

**Claude Sandbox (Fedora 44 / OpenShell)**

A reproducible, network-isolated development sandbox — built as an NVIDIA OpenShell sandbox from a Fedora 44 image — for running Claude Code with `--dangerously-skip-permissions` safely. The sandbox bundles a Go toolchain and the claude-engineering-toolkit plugins, applies supply-chain cooldown pinning to its dependencies, and mounts `~/claudeshared` read-write so the operator can clone repos there and do development with Claude inside the sandbox. It is for a developer who wants to give Claude elevated, autonomous permissions without exposing the host or the open internet.

**Core Value:** Claude can run fully autonomous (`--dangerously-skip-permissions`) inside a sandbox with **two independently binary-scoped, TLS-opaque egress allowlists** and **nothing else reaches the open internet**. The `claude` binary reaches only the three Claude auth/API hosts — `api.anthropic.com:443` (inference), `platform.claude.com:443` (Console auth), `claude.ai:443` (claude.ai auth); the Go toolchain (`go`, `golangci-lint`, `govulncheck`) reaches only the three Go-tooling hosts — `proxy.golang.org:443` (modules), `sum.golang.org:443` (checksums), `vuln.go.dev:443` (govulncheck DB), so the toolkit's `lint`/`test`/`vuln` reviewers work against non-vendored Go projects under `/claudeshared`. Both allowlists are TLS passthrough (no decryption, no credential injection); the OAuth token transits the Claude allowlist only and the Go binaries cannot reach the Claude hosts (or vice versa). `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` disables telemetry/auto-update so `statsig.anthropic.com`, `sentry.io`, and `downloads.claude.ai` are never contacted.

**Accepted trade-off:** The subscription OAuth token lives inside the sandbox at `~/.claude/.credentials.json` (written by the in-sandbox `claude` OAuth login flow). Mitigations: the `claude` binary's egress is restricted to the three Claude auth/API hosts only and binary-scoped to `claude` (the Go-tooling allowlist is scoped to the Go binaries and cannot reach the token's hosts); the sandbox is deleted between sessions with `./rebuild.sh down`.

### Constraints

- **Platform**: Sandbox runtime must be NVIDIA OpenShell — built/managed via the `openshell` CLI on this host.
- **Build tool**: Container image must be built with podman (`podman build`), not the Docker daemon. The image reference is then handed to `openshell sandbox create --from <image-ref>`.
- **Base image**: Fedora 44 — base for the sandbox image.
- **Network**: Running sandbox allows two binary-scoped allowlists and nothing else. `claude_egress` (scoped to `/usr/bin/claude`, `/usr/local/bin/claude`): `api.anthropic.com:443`, `platform.claude.com:443`, `claude.ai:443`. `go_egress` (scoped to `/usr/bin/go`, `/usr/bin/golangci-lint`, `/usr/local/bin/govulncheck`): `proxy.golang.org:443`, `sum.golang.org:443`, `vuln.go.dev:443` — added in Phase 4 so the toolkit's Go reviewers (`lint`/`test`/`vuln`) can resolve modules + the vuln DB. All six are TLS passthrough. No `statsig.anthropic.com`, no `sentry.io`, no open internet. `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` keeps telemetry/auto-update hosts unused. Claude Code authenticates via in-sandbox subscription OAuth login (no `ANTHROPIC_API_KEY`, no `inference.local` gateway).
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

### Network Policy — Two Binary-Scoped Egress Allowlists (Architecture B)

- Sandbox allows two independently binary-scoped allowlists (all TLS passthrough, proxy never decrypts the stream); everything else denied.
- `claude_egress` — scoped to `/usr/bin/claude` and `/usr/local/bin/claude`:
  - `api.anthropic.com:443` — model inference
  - `platform.claude.com:443` — Console/Claude account authentication (OAuth)
  - `claude.ai:443` — claude.ai account authentication (OAuth)
- `go_egress` — scoped to `/usr/bin/go`, `/usr/bin/golangci-lint`, `/usr/local/bin/govulncheck` (Phase 4 / 04-03 audit enablement):
  - `proxy.golang.org:443` — Go module proxy (go / golangci-lint / go test)
  - `sum.golang.org:443` — Go checksum database (go verifies `go.sum` by default)
  - `vuln.go.dev:443` — govulncheck vulnerability database
  - Enables the toolkit's `lint`/`test`/`vuln` reviewers to run their Go tools against non-vendored projects under `/claudeshared`. The Go binaries cannot reach the Claude hosts and `claude` cannot reach the Go hosts — the OAuth token stays isolated to `claude_egress`.
- Binary-scoping means arbitrary processes cannot use either egress hole
- `statsig.anthropic.com` and `sentry.io` intentionally absent; `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` suppresses those code paths
- All other egress denied (no `curl google.com`, no git clone at runtime, etc.)
- NET-04 asserts both allowlists present, passthrough, and correctly scoped (+ statsig/sentry absent); NET-05 asserts deny posture via `curl` (blocked by binary-scoping); Claude reachability validated by `./rebuild.sh login`
- No `inference.local` gateway, no `ANTHROPIC_API_KEY`, no host-side `openshell provider create`
- Claude Code authenticates via in-sandbox OAuth login: `./rebuild.sh login` → browser URL outside sandbox → paste code

### Zero-Egress Policy (historical note — superseded by Architecture B)

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

- `npm install -g @opengsd/gsd-core@VERSION --before="DATE T23:59:59Z" --ignore-scripts --allow-git=none --allow-remote=none --allow-directory=none` installs the package and pins all transitive deps to versions published on or before the cooldown date. `--before` applies to direct and transitive dependencies (widely supported, works on old and new npm).
- `gsd-core --claude --global` then runs `bin/install.js` which writes the actual Claude Code integration files (commands, hooks, agent definitions) into `~/.claude/`.
- `npx` does not support `--before`. Pinning transitive deps requires `npm install`.
- `--ignore-scripts` is safe for gsd-core 1.4.0 — it has no `install`/`preinstall`/`postinstall` scripts; `prepare` does not run for registry installs; real setup is the explicit `gsd-core --claude --global`.

### npm --before: What It Actually Does

- Rebuilds the entire dependency tree using only versions published on or before the given date
- Applies to **all** transitive dependencies, not just direct dependencies
- If no version exists before the cutoff for a required package, `npm install` errors
- When a dist-tag (like `@latest`) is used, it resolves the most recent version within the date filter
- `--min-release-age=<days>` is the relative equivalent — but is silently ignored by older npm versions (e.g. the version shipped in Fedora 44); always use `--before` for guaranteed compatibility

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

- `npm install -g @anthropic-ai/claude-code@VERSION --before="DATE T23:59:59Z" --allow-scripts @anthropic-ai/claude-code --allow-git=none --allow-remote=none --allow-directory=none` installs claude-code and pins the transitive tree to the cooldown date.
- `--allow-scripts @anthropic-ai/claude-code` is required — claude-code has a first-party `postinstall: node install.cjs` (confirmed on 2.1.169); this permits only its own script and blocks all transitive-dep scripts.
- Explicit `@VERSION` pin is required; the version is pre-resolved by `resolve-versions.sh` via a live npm registry query on the host before the build.
- Claude Code ships frequently (daily releases); without an explicit version pin + `--before`, `@latest` would resolve to a post-cooldown version.
- The native installer at `https://claude.ai/install.sh` (or `npx @anthropic-ai/claude-code`) runs interactively and cannot enforce a transitive date window.
- `npm install -g @anthropic-ai/claude-code@VERSION --before=DATE` is the correct containerized approach (no interactive prompts, reproducible, version pinned before build)

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
| `npm install -g pkg@VERSION --before=DATE` (pre-resolved pin + date fence) | `npm install -g pkg --min-release-age=N` (npm 11 native cooldown) | `--min-release-age` is silently ignored by older npm (e.g. Fedora 44's bundled npm) — installs @latest instead of the cooldown version; `--before` is widely supported and reliable across npm versions |
| `npm install -g pkg@VERSION --before=DATE` | pnpm/yarn date pinning | Neither pnpm nor yarn has an equivalent `--before` that pins transitive deps; yarn resolutions only pin direct deps |
| `npm install -g pkg@VERSION --before=DATE` | Committing `package-lock.json` | Works but is cumbersome for rolling cooldown: requires re-running `npm install --before` and committing a new lockfile each rebuild |
| `npm install -g pkg@VERSION --before=DATE` | Registry time-travel proxy (Verdaccio `--snapshot`) | Verdaccio snapshot support exists but adds operational complexity; npm `--before` is sufficient and built-in |
| `go install pkg@vX.Y.Z` (explicit tag) | `go install pkg@latest` | `@latest` ignores cooldown; always use explicit tag computed from Go proxy timestamps |
| `openshell sandbox create --policy ./policy.yaml` (empty `network_policies`) | `openshell policy update --add-endpoint ...` post-create | Policy must be set at create time for static sections; zero-egress requires empty `network_policies` from the start |
| Podman driver | Docker driver | Gateway config already uses Podman; switching to Docker driver would require config change; both support bind mounts with `enable_bind_mounts` |
| Clone toolkit at image build time | Clone at sandbox start via entrypoint | Sandbox has zero egress at runtime; git clone cannot reach github.com from inside the running sandbox |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `npx @opengsd/gsd-core@latest --claude --global` | `npx` does not support `--before`; `@latest` resolves to whatever is current | `npm install -g @opengsd/gsd-core@VERSION --before=DATE --ignore-scripts ... && gsd-core --claude --global` |
| npm install without `--ignore-scripts` for gsd-core | gsd-core 1.4.0 has no install scripts; omitting the flag relies on npm's implicit warn-and-skip default which may change across npm versions | `--ignore-scripts` (explicit and durable) |
| npm install without `--allow-scripts @anthropic-ai/claude-code` for claude-code | claude-code requires its first-party `postinstall: node install.cjs`; omitting the flag may fail silently if npm defaults change | `--allow-scripts @anthropic-ai/claude-code` (permits only first-party script) |
| npm install without `--allow-git=none --allow-remote=none --allow-directory=none` | These flags default to `all` (permissive); omitting them leaves git-ref, tarball-URL, and local-directory dependency sources allowed — only registry semver ranges are acceptable in a supply-chain-hardened sandbox | Pass `--allow-git=none --allow-remote=none --allow-directory=none` on every npm install |
| `claude --allow-dangerously-skip-permissions` | Prompts the user on each risky action; designed for interactive opt-in not autonomous operation | `claude --dangerously-skip-permissions` |
| `ENV ANTHROPIC_BASE_URL=https://inference.local` in Dockerfile | Architecture B does not use inference.local; setting this ENV would point Claude Code at a non-existent gateway | Omit the ENV — Claude Code uses its built-in default (api.anthropic.com) |
| `protocol: rest` on the api.anthropic.com policy entry | Would terminate TLS and expose the subscription OAuth token to the proxy | Omit `protocol` entirely (TCP passthrough — proxy never decrypts the stream) |
| `openshell provider create --from-existing` | Architecture B has no host-side provider step; credentials live inside the sandbox | `./rebuild.sh login` (in-sandbox OAuth flow: URL in browser outside → paste code) |
| `golangci-lint` via `go install` (from upstream) | Bypasses dnf cooldown mechanism; version not controlled by RPM package manager | `dnf install golangci-lint` in Fedora 44 (provides 2.11.3) |
| Adding `statsig.anthropic.com` or `sentry.io` to network_policies | Expands egress beyond the minimal 3-host Claude allowlist; adds telemetry/error-reporting exfil paths | Keep both absent; `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` prevents contact; if Claude Code is degraded despite this, adding `statsig.anthropic.com:443` is the minimal follow-up |

## Version Compatibility

| Package | Version | Compatible With | Notes |
|---------|---------|-----------------|-------|
| `golang` (RPM) | 1.26.4 (fc44) | `govulncheck@v1.3.0` requires Go 1.25+ (from go.mod) | Go 1.26 satisfies the requirement |
| `golangci-lint` (RPM) | 2.11.3 (fc44) | `golang@1.26` | Upstream golangci-lint 2.x supports Go 1.22+ |
| `@anthropic-ai/claude-code` | 2.1.169 | Node.js 18+ | Fedora 44 nodejs will provide a compatible version |
| `@opengsd/gsd-core` | 1.4.0 | `@anthropic-ai/claude-code@2.1.169` | gsd-core is runtime-agnostic; installs hooks/commands into `~/.claude` |
| OpenShell CLI | 0.0.62 | Podman driver (configured) | `enable_bind_mounts = true` under `[openshell.drivers.podman]` is a REQUIRED host precondition (not auto-configured); `rebuild.sh` verifies it fail-closed before sandbox create (RUN-05 preflight, `scripts/preflight-gateway-bind-mount.sh`) |

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
