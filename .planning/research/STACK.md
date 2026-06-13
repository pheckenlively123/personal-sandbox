# Stack Research

**Domain:** Network-isolated Claude Code sandbox (NVIDIA OpenShell / Fedora 44)
**Researched:** 2026-06-13
**Cooldown date:** 2026-06-09 (build date 2026-06-13 minus 4 days)
**Confidence:** HIGH — all CLI flags verified against live `openshell --help` output; all version pins verified against live npm and Go module proxy registry queries; all mount/inference docs fetched from the live OpenShell GitHub repo.

---

## 1. NVIDIA OpenShell CLI

**Version installed:** 0.0.62 (Homebrew tap `nvidia/homebrew-openshell`)
**Binaries:** `/opt/homebrew/bin/openshell`, `/opt/homebrew/bin/openshell-gateway`

### How `sandbox create --from` works

```
openshell sandbox create --from <source> [flags] [-- <command>...]
```

`--from` accepts four forms (verified from `openshell sandbox create --help`):

| Form | Resolution |
|------|-----------|
| Bare name (e.g. `base`, `ollama`) | `ghcr.io/nvidia/openshell-community/sandboxes/<name>:latest` |
| Local directory path (e.g. `./my-sandbox-dir`) | Builds Dockerfile in that directory into the local Docker daemon, then creates sandbox |
| Explicit Dockerfile path | Builds that Dockerfile into the local Docker daemon |
| Full container image reference (e.g. `registry.io/img:tag`) | Pulls the image directly |

**For a local build:** the gateway must be a local gateway (the CLI builds through the local Docker daemon). Building from a Dockerfile requires Docker; the local gateway is Podman-backed but the build step uses Docker. Concretely:

```bash
openshell sandbox create \
  --name claude-sandbox \
  --from ./sandbox \
  -- bash
```

The `sandbox/` directory must contain a `Dockerfile`. OpenShell builds it (`docker build`), creates a gateway-managed sandbox from the result, and starts the command inside it.

**Command placement:** the command to run goes after `--`, e.g. `-- claude`. If omitted, an interactive shell is launched.

### Host Directory Mounts (`~/claudeshared`)

Host bind mounts require two things, both confirmed from live docs (`sandbox-compute-drivers.mdx`):

**1. Gateway config (one-time, already set in `~/.config/openshell/gateway.toml`):**

```toml
[openshell.drivers.podman]
enable_bind_mounts = true
```

This is already enabled in the operator's gateway.toml. The gateway uses the Podman driver on this machine.

**2. Per-sandbox `--driver-config-json` at create time:**

```bash
openshell sandbox create \
  --name claude-sandbox \
  --from ./sandbox \
  --driver-config-json '{"podman":{"mounts":[{"type":"bind","source":"/Users/<user>/claudeshared","target":"/claudeshared","read_only":false}]}}' \
  -- claude
```

Podman mount schema for bind mounts:

| Field | Value |
|-------|-------|
| `type` | `bind` |
| `source` | Absolute host path (e.g. `/Users/patrickheckenlively/claudeshared`) |
| `target` | Path inside sandbox (e.g. `/claudeshared`) |
| `read_only` | `false` for read-write |

**Important constraints:**
- `source` must be an absolute path, not `~`-prefixed. Expand `$HOME` in the build/run script.
- OpenShell rejects mount targets that overlap with `/etc/openshell`, `/etc/openshell-tls`, workspace root, or supervisor paths.
- Named volumes (`type: volume`) do NOT require `enable_bind_mounts = true` unless the named volume itself is bind-backed.

**Alternative (named volume):** Create a Podman named volume backed by the host path and mount as `type: volume`. This avoids `enable_bind_mounts` but adds setup steps. For this project, bind mount is preferred since `enable_bind_mounts` is already set.

### Gateway Inference Brokering (`inference.local`)

Verified from `inference-routing.mdx` in the OpenShell repo.

