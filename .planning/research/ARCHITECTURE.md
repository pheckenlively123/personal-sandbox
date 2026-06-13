# Architecture Research

**Domain:** Reproducible network-isolated container sandbox with brokered inference
**Researched:** 2026-06-13
**Confidence:** HIGH (derived from direct CLI introspection of the running OpenShell v0.0.62 installation, gateway binary symbol analysis, and policy inspection of the live sandbox)

---

## Standard Architecture

### System Overview

```
┌──────────────────────────────────────────────────────────────────┐
│  BUILD TIME  (network allowed — podman build phase)              │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  Dockerfile  (Fedora 44 base)                            │    │
│  │  ─ dnf update -y                  → RPM packages         │    │
│  │  ─ dnf install golang golangci-lint                      │    │
│  │  ─ go install govulncheck@<pinned> → Go module proxy     │    │
│  │  ─ npm install -g @anthropic-ai/claude-code@<pinned>     │    │
│  │  ─ npm install -g gsd-core@<pinned> (+ dep lockfile)     │    │
│  │  ─ git clone claude-engineering-toolkit (latest HEAD)    │    │
│  └──────────────────────────────────────────────────────────┘    │
│                       ↑                                          │
│            rebuild.sh computes cooldown_date (today − 4d)        │
│            resolves pinned versions → writes versions.lock       │
│            passes ARGs into podman build                         │
└──────────────────────────────────────────────────────────────────┘
                              │
                              │  openshell sandbox create --from .
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  RUNTIME  (zero direct internet egress)                          │
│                                                                  │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │  OpenShell Sandbox (podman container)                     │   │
│  │                                                           │   │
│  │  ┌─────────────────────────────────────────────────────┐  │   │
│  │  │  openshell-sandbox (supervisor process)             │  │   │
│  │  │  ─ fetches InferenceBundle from gateway (gRPC mTLS) │  │   │
│  │  │  ─ fetches provider env (ANTHROPIC_API_KEY) via     │  │   │
│  │  │    GetSandboxProviderEnvironment RPC                 │  │   │
│  │  │  ─ acts as local L7 inference proxy for Claude Code │  │   │
│  │  │  ─ enforces Landlock + filesystem policy             │  │   │
│  │  └─────────────────────────────────────────────────────┘  │   │
│  │                                                           │   │
│  │  ┌─────────────────────────────────────────────────────┐  │   │
│  │  │  claude (Claude Code CLI)                           │  │   │
│  │  │  --dangerously-skip-permissions                     │  │   │
│  │  │  --plugin-dir /opt/claude-engineering-toolkit       │  │   │
│  │  │  ANTHROPIC_BASE_URL=<gateway-local-proxy>           │  │   │
│  │  │  ANTHROPIC_API_KEY=<injected by supervisor>         │  │   │
│  │  └─────────────────────────────────────────────────────┘  │   │
│  │                                                           │   │
│  │  /home/sandbox/claudeshared  ← bind mount (rw)           │   │
│  │  /opt/claude-engineering-toolkit (baked in at build)     │   │
│  └───────────────────────────────────────────────────────────┘   │
│                                                                  │
│  Sandbox Network Policy:                                         │
│  ─ Empty endpoint list = deny all direct egress                  │
│  ─ Gateway gRPC socket is NOT a network endpoint; it is an       │
│    in-container Unix socket / gRPC channel the supervisor owns   │
└──────────────────────────────────────────────────────────────────┘
                              │
                       gRPC mTLS (inference proxy)
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  HOST — OpenShell Gateway  (https://127.0.0.1:17670)            │
│                                                                  │
│  ─ Holds ANTHROPIC_API_KEY via attached provider                │
│  ─ Holds inference route config (openshell inference set)        │
│  ─ Proxies /v1/messages → api.anthropic.com on behalf of sandbox │
│  ─ Enforces sandbox network policy (L7 allow/deny rules)         │
│  ─ Stores policy history and draft proposals                     │
│  ─ Manages sandbox lifecycle (create / delete / connect)         │
└──────────────────────────────────────────────────────────────────┘
                              │
                       HTTPS (from host, unrestricted)
                              ▼
                     api.anthropic.com
```

---

### Component Responsibilities

| Component | Responsibility | Implementation |
|-----------|----------------|----------------|
| **Dockerfile** | Define the immutable build-time environment: OS packages, Go toolchain, npm globals, toolkit clone | Fedora 44 base; build args carry pinned versions computed by rebuild.sh |
| **rebuild.sh** | Orchestrate: compute cooldown date, resolve pinned versions, invoke `openshell sandbox create`, apply policy, store lockfile | Bash script on host; runs before every rebuild |
| **versions.lock** | Record the exact versions installed so the build is auditable and re-pinnable | JSON or plaintext written by rebuild.sh before `podman build` |
| **policy.yaml** | Declare the zero-egress network policy for the running sandbox | YAML passed to `openshell sandbox create --policy` or applied post-create with `openshell policy set` |
| **OpenShell gateway** | Broker inference (proxy API calls); hold provider credentials; enforce L7 policy; manage sandbox lifecycle | `openshell-gateway` process on host at `https://127.0.0.1:17670` |
| **openshell-sandbox (supervisor)** | In-container process: fetches InferenceBundle + provider env from gateway, acts as local L7 inference proxy, enforces Landlock | Sidecar to the sandboxed workload; part of the OpenShell supervisor image |
| **Claude Code CLI** | Autonomous AI agent; sends inference requests to local supervisor proxy | `claude --dangerously-skip-permissions --plugin-dir ...` |
| **claude-engineering-toolkit** | Plugin directory baked into the image at build time | Cloned via `git clone` during podman build (no cooldown — operator-controlled fork) |
| **~/claudeshared (host path)** | Shared workspace: operator clones repos here; Claude reads/writes inside sandbox via bind mount | Bind-mounted rw at sandbox create time via `--driver-config-json` |

---

## Recommended Project Structure

```
personal-sandbox/              # repo root
├── Dockerfile                 # Fedora 44 image definition
├── rebuild.sh                 # Orchestration script (the main entrypoint)
├── policy.yaml                # Zero-egress sandbox network policy
├── versions.lock              # Written by rebuild.sh; records pinned versions + dates
└── .planning/                 # GSD project files (not shipped into the image)
    ├── PROJECT.md
    └── research/
```

### Structure Rationale

- **Dockerfile** sits at root so `openshell sandbox create --from .` works without extra flags; the build context is the entire repo directory.
- **rebuild.sh** is the single operator entrypoint — it encapsulates all ordering logic (compute date → resolve → build → create → policy → mount → launch).
- **policy.yaml** is a separate file (not inline in rebuild.sh) so it can be version-controlled, diffed, and passed with `--policy` at create time or updated post-create with `openshell policy set`.
- **versions.lock** is generated output, not hand-edited. It records what was actually installed for reproducibility auditing.

---

## Architectural Patterns

### Pattern 1: Build-time / Runtime Separation

**What:** All package downloads happen during `podman build` (which has unrestricted network). The running sandbox has a zero-egress policy applied after creation. These two concerns are never mixed.

**When to use:** Any time you need reproducible supply-chain isolation without baking credentials or network assumptions into the image.

**Trade-offs:** The image must be rebuilt when package versions change. The rebuild script must be idempotent — `openshell sandbox create` will fail if the name already exists, so rebuild.sh must delete the old sandbox first or use `--no-keep`.

**Example flow:**
```
rebuild.sh
  ├── COOLDOWN_DATE=$(date -v-4d +%Y-%m-%dT%H:%M:%SZ)      # compute rolling window
  ├── resolve_npm_version @anthropic-ai/claude-code $COOLDOWN_DATE
  ├── resolve_npm_version gsd-core $COOLDOWN_DATE
  ├── resolve_go_version golang.org/x/vuln $COOLDOWN_DATE
  ├── write versions.lock
  ├── podman build --build-arg CLAUDE_VERSION=... --build-arg ...
  ├── openshell sandbox delete claude-sandbox --yes 2>/dev/null || true
  ├── openshell sandbox create --from . --name claude-sandbox \
  │       --policy policy.yaml \
  │       --driver-config-json '{"podman":{"mounts":[{"bind":{"source":"/Users/.../claudeshared","target":"/home/sandbox/claudeshared","read_only":false}}]}}' \
  │       --provider anthropic-provider
  └── openshell sandbox exec claude-sandbox -- claude --dangerously-skip-permissions --plugin-dir /opt/claude-engineering-toolkit
```

### Pattern 2: Gateway-Brokered Inference (the zero-egress inference path)