**How it works:** Every sandbox has access to `https://inference.local` — a sandbox-local HTTPS endpoint managed by the OpenShell privacy router. The router:
- Strips any `Authorization` / `ANTHROPIC_API_KEY` the sandbox provides (they are never forwarded)
- Injects the real backend credentials from the configured provider record
- Rewrites the model to the gateway-configured model
- Forwards to the upstream Anthropic (or other) endpoint

**To use from Claude Code inside the sandbox:**

```bash
ANTHROPIC_BASE_URL="https://inference.local" \
ANTHROPIC_API_KEY=unused \
claude --dangerously-skip-permissions --plugin-dir /toolkit
```

**Critical URL note:** Claude Code appends `/v1/messages` to `ANTHROPIC_BASE_URL`. Set the URL to `https://inference.local` (without `/v1`). The full upstream path becomes `https://inference.local/v1/messages`, which matches the Anthropic-compatible pattern.

**Why `ANTHROPIC_API_KEY=unused`:** The proxy strips it; this placeholder satisfies the SDK's requirement for a non-empty key value.

**`--bare` vs `--dangerously-skip-permissions`:** Use `--dangerously-skip-permissions` for elevated autonomous operation. `--bare` is mentioned in the OpenShell docs for skipping OAuth, but the project requirement is `--dangerously-skip-permissions`, not bare mode.

**Gateway setup (host-side, one-time):**

```bash
# Register local gateway (already done on this machine):
openshell gateway add https://127.0.0.1:17670 --local --name openshell

# Configure inference provider (Anthropic example):
openshell provider create --name anthropic-prod --type anthropic --from-existing
# ^ reads ANTHROPIC_API_KEY from host environment

# Point inference.local at the provider:
openshell inference set --provider anthropic-prod --model claude-opus-4-5
```

### Zero-Egress Policy

**From the docs:** "If no endpoint matches, the connection is denied." An empty `network_policies` section means all outbound connections from the sandbox are denied. `inference.local` is exempt from `network_policies` — it is always routed through the gateway regardless of policy.

Minimal zero-egress policy YAML (pass via `--policy` at `sandbox create`):

```yaml
version: 1

filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /proc, /dev/urandom, /etc, /var/log]
  read_write: [/sandbox, /tmp, /dev/null, /claudeshared]

landlock:
  compatibility: best_effort

process:
  run_as_user: sandbox
  run_as_group: sandbox

network_policies: {}
```

Empty `network_policies: {}` = deny all direct outbound. `inference.local` still works because it is handled separately by the gateway proxy, not by `network_policies`.

**Policy YAML is passed at create time (static sections locked):**

```bash
openshell sandbox create \
  --policy ./sandbox/policy.yaml \
  --from ./sandbox \
  --driver-config-json '...' \
  -- claude
```

**Dynamic updates (hot-reload) while sandbox runs:**

```bash
openshell policy update <sandbox-name> \
  --add-endpoint api.github.com:443:read-only:rest:enforce \
  --binary /usr/local/bin/claude \
  --wait
```

---

## 2. Fedora 44 Base Image

**Image reference:** `fedora:44`
**Registry:** Docker Hub (`docker.io/library/fedora:44`)
**Architectures:** linux/amd64, linux/arm64/v8 (confirmed from Docker Hub, last pushed 2026-05-28)
**Size:** ~66 MB (amd64), ~63 MB (arm64)

**Dockerfile `FROM` line:**

```dockerfile
FROM fedora:44
```

**Package manager:** `dnf` (same as Fedora 39–43; `dnf5` is the default in F38+ but `dnf` alias works)

### RPM Packages

```dockerfile
RUN dnf update -y && \
    dnf install -y \
        golang \
        golangci-lint \
        nodejs \
        npm \
        git \
        ca-certificates \
    && dnf clean all
```