**What:** The sandbox has no direct route to `api.anthropic.com`. Instead, the `openshell-sandbox` supervisor process inside the container fetches an `InferenceBundle` from the gateway over a gRPC mTLS channel. That bundle contains inference routes (provider type, `base_url`, model). The supervisor then acts as a local L7 proxy — it intercepts Claude Code's outbound inference requests and forwards them to the gateway, which proxies them to Anthropic on behalf of the sandbox. Provider credentials (`ANTHROPIC_API_KEY`) are injected into the sandbox environment via the `GetSandboxProviderEnvironment` RPC, not baked into the image.

**When to use:** Required here. This is OpenShell's core security architecture for zero-egress sandboxes.

**Trade-offs:** Inference requires the gateway to be running and the provider to be registered (`openshell provider create` + `openshell sandbox provider attach`) before the sandbox can reach a model. This is a prerequisite that rebuild.sh cannot automate for the first-time setup (credentials must be registered once by the operator).

**Data flow:**
```
Claude Code (in sandbox)
    │  POST /v1/messages  (to local supervisor proxy)
    ▼
openshell-sandbox supervisor (L7 inference proxy, in-container)
    │  gRPC GetInferenceBundle / route request
    ▼
openshell-gateway (host, 127.0.0.1:17670)
    │  HTTPS with ANTHROPIC_API_KEY
    ▼
api.anthropic.com
```

**Key detail from binary analysis:** The supervisor's `inference.rs` module loads routes from the InferenceBundle, intercepts outbound requests matching known inference endpoints, rewrites/proxies them through the gateway channel. `ANTHROPIC_BASE_URL` is set to the supervisor's local proxy address (not the Anthropic API directly), so Claude Code's HTTPS call goes to localhost, never hits the network policy, and the supervisor forwards it.

### Pattern 3: Version Pinning by Cooldown Date

**What:** The rebuild script computes `COOLDOWN_DATE = today − 4 days`. For each package that needs pinning, it queries the package registry's time metadata, filters to versions published before the cooldown date, and takes the maximum semver. This version is passed as a podman build arg and recorded in `versions.lock`.