| Package | Fedora 44 version (from Koji) | Notes |
|---------|-------------------------------|-------|
| `golang` | 1.26.4-2.fc44 | Standard Go toolchain; installs to `/usr/bin/go`, sets `GOPATH` |
| `golangci-lint` | 2.11.3-1.fc44 | Confirmed in Koji (`f44` + `f44-updates-testing` tags) |
| `nodejs` | Available in F44 | Provides Node.js for npm-based installs |
| `npm` | Bundled with nodejs | npm 11 expected (matches host) |
| `git` | Standard | Required for cloning toolkit repo |
| `ca-certificates` | Standard | Required for HTTPS in container |

**Do NOT use `dnf install golang-x-vuln` for govulncheck** — that Fedora sub-package path returns 404 from the packages API and govulncheck is installed via `go install` with version pinning instead (see section 3).

---

## 3. govulncheck via `go install`

**Module path:** `golang.org/x/vuln/cmd/govulncheck`
**Go proxy:** `https://proxy.golang.org/`

### Version Selection (Rolling Cooldown)

All versions with publish dates (verified against `https://proxy.golang.org/golang.org/x/vuln/@v/<tag>.info`):

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

**Latest version before cooldown date 2026-06-09:** `v1.3.0` (published 2026-04-22)

### How to Determine the Version in a Build Script

Query the Go module proxy at build time:

```bash
COOLDOWN_DATE=$(date -d "-4 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                date -v-4d +%Y-%m-%dT%H:%M:%SZ)  # macOS fallback

# List all versions, fetch timestamps, pick latest before cutoff
GOVULNCHECK_VERSION=$(
  curl -s https://proxy.golang.org/golang.org/x/vuln/@v/list |
  tr '\n' '\0' |
  xargs -0 -I{} sh -c '
    info=$(curl -s "https://proxy.golang.org/golang.org/x/vuln/@v/{}.info")
    ts=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin)[\"Time\"])")
    echo "$ts {}"
  ' |
  awk -v cutoff="$COOLDOWN_DATE" '$1 < cutoff {print $1, $2}' |
  sort | tail -1 | awk '{print $2}'
)
```

For the Dockerfile itself (where the cooldown date is fixed at build time), pin the version explicitly:

```dockerfile
ARG GOVULNCHECK_VERSION=v1.3.0

RUN go install golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}
```

Pass `GOVULNCHECK_VERSION` as a `--build-arg` from the rebuild script, which computes it at invocation time using the registry query above.

**Why `go install` (not dnf):** Fedora does not package `golang-x-vuln`'s govulncheck binary separately. The `go install` path lets us pin to an exact version with supply-chain cooldown control. `go install` with an explicit version tag produces a reproducible build.

---

## 4. gsd-core Install

**Package:** `@opengsd/gsd-core`
**Registry:** npm (`https://registry.npmjs.org/`)

### Version Selection (Rolling Cooldown)

Versions queried from `https://registry.npmjs.org/@opengsd/gsd-core` (time field):

| Version | Published |
|---------|-----------|
| 1.2.0 | 2026-05-31 |
| 1.3.0 | 2026-06-04 |
| 1.3.1 | 2026-06-04 |
| 1.4.0-rc.1 | 2026-06-07 |
| 1.4.0-rc.2 | 2026-06-08 |
| 1.4.0 | 2026-06-08T18:34:56Z |
| 1.4.1 | 2026-06-09T04:09:36Z (AFTER cutoff) |

**Latest stable version before cooldown date 2026-06-09T00:00:00Z:** `1.4.0` (published 2026-06-08T18:34:56Z)

### gsd-core Dependencies (for cooldown analysis)

`@opengsd/gsd-core@1.4.0` has only 2 runtime dependencies:

| Package | Version range | Latest before cooldown |
|---------|---------------|------------------------|
| `ws` | `8.20.1` (exact pin) | `8.21.0` (2026-05-22) |
| `@anthropic-ai/claude-agent-sdk` | `^0.2.84` | `0.3.169` (2026-06-08T18:11:18Z) |

Both transitive dependencies have versions published before the cooldown date; `npm --before` will resolve them correctly.

### Install Mechanism

gsd-core ships two binaries:
- `gsd-core` → `bin/install.js` (the interactive installer)
- `gsd-tools` → `gsd-core/bin/gsd-tools.cjs` (runtime CLI used by agents)

The installer (`bin/install.js`) reads `--claude`, `--global`, `--local` flags from `process.argv`. It writes hooks, commands, and agent files into `~/.claude/` (for `--global --claude`).

**Correct Dockerfile install chain with cooldown pinning:**

```dockerfile
ARG GSD_CORE_VERSION=1.4.0
ARG COOLDOWN_DATE=2026-06-09

# Step 1: Install the package and all transitive deps pinned to versions before cutoff
RUN npm install -g @opengsd/gsd-core@${GSD_CORE_VERSION} --before=${COOLDOWN_DATE}

# Step 2: Run the installer to deploy hooks/commands into ~/.claude
RUN gsd-core --claude --global
```

**Why split into two steps:**
- `npm install -g @opengsd/gsd-core@VERSION --before=DATE` installs the package and pins all transitive deps to versions released before `DATE`. The `--before` flag applies to direct and transitive dependencies (verified against npm v11 docs).
- `gsd-core --claude --global` then runs `bin/install.js` which writes the actual Claude Code integration files (commands, hooks, agent definitions) into `~/.claude/`.

**Why NOT `npx @opengsd/gsd-core@latest --claude --global`:**
- `npx` does not support `--before` or `--min-release-age`. Pinning transitive deps requires `npm install`.
- Using `@latest` without `--before` would resolve to the current latest (1.4.5 as of 2026-06-13), which postdates the cooldown.

### npm --before: What It Actually Does

`npm --before=<ISO8601-date>` (supported in npm v10+, present in npm v11 on this host):
- Rebuilds the entire dependency tree using only versions published on or before the given date
- Applies to **all** transitive dependencies, not just direct dependencies
- If no version exists before the cutoff for a required package, `npm install` errors
- When a dist-tag (like `@latest`) is used, it resolves the most recent version within the date filter
- `--min-release-age=<days>` is the relative equivalent (e.g. `--min-release-age=4`)

**DO NOT** attempt to use yarn or pnpm date-pinning as an alternative — neither has an equivalent to `--before` that applies to transitive deps. Lockfile-based reproducibility (committing `package-lock.json`) is an alternative but requires re-running the resolver each rebuild. The `--before` approach is preferred for rolling cooldown rebuilds.

---

## 5. Claude Code CLI

**Package:** `@anthropic-ai/claude-code`
**Registry:** npm (`https://registry.npmjs.org/`)

### Version Selection (Rolling Cooldown)

Queried from npm registry time field (439 total versions as of 2026-06-13):

**Current dist-tags:**
- `latest`: 2.1.177 (published 2026-06-13)
- `stable`: 2.1.153 (published 2026-05-27)
- `next`: 2.1.177

**Last 5 versions before cooldown date 2026-06-09T00:00:00Z:**

| Version | Published |
|---------|-----------|
| 2.1.165 | 2026-06-05T05:22:42Z |
| 2.1.166 | 2026-06-05T19:01:59Z |
| 2.1.167 | 2026-06-06T01:18:42Z |
| 2.1.168 | 2026-06-06T23:32:52Z |
| 2.1.169 | 2026-06-08T18:11:20Z |

**Latest version before cooldown date 2026-06-09:** `2.1.169` (published 2026-06-08T18:11:20Z)

### Install Command in Dockerfile

```dockerfile
ARG CLAUDE_CODE_VERSION=2.1.169
ARG COOLDOWN_DATE=2026-06-09

RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} --before=${COOLDOWN_DATE}
```

**Why pin by explicit version AND use `--before`:**
- Explicit version pin ensures the correct top-level package is installed
- `--before` ensures all transitive dependencies are also pinned to pre-cooldown versions
- Claude Code ships frequently (daily releases); without pinning, `@latest` would pull 2.1.177

**Why NOT the native installer (`claude-code` native install script):**
- The native installer at `https://claude.ai/install.sh` (or the npm installer triggered by `npx @anthropic-ai/claude-code`) runs interactively and cannot be version-pinned at the transitive dependency level
- `npm install -g @anthropic-ai/claude-code@VERSION` is the correct containerized approach (no interactive prompts, reproducible)