**When to use:** For govulncheck, gsd-core, and Claude Code CLI. Not for RPM packages (managed by dnf, locked to Fedora 44's snapshot) and not for claude-engineering-toolkit (operator-controlled fork, trusted at latest HEAD).

**Trade-offs:** Adds a network call to the registry at rebuild time (from the host, before the podman build). Requires the host to have curl/python/node available for the resolution script. The Go module proxy does not have a native "list versions before date" query; the approach is to query `proxy.golang.org/golang.org/x/vuln/@v/list` for all versions, then query `/@v/<version>.info` for timestamps and filter — or use the Go sum DB's time metadata.

**npm resolution (registry time API):**
```bash
# Returns all version timestamps; filter to those before COOLDOWN_DATE, take max semver
curl -s https://registry.npmjs.org/@anthropic-ai/claude-code \
  | jq --arg d "$COOLDOWN_DATE" \
      '.time | to_entries | map(select(.value < $d and (.key | test("^[0-9]")))) | max_by(.value) | .key'
```

**Go module resolution:**
```bash
# List versions, fetch .info for each to get timestamp, filter by cooldown date
VERSIONS=$(curl -s "https://proxy.golang.org/golang.org/x/vuln/@v/list")
# For each version: curl -s "https://proxy.golang.org/golang.org/x/vuln/@v/${v}.info" -> .Time field
# Example response: {"Version":"v1.3.0","Time":"2026-04-22T22:03:04Z","Origin":{...}}
```

---

## Data Flow

### Build-time Flow

```
rebuild.sh (host)
    │
    ├─ compute cooldown_date (today − 4d)
    │
    ├─ query npm registry → resolve claude-code version
    ├─ query npm registry → resolve gsd-core version + dep lockfile
    ├─ query Go module proxy → resolve govulncheck version
    │
    ├─ write versions.lock (pinned versions + cooldown_date + timestamps)
    │
    ├─ podman build --build-arg CLAUDE_VERSION=X.Y.Z \
    │              --build-arg GSD_CORE_VERSION=A.B.C \
    │              --build-arg GOVULNCHECK_VERSION=vM.N.O \
    │     (Dockerfile pulls from registries during build — network allowed)
    │
    ├─ openshell sandbox delete <name> || true  (idempotent cleanup)
    │
    ├─ openshell sandbox create --from . --name <name> \
    │       --policy policy.yaml \
    │       --driver-config-json '{"podman":{"mounts":[...]}}' \
    │       --provider <registered-provider-name>
    │
    └─ (optionally) openshell sandbox exec <name> -- claude ...
       OR: operator connects interactively: openshell sandbox connect <name>
```

### Runtime Inference Flow (zero-egress path)

```
[Claude Code inside sandbox]
        │ POST /v1/messages → localhost:<supervisor-proxy-port>
        ▼
[openshell-sandbox supervisor]
    ── fetched InferenceBundle at startup: knows route for anthropic provider
    ── intercepts the request (L7 proxy)
    ── calls gateway gRPC: relay inference request
        │ gRPC mTLS (over agent_socket / TLS tunnel)
        ▼
[openshell-gateway on host, 127.0.0.1:17670]
    ── holds ANTHROPIC_API_KEY (via registered provider, never in image)
    ── makes outbound HTTPS to api.anthropic.com/v1/messages
    ── returns response back through gRPC channel
        │
        ▼
[openshell-sandbox supervisor]
    ── streams response back to Claude Code's HTTP connection
        │
        ▼
[Claude Code] ← response
```

### Host-Bind-Mount Flow (~/claudeshared)

```
Host filesystem: ~/claudeshared/  (read-write)
        │
        │  bind mount via driver-config-json at sandbox create time
        │  requires enable_bind_mounts = true in ~/.config/openshell/gateway.toml
        │  (already configured on this host)
        ▼
Sandbox path: /home/sandbox/claudeshared/  (read-write)
        │
        ▼
Claude Code reads/writes repos here under --dangerously-skip-permissions
```

### Provider Credential Injection Flow

```
Operator (one-time setup, outside rebuild.sh):
    openshell provider create --name anthropic-provider \
        --type anthropic \
        --credential ANTHROPIC_API_KEY=<key>
    openshell inference set --provider anthropic-provider --model claude-opus-4-5

At sandbox create time:
    --provider anthropic-provider  →  gateway attaches provider to sandbox

At sandbox startup (inside container):
    openshell-sandbox supervisor calls GetSandboxProviderEnvironment RPC
    gateway returns: {ANTHROPIC_API_KEY: "<key>", ...}
    supervisor injects into Claude Code's process environment
    (key is never in the image, never in the Dockerfile, never in versions.lock)
```

---

## Component Boundaries

### What Talks to What

| From | To | Channel | Content |
|------|----|---------|---------|
| rebuild.sh | npm registry | HTTPS (host) | Version timestamp queries |
| rebuild.sh | Go module proxy | HTTPS (host) | Module version queries |
| rebuild.sh | podman | podman CLI | Image build (`podman build`) |
| rebuild.sh | openshell-gateway | openshell CLI / gRPC | Create sandbox, attach provider, apply policy |
| openshell-sandbox (in container) | openshell-gateway | gRPC mTLS over agent socket | GetInferenceBundle, GetSandboxProviderEnvironment, policy sync, logs |
| Claude Code (in container) | openshell-sandbox supervisor | localhost HTTP | Inference requests (POST /v1/messages) |
| openshell-gateway | api.anthropic.com | HTTPS (unrestricted, from host) | Proxied inference requests |
| Claude Code (in container) | /home/sandbox/claudeshared | local filesystem | Repo reads/writes via bind mount |

### What Does NOT Cross the Sandbox Network Boundary

- Claude Code never makes a direct outbound TLS connection to api.anthropic.com
- The sandbox policy (policy.yaml) has an empty endpoint list → deny all direct egress
- dnf, go install, npm install, git clone all ran during build, not at runtime

---

## Suggested Build Order

The dependency graph between components determines this ordering:

```
1. PREREQUISITES (one-time, manual — not automated by rebuild.sh)
   └── openshell provider create --name anthropic-provider --type anthropic ...
   └── openshell inference set --provider anthropic-provider --model <model>
   (These register credentials in the gateway database; persist across rebuilds)

2. COOLDOWN DATE RESOLUTION (rebuild.sh, step 1)
   └── Compute COOLDOWN_DATE = today − 4 days
   └── Query registries and write versions.lock
   (Must happen before podman build so build args are ready)

3. PODMAN BUILD (rebuild.sh, step 2)
   └── Depends on: versions.lock (provides pinned build args)
   └── Depends on: network access (dnf, go install, npm, git clone)
   └── Output: local podman image tagged for openshell sandbox create

4. SANDBOX DELETE (rebuild.sh, step 3, idempotent)
   └── openshell sandbox delete <name> --yes 2>/dev/null || true
   (Must happen before create to avoid "sandbox already exists" error)

5. SANDBOX CREATE (rebuild.sh, step 4)
   └── Depends on: podman image (step 3)
   └── Depends on: registered provider (step 1)
   └── Depends on: enable_bind_mounts = true in gateway.toml (pre-configured)
   └── openshell sandbox create --from <image-ref> --name <name> --policy policy.yaml \
           --driver-config-json <bind-mount-spec> \
           --provider anthropic-provider
   (Creates sandbox from the podman-built image reference, attaches provider, applies policy.
    NOTE: build-phase plan must confirm OpenShell resolves a podman-built image; do NOT use
    --from . which would trigger an OpenShell-managed Docker-daemon build)

6. LAUNCH (rebuild.sh, step 5 — or operator-initiated)
   └── Depends on: sandbox in Ready phase (step 5)
   └── openshell sandbox exec <name> -- claude --dangerously-skip-permissions \
           --plugin-dir /opt/claude-engineering-toolkit
   OR: openshell sandbox connect <name> (interactive shell)
```

**Critical ordering constraint:** Provider registration (step 1) must happen before sandbox create (step 5) or the `--provider` flag will fail. Because provider registration involves interactive credential input, it cannot be fully automated in rebuild.sh for first-time setup. rebuild.sh should guard with `openshell provider get anthropic-provider` and fail fast with a helpful message if the provider is not registered.

---

## Integration Points

### External Services

| Service | Phase | Integration | Notes |
|---------|-------|-------------|-------|
| npm registry (registry.npmjs.org) | Build (host) | HTTPS REST, time metadata | Used for cooldown version resolution; no auth needed for public packages |
| Go module proxy (proxy.golang.org) | Build (host) | HTTPS REST, `/@v/<version>.info` | Used for govulncheck version resolution; timestamp in `Time` field of `.info` response |
| podman (Rancher Desktop) | Build | `podman build` → `openshell sandbox create --from <image-ref>` | rebuild.sh builds the image with podman; OpenShell creates the sandbox from the image reference |
| api.anthropic.com | Runtime (via gateway only) | HTTPS/REST proxied by gateway | Never reached directly by the sandbox |
| github.com | Build only | git clone | For claude-engineering-toolkit; no cooldown, latest HEAD |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| rebuild.sh ↔ openshell CLI | CLI subprocess | rebuild.sh shells out to `openshell` commands |
| Sandbox ↔ gateway | gRPC mTLS over agent socket | The supervisor connects to the gateway at startup; this is a privileged channel distinct from the sandbox's user-space network |
| Claude Code ↔ supervisor | localhost HTTP | Supervisor binds a local port inside the container and acts as L7 inference proxy |
| Gateway ↔ Anthropic API | HTTPS from host | The gateway runs on the host and has unrestricted outbound access |
| ~/claudeshared ↔ sandbox | podman bind mount | Declared in `--driver-config-json`; requires `enable_bind_mounts = true` in gateway.toml (already set) |

---

## Anti-Patterns

### Anti-Pattern 1: Baking ANTHROPIC_API_KEY into the Dockerfile

**What people do:** `ENV ANTHROPIC_API_KEY=sk-ant-...` or `ARG ANTHROPIC_API_KEY` in the Dockerfile.

**Why it's wrong:** The key ends up in the image layers, is visible in `podman history`, and is leaked if the image is ever pushed or inspected. OpenShell's provider mechanism exists specifically to avoid this.

**Do this instead:** Register the provider once with `openshell provider create` and attach it with `--provider` at sandbox create time. The gateway injects the key at runtime via `GetSandboxProviderEnvironment`.

### Anti-Pattern 2: Adding api.anthropic.com to the Sandbox Policy

**What people do:** `openshell policy update --add-endpoint api.anthropic.com:443:read-write:rest:enforce` because inference isn't working.

**Why it's wrong:** This defeats the zero-egress guarantee. Claude Code running with `--dangerously-skip-permissions` could then exfiltrate data, push to remote systems, or make arbitrary API calls to Anthropic's platform.

**Do this instead:** Use the gateway inference route. Configure `openshell inference set --provider <name> --model <model>`. The supervisor's L7 proxy handles the path from inside the sandbox to the gateway without any direct egress endpoint being allowed.

### Anti-Pattern 3: Pinning at Build Time via ARG Without Recording the Lock

**What people do:** Compute the cooldown version inside the Dockerfile (e.g., with a `RUN` command that queries npm) or hardcode specific versions.

**Why it's wrong:** Computing inside the Dockerfile means the resolved version is buried in layer history and invisible in the repo. Hardcoding means rebuilds don't roll the window — the whole point of the rolling cooldown is that each rebuild re-pins to "4 days before today", not a static date.

**Do this instead:** Compute versions in rebuild.sh before `podman build`. Write them to versions.lock (committed or at least archived). Pass as `--build-arg` so they appear in the build's argument record and can be reproduced.

### Anti-Pattern 4: Using --upload Instead of Bind Mount for ~/claudeshared

**What people do:** `openshell sandbox create --upload ~/claudeshared:/home/sandbox/claudeshared` to sync files.

**Why it's wrong:** `--upload` is a one-time file copy at sandbox create. Changes made by Claude inside the sandbox are not reflected on the host, and vice versa. The repo is effectively a snapshot.

**Do this instead:** Use the bind mount via `--driver-config-json '{"podman":{"mounts":[{"bind":{"source":"<host-path>","target":"<sandbox-path>","read_only":false}}]}}'`. This requires `enable_bind_mounts = true` in `~/.config/openshell/gateway.toml` (already configured on this host per the existing gateway.toml).

### Anti-Pattern 5: Applying the Zero-Egress Policy as a Global Policy

**What people do:** `openshell policy set --global --policy zero-egress.yaml` to ensure all sandboxes are isolated.

**Why it's wrong:** The global policy locks all sandboxes on this gateway, including any other sandboxes used for non-Claude purposes. The global policy also overrides sandbox-level policies.

**Do this instead:** Apply the policy per-sandbox via `--policy policy.yaml` at `sandbox create` time. This scopes isolation to the Claude sandbox only.

---

## Scaling Considerations

This is a single-operator local tool, not a multi-user service. Scaling concerns are instead durability and repeatability concerns:

| Concern | Approach |
|---------|----------|
| Rebuilding after OS update | rebuild.sh handles idempotently: delete old sandbox, rebuild image, recreate |
| Cooldown date drift | rebuild.sh recomputes rolling window each run; no manual version bumps needed |
| Plugin updates | git clone at build time pulls latest toolkit HEAD; just rebuild to update |
| New Claude Code versions | Automatic on each rebuild (cooldown resolution re-queries npm) |
| Provider credential rotation | `openshell provider update` or `openshell provider rotate-credential`; does not require rebuild |
| Gateway version upgrade | Homebrew upgrade; does not affect the sandbox image |

---

## Sources

- Direct CLI introspection: `openshell --help`, `openshell sandbox create --help`, `openshell policy --help`, `openshell inference --help`, `openshell gateway --help`, `openshell provider list-profiles --output json` (all on v0.0.62)
- Binary symbol analysis: `strings /opt/homebrew/bin/openshell-gateway` — revealed `PodmanSandboxDriverConfig`, `PodmanDriverMountConfig::Bind{source,target,read_only}`, provider env injection RPC names, inference bundle fetch and L7 proxy logic
- Binary symbol analysis: `strings .../openshell-sandbox` — confirmed supervisor calls `GetInferenceBundle`, `GetSandboxProviderEnvironment`, acts as local L7 inference proxy (`inference.rs` module)
- Live gateway config: `~/.config/openshell/gateway.toml` — confirmed `enable_bind_mounts = true` under `[openshell.drivers.podman]` with bind-mount rationale comment
- Live gateway state: `openshell gateway list`, `openshell status`, `openshell policy get go-dev --full` — confirmed gateway at `https://127.0.0.1:17670`, podman driver, policy YAML structure
- npm registry time API: `https://registry.npmjs.org/@anthropic-ai/claude-code` — confirmed `time` object maps version → ISO8601 timestamp, usable for cooldown resolution
- Go module proxy: `https://proxy.golang.org/golang.org/x/vuln/@v/v1.3.0.info` — confirmed `{"Version":"v1.3.0","Time":"2026-04-22T22:03:04Z",...}` format
- PROJECT.md: requirements, constraints, key decisions for this project

---
*Architecture research for: Claude Sandbox (Fedora 44 / OpenShell)*
*Researched: 2026-06-13*