### Runtime Configuration

Inside the sandbox, Claude Code is launched with:

```bash
ANTHROPIC_BASE_URL="https://inference.local" \
ANTHROPIC_API_KEY=unused \
claude \
  --dangerously-skip-permissions \
  --plugin-dir /toolkit
```

Where `/toolkit` is the cloned `claude-engineering-toolkit` repo (see section 6).

---

## 6. Plugin Loading (`--plugin-dir`)

**Flag:** `claude --plugin-dir <path>` (verified from `claude --help`)

From the help text:
```
--plugin-dir <path>   Load a plugin from a directory or .zip
                      for this session only (repeatable:
                      --plugin-dir A --plugin-dir B.zip)
                      (default: [])
```

**How it works:** `--plugin-dir` loads agents and skills from a directory for the current session. The flag is repeatable. Passing a directory of a cloned plugin repo makes all agents and slash commands in that repo available.

**For the toolkit:**

```dockerfile
# Clone the toolkit during image build
RUN git clone \
    https://github.com/pheckenlWork/claude-engineering-toolkit.git \
    /toolkit
```

Then at runtime:

```bash
claude --dangerously-skip-permissions --plugin-dir /toolkit
```

**Why clone at build time (not runtime):** The container has zero egress at runtime. The git clone must happen during the Docker build phase, which has network access. Cloning at HEAD (no cooldown) is intentional — the operator maintains the fork.

**Note on `--plugin-url`:** Claude also supports `--plugin-url <url>` to fetch a `.zip` plugin at startup, but this requires network egress at runtime, which is blocked by the zero-egress policy.

---

## Summary: Complete Dockerfile Pattern

```dockerfile
FROM fedora:44

# Build args (computed by rebuild script from rolling cooldown)
ARG COOLDOWN_DATE=2026-06-09
ARG GOVULNCHECK_VERSION=v1.3.0
ARG GSD_CORE_VERSION=1.4.0
ARG CLAUDE_CODE_VERSION=2.1.169

# 1. System packages
RUN dnf update -y && \
    dnf install -y \
        golang \
        golangci-lint \
        nodejs \
        npm \
        git \
        ca-certificates \
    && dnf clean all

# 2. govulncheck (pinned, via go install)
ENV GOPATH=/usr/local/go
RUN go install golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}

# 3. gsd-core (pinned, with transitive dep pinning)
RUN npm install -g @opengsd/gsd-core@${GSD_CORE_VERSION} --before=${COOLDOWN_DATE} && \
    gsd-core --claude --global

# 4. Claude Code CLI (pinned, with transitive dep pinning)
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} --before=${COOLDOWN_DATE}

# 5. Plugin toolkit (latest HEAD, no cooldown — operator trusts the fork)
RUN git clone \
    https://github.com/pheckenlWork/claude-engineering-toolkit.git \
    /toolkit

# Entry point — override ANTHROPIC_BASE_URL at runtime or in CMD
CMD ["claude", "--dangerously-skip-permissions", "--plugin-dir", "/toolkit"]
```

**Build invocation (from rebuild script):**

```bash
#!/usr/bin/env bash
set -euo pipefail

BUILD_DATE=$(date +%Y-%m-%d)
COOLDOWN_DATE=$(date -d "-4 days" +%Y-%m-%d 2>/dev/null || date -v-4d +%Y-%m-%d)

# Query cooldown versions from registries
GOVULNCHECK_VERSION=$(
  # ... query proxy.golang.org as described in section 3
)
GSD_CORE_VERSION=$(
  curl -s https://registry.npmjs.org/@opengsd/gsd-core |
  python3 -c "
import json,sys
data=json.load(sys.stdin)
times=data['time']
cutoff='${COOLDOWN_DATE}T23:59:59'
eligible=sorted([(v,t) for v,t in times.items() if v not in ('created','modified') and t<cutoff and 'rc' not in v], key=lambda x:x[1])
print(eligible[-1][0])
  "
)
CLAUDE_CODE_VERSION=$(
  curl -s https://registry.npmjs.org/@anthropic-ai/claude-code |
  python3 -c "
import json,sys
data=json.load(sys.stdin)
times=data['time']
cutoff='${COOLDOWN_DATE}T23:59:59'
eligible=sorted([(v,t) for v,t in times.items() if v not in ('created','modified') and t<cutoff], key=lambda x:x[1])
print(eligible[-1][0])
  "
)

docker build \
  --build-arg COOLDOWN_DATE="${COOLDOWN_DATE}" \
  --build-arg GOVULNCHECK_VERSION="${GOVULNCHECK_VERSION}" \
  --build-arg GSD_CORE_VERSION="${GSD_CORE_VERSION}" \
  --build-arg CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION}" \
  -t claude-sandbox:${BUILD_DATE} \
  ./sandbox

openshell sandbox create \
  --name claude-sandbox \
  --from ./sandbox \
  --policy ./sandbox/policy.yaml \
  --driver-config-json "{\"podman\":{\"mounts\":[{\"type\":\"bind\",\"source\":\"${HOME}/claudeshared\",\"target\":\"/claudeshared\",\"read_only\":false}]}}" \
  -- bash -c 'ANTHROPIC_BASE_URL=https://inference.local ANTHROPIC_API_KEY=unused claude --dangerously-skip-permissions --plugin-dir /toolkit'
```

---

## Alternatives Considered

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
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
| `npx @opengsd/gsd-core@latest --claude --global` without version pin | `npx` does not support `--before`; `@latest` resolves to post-cooldown version | `npm install -g @opengsd/gsd-core@1.4.0 --before=2026-06-09 && gsd-core --claude --global` |
| `claude --allow-dangerously-skip-permissions` | Prompts the user on each risky action; designed for interactive opt-in not autonomous operation | `claude --dangerously-skip-permissions` |
| `ANTHROPIC_BASE_URL=https://inference.local/v1` | Claude Code appends `/v1/messages`; adding `/v1` in the base URL creates `/v1/v1/messages` (double path) | `ANTHROPIC_BASE_URL=https://inference.local` (no trailing `/v1`) |
| `--from-existing` provider flag in Dockerfile | Reads from host keychain/environment, not available inside container build | Set credentials via `openshell provider create` on the host before sandbox creation |
| `golangci-lint` via `go install` (from upstream) | Bypasses dnf cooldown mechanism; version not controlled by RPM package manager | `dnf install golangci-lint` in Fedora 44 (provides 2.11.3) |
| `openshell policy update --add-endpoint api.anthropic.com:443` | Defeats zero-egress guarantee; opens direct path to Anthropic bypassing inference.local privacy routing | Use `inference.local` via gateway; no direct egress allowlist needed |

---

## Version Compatibility

| Package | Version | Compatible With | Notes |
|---------|---------|-----------------|-------|
| `golang` (RPM) | 1.26.4 (fc44) | `govulncheck@v1.3.0` requires Go 1.25+ (from go.mod) | Go 1.26 satisfies the requirement |
| `golangci-lint` (RPM) | 2.11.3 (fc44) | `golang@1.26` | Upstream golangci-lint 2.x supports Go 1.22+ |
| `@anthropic-ai/claude-code` | 2.1.169 | Node.js 18+ | Fedora 44 nodejs will provide a compatible version |
| `@opengsd/gsd-core` | 1.4.0 | `@anthropic-ai/claude-code@2.1.169` | gsd-core is runtime-agnostic; installs hooks/commands into `~/.claude` |
| OpenShell CLI | 0.0.62 | Podman driver (configured) | `enable_bind_mounts = true` already set |

---

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

---
*Stack research for: Network-isolated Claude Code sandbox (NVIDIA OpenShell / Fedora 44)*
*Researched: 2026-06-13*
*Cooldown date: 2026-06-09 (build date minus 4 days)*
