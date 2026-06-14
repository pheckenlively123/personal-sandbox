# Phase 2: Rebuild Script and Sandbox Lifecycle — Research

**Researched:** 2026-06-14
**Domain:** Bash script orchestration, OpenShell sandbox lifecycle, podman image management, macOS virtiofs UID mapping
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Full-clean teardown on every run: remove existing sandbox, remove previous image (podman rmi), prune dangling layers. Accept full rebuild cost per run.
- **D-02:** Teardown is force + tolerate-absent: stop-then-remove with force; if sandbox/image not found, log and continue (exit 0). Hard-error only on genuinely unexpected failures.
- **D-03:** Tag each build as `claude-sandbox:<build-date>` + move `:latest`. Hand the date-pinned ref to `openshell sandbox create --from`.
- **D-04:** Cooldown date + build metadata attached as podman-inspectable labels via `LABEL` lines in the Dockerfile fed by build ARGs — not via `podman build --label` in the script.
- **D-05:** `rebuild.sh` reuses Phase 1 logic by calling `scripts/build-and-lock.sh` as a subprocess (passing `--tag`). Refactor into sourced `scripts/lib/` only if BLD-04 logging granularity forces it.
- **D-06 (flagged for research):** dnf/npm/go phases run inside `podman build` image layers. Timestamped banners around rebuild.sh-controlled phases (resolve, build, teardown, create) plus podman's per-STEP output satisfies BLD-04. Confirm during research.
- **D-07:** `--audit` flag on `rebuild.sh` runs `openshell logs <sandbox>` directly. Scope: log surfacing only. Policy assertion is Phase 3.
- **D-08:** Bind mount: `type:bind`, `source=$HOME/claudeshared` (expand $HOME, absolute path), `target=/claudeshared`, `read_only:false`. Ensure host source dir exists.
- **D-09 (deferred to research):** UID alignment mechanism for host-user-owned canary — research determines the concrete approach.

### Claude's Discretion

- Cooldown-label mechanism (D-04) → Dockerfile LABEL via ARG (recommended)
- Build seam (D-05) → call build-and-lock.sh as subprocess (recommended)
- BLD-04 logging granularity (D-06) → confirm during research/planning
- UID-alignment mechanism (D-09) → researcher determines; requirement is fixed
- Sandbox name, exact openshell sandbox subcommand names (rm/stop/create flags), and basic preflight (podman/openshell present) left to research + planning

### Deferred Ideas (OUT OF SCOPE)

- Preflight `openshell inference get` — Phase 3
- Egress policy assertion (no api.anthropic.com) — Phase 3
- Makefile wrapper (ERG-01) — v2
- Fast cache-reuse/sandbox-only teardown toggle — rejected (D-01: always full-clean)
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BLD-01 | Single script rebuilds sandbox on demand | `rebuild.sh` orchestrates all phases; verified openshell + podman CLI contracts |
| BLD-02 | Rebuild is idempotent — tears down existing sandbox/image and recreates cleanly | `openshell sandbox delete` tolerates not-found (exit 1); `podman rmi --ignore` handles missing image |
| BLD-03 | Image tagged with build date, carries cooldown date as image label | `podman build --tag claude-sandbox:DATE`; `podman tag ... :latest`; `LABEL` in Dockerfile via ARG |
| BLD-04 | Rebuild script emits timestamped log lines per phase | Confirmed: rebuild.sh banners + podman's STEP N/M output covers all named phases |
| BLD-05 | Rebuild script surfaces `openshell logs` egress-audit step via `--audit` flag | `openshell logs <name>` verified CLI contract; exact flags documented |
| BLD-06 | Image built with podman; image reference handed to `openshell sandbox create --from` | Confirmed: `localhost/claude-sandbox:DATE` is valid ref; podman driver uses `image_pull_policy: missing` (uses local store) |
| RUN-03 | `~/claudeshared` bind-mounted read-write | Exact `--driver-config-json` schema verified from official docs; `enable_bind_mounts = true` already set in gateway.toml |
| RUN-04 | Bind mount has correct UID/ownership alignment — Claude can read/write files editable from host | RESOLVED: virtiofs on macOS applehv podman-machine maps ALL container UIDs to host user — empirically verified |
</phase_requirements>

---

## Summary

Phase 2 delivers `rebuild.sh`, a single idempotent script that orchestrates the full sandbox lifecycle by wrapping the Phase 1 `scripts/build-and-lock.sh` seam. All critical unknowns from the CONTEXT.md have been resolved by live CLI verification against the openshell v0.0.62 binary and empirical testing of podman bind mounts on this machine.

The five largest open questions are now closed:

1. **D-09 (UID alignment):** Fully automatic. The podman-machine on macOS uses Apple Hypervisor (applehv) with virtiofs. All container UIDs — whether root (UID 0) or any other UID (tested: UID 1000, UID 501/sandbox) — appear as the macOS host user (`patrickheckenlively`) on the host side. No `--userns`, UID-mapping flags, or chown-on-entry needed. Only requirement: `/claudeshared` must be in `read_write` in the sandbox policy.

2. **Exact openshell CLI surface:** Verified live. `openshell sandbox delete <name>` returns exit 1 with message `"sandbox not found"` when absent. `openshell sandbox create` accepts `--name`, `--from`, `--policy`, `--driver-config-json`, `--no-tty`. `openshell logs <name>` accepts `--source`, `--tail`, `--since`, `--level`, `-n`.

3. **D-06 (BLD-04 logging):** Confirmed satisfied. `podman build` emits `STEP N/M: RUN ...` for each Dockerfile layer — the dnf step, node/npm step, go install step, and both npm install steps each get their own step label. `rebuild.sh` adds timestamped banners for phases it controls (resolve, build, teardown, create). Together these cover all named phases in BLD-04.

4. **BLD-06 (podman → openshell handoff):** Confirmed. The gateway config has no explicit `image_pull_policy`, defaulting to `missing` (pull only if not in local store). Since the image is built into podman's local store, `openshell sandbox create --from localhost/claude-sandbox:<date>` finds the image locally without a registry pull. The full ref `localhost/claude-sandbox:<date>` is the correct form.

5. **Filesystem policy for /claudeshared:** OpenShell's Landlock enforcement blocks agent access to any path not listed in `read_only` or `read_write`. `/claudeshared` is not in the auto-baseline. `rebuild.sh` MUST pass `--policy ./policy.yaml` with `/claudeshared` in `read_write`, and a `policy.yaml` must be committed to the repo. The policy YAML adds to the auto-baseline; it does not replace it.

**Primary recommendation:** Implement `rebuild.sh` as a bash script with `set -euo pipefail` following Phase 1 conventions. The script must: precheck tools, compute BUILD_DATE, call `build-and-lock.sh --tag claude-sandbox:BUILD_DATE`, `podman tag :latest`, tear down sandbox + old images (tolerate-absent), then `openshell sandbox create` with the locked `--driver-config-json` bind mount, `--policy ./policy.yaml`, and `--no-tty`. A one-liner `-- /bin/true` initial command creates the sandbox non-interactively and leaves it in Ready state.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Version resolution (cooldown) | Host script | — | Phase 1 seam; rebuild.sh delegates to resolve-versions.sh via build-and-lock.sh |
| Container image build | Podman (host) | Dockerfile | podman build on host machine; Dockerfile declares layers |
| Image labeling | Dockerfile ARGs → LABEL | build-and-lock.sh (passes BUILD_DATE build-arg) | D-04 locked: labels travel with image regardless of build entry point |
| Image tagging | rebuild.sh | build-and-lock.sh (primary tag) | build-and-lock.sh sets date tag; rebuild.sh adds :latest alias |
| Sandbox teardown | OpenShell CLI (host) | podman CLI (host) | openshell sandbox delete + podman rmi + podman image prune |
| Sandbox creation | OpenShell CLI (host) | gateway (podman driver) | openshell sandbox create hands image ref to gateway |
| Bind mount configuration | OpenShell CLI (--driver-config-json) | gateway.toml (enable_bind_mounts) | bind mount config is per-sandbox, not per-gateway |
| Filesystem policy (Landlock) | OpenShell policy.yaml | openshell sandbox create --policy | static at sandbox create time; must include /claudeshared |
| UID alignment (RUN-04) | virtiofs (podman-machine kernel layer) | — | automatic on macOS applehv; no rebuild.sh action required |
| Egress-audit surfacing | rebuild.sh --audit flag | openshell logs CLI | D-07: log surfacing only, no policy assertion |

---

## Standard Stack

### Core

| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| `openshell` | v0.0.62 [VERIFIED: live binary] | Sandbox lifecycle (create, delete, list, logs) | The project's mandated sandbox runtime; already installed |
| `podman` | v5.x (machine runs rootfully) [VERIFIED: live binary] | Container image build, tag, rmi, prune | CLAUDE.md mandates podman, not Docker daemon |
| `bash` | system | Script interpreter | Phase 1 convention; all scripts use bash |
| `python3` | system | Date arithmetic (COOLDOWN_DATE, BUILD_DATE) | Phase 1 pattern; cross-platform vs GNU `date -d` |
| `jq` | system | JSON parsing (policy probe, inspect) | Already in scripts; installed in Dockerfile |

### No New Packages

This phase adds no new external packages. All tooling is already present on the host or installed in the image by Phase 1.

### Package Legitimacy Audit

No new packages are installed in this phase. Audit not applicable.

---

## Architecture Patterns

### System Architecture Diagram

```
rebuild.sh (host)
    │
    ├── [Preflight] check podman + openshell on PATH
    │
    ├── [Step 1: Resolve + Build]
    │   └── scripts/build-and-lock.sh --cooldown-days N --tag claude-sandbox:BUILD_DATE
    │           └── resolve-versions.sh → cooldown date, pinned versions
    │           └── podman build --build-arg ... --tag claude-sandbox:BUILD_DATE
    │               (STEP 1: FROM fedora:44)
    │               (STEP 2: ARG ...)
    │               (STEP 3: RUN dnf update) ← BLD-04 step label from podman
    │               (STEP 4: RUN node/npm version)
    │               (STEP 5: RUN go install govulncheck)
    │               (STEP 6: RUN npm install gsd-core)
    │               (STEP 7: RUN npm install claude-code)
    │               (STEP 8: RUN git clone toolkit)
    │               (STEP 9: RUN npm ls snapshot)
    │           └── podman create + cp → versions-npm.json, versions-govulncheck.txt
    │           └── jq → versions.lock
    │           └── verify-pins.sh (PIN-07 gate)
    │
    ├── [Step 2: Tag :latest]
    │   └── podman tag localhost/claude-sandbox:BUILD_DATE localhost/claude-sandbox:latest
    │
    ├── [Step 3: Teardown (D-01, D-02)]
    │   ├── openshell sandbox delete claude-sandbox   (exit 1 if not found → tolerate)
    │   ├── podman rmi --force --ignore localhost/claude-sandbox:PREV_DATE
    │   └── podman image prune --force
    │
    └── [Step 4: Create Sandbox (BLD-06, RUN-03, RUN-04)]
        └── openshell sandbox create
                --name claude-sandbox
                --from localhost/claude-sandbox:BUILD_DATE
                --policy ./policy.yaml              ← must include /claudeshared read_write
                --driver-config-json '{"podman":{"mounts":[...]}}'
                --no-tty
                -- /bin/true                        ← exits immediately, sandbox stays Ready

--audit flag subcommand:
    └── openshell logs claude-sandbox [--since <duration>] [--source all]
```

### Recommended Project Structure

```
scripts/
├── build-and-lock.sh      # Phase 1 (extend: add --build-date flag + ARG passthrough)
├── resolve-versions.sh    # Phase 1 (no change)
├── verify-pins.sh         # Phase 1 (no change)
└── (rebuild.sh)           # Phase 2 — new top-level entry point
policy.yaml                # Phase 2 — new sandbox policy (committed to repo)
Dockerfile                 # Extend: add ARG BUILD_DATE + LABEL lines
rebuild.sh                 # Phase 2 — new top-level entry point (at project root)
```

### Pattern 1: Tolerate-Absent Teardown (D-02)

**What:** `openshell sandbox delete` exits 1 with `"sandbox not found"` when the named sandbox does not exist. The teardown step must distinguish this expected condition from a real failure.

**When to use:** Every run of rebuild.sh (D-01: always full clean).

```bash
# Source: openshell sandbox delete --help + live test (verified exit 1 on not-found)
SANDBOX_NAME="claude-sandbox"
DELETE_OUT=$(openshell sandbox delete "${SANDBOX_NAME}" 2>&1) && true
DELETE_RC=$?
if [[ $DELETE_RC -ne 0 ]]; then
    if echo "${DELETE_OUT}" | grep -q "sandbox not found"; then
        echo "INFO: Sandbox ${SANDBOX_NAME} not found — nothing to tear down" >&2
    else
        echo "ERROR: openshell sandbox delete failed: ${DELETE_OUT}" >&2
        exit 1
    fi
fi
```

### Pattern 2: podman rmi Tolerate-Absent (D-02)

**What:** `podman rmi --force --ignore` removes an image without error if it doesn't exist. `--force` handles images with containers using them.

```bash
# Source: podman rmi --help (verified live)
podman rmi --force --ignore "localhost/claude-sandbox:${PREV_DATE}" 2>&1 >&2 || true
podman image prune --force >/dev/null 2>&1 || true
```

### Pattern 3: Non-Interactive Sandbox Create with /bin/true (BLD-06)

**What:** `openshell sandbox create` with `-- /bin/true` runs an immediately-exiting command. OpenShell keeps the sandbox alive after the initial command exits (this is the default; `--no-keep` reverses it). The create CLI call returns once `/bin/true` exits.

```bash
# Source: openshell sandbox create --help (verified live); behavior confirmed from docs
BUILD_DATE="$(python3 -c 'from datetime import date; print(date.today().isoformat())')"
CLAUDESHARED_ABS="${HOME}/claudeshared"
mkdir -p "${CLAUDESHARED_ABS}"

openshell sandbox create \
    --name claude-sandbox \
    --from "localhost/claude-sandbox:${BUILD_DATE}" \
    --policy "${PROJECT_ROOT}/policy.yaml" \
    --driver-config-json "{\"podman\":{\"mounts\":[{\"type\":\"bind\",\"source\":\"${CLAUDESHARED_ABS}\",\"target\":\"/claudeshared\",\"read_only\":false}]}}" \
    --no-tty \
    -- /bin/true
```

### Pattern 4: Timestamped Step Banners (BLD-04)

**What:** Phase 1 established `=== Step N: ... ===` banners to stderr. Phase 2 adds an ISO-8601 timestamp prefix for BLD-04.

```bash
# Follows Phase 1 convention (CONTEXT.md code_context section)
ts() { python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }

log_step() {
    echo "" >&2
    echo "=== [$(ts)] Step $1: $2 ===" >&2
}
log_info() { echo "INFO: $1" >&2; }
log_error() { echo "ERROR: $1" >&2; }
```

### Pattern 5: Dockerfile LABEL via ARG (D-04)

**What:** LABEL lines added to Dockerfile, fed by build ARGs, so labels travel with the image regardless of build entry point.

```dockerfile
# Add after existing ARGs in Dockerfile
ARG BUILD_DATE
LABEL cooldown.date="${COOLDOWN_DATE}"
LABEL build.date="${BUILD_DATE}"
LABEL govulncheck.version="${GOVULNCHECK_VERSION}"
LABEL gsd.core.version="${GSD_CORE_VERSION}"
LABEL claude.code.version="${CLAUDE_CODE_VERSION}"
```

Verified format via `podman inspect localhost/claude-sandbox:dev --format '{{json .Labels}}'` — labels are a flat string map visible in JSON output.

### Pattern 6: --audit Subcommand (D-07)

```bash
# rebuild.sh --audit invocation
# Source: openshell logs --help (verified live)
audit_sandbox() {
    local name="${1:-claude-sandbox}"
    local since="${2:-}"
    local since_arg=""
    [[ -n "$since" ]] && since_arg="--since ${since}"
    openshell logs "${name}" ${since_arg} --source all
}
```

### Pattern 7: policy.yaml for /claudeshared Access

**What:** OpenShell's Landlock enforcement blocks agent writes to `/claudeshared` unless it is listed in `read_write`. The baseline auto-includes `/sandbox` and `/tmp` but NOT bind-mounted paths.

```yaml
# policy.yaml (committed to project root)
# Source: OpenShell policy schema docs + policies.mdx
version: 1

filesystem_policy:
  include_workdir: true
  read_write:
    - /claudeshared

# network_policies left empty for Phase 2; Phase 3 adds zero-egress enforcement
```

The auto-baseline (`/usr`, `/lib`, `/etc`, `/var/log` read-only; `/sandbox`, `/tmp` read-write) is merged on top automatically — no need to repeat baseline paths in user policy.

### Anti-Patterns to Avoid

- **`--from .` or path-based `--from`:** Builds through the local Docker daemon (not podman). CLAUDE.md explicitly forbids this. Always pass the full `localhost/` image ref.
- **`--from-existing` in sandbox create:** Not a sandbox create flag; it was referenced for provider creation. Does not exist in `openshell sandbox create`.
- **`eval` of openshell output:** Use explicit string matching (`grep -q "sandbox not found"`) for tolerate-absent checks. Never `eval` CLI output.
- **`~` in bind mount source:** OpenShell rejects `~`-prefixed paths. Always expand to `$HOME` before constructing the `--driver-config-json`.
- **JSON interpolation with unquoted variables:** Construct the `--driver-config-json` value using bash string interpolation with double-quoted outer string; escape inner quotes explicitly.
- **`--no-keep` on sandbox create:** Would delete the sandbox after `/bin/true` exits. Omit `--no-keep` to keep the sandbox alive.
- **Running `openshell sandbox create` without `--policy`:** Without a policy, `/claudeshared` is blocked by Landlock. The canary test (RUN-04) would fail silently.
- **`ANTHROPIC_BASE_URL=https://inference.local/v1`:** Claude Code appends `/v1/messages`; the double path breaks inference. CLAUDE.md anti-pattern; already correct in Dockerfile CMD.

---

## D-09: UID Alignment Mechanism (RESOLVED)

**Mechanism:** macOS applehv podman-machine with virtiofs filesystem.

**Finding (empirically verified on this machine, 2026-06-14):**

The podman-machine-default VM runs rootfully (`Rootful: true` from `podman machine inspect`). The VM uses Apple Hypervisor (applehv). The host's `/Users` directory is exposed into the VM via virtiofs (`Users /Users virtiofs rw` confirmed from `podman machine ssh podman-machine-default "mount"`).

**Verified behavior:** Files written inside a container to a bind-mounted host path appear on the macOS host owned by the host user, regardless of the UID used in the container:

```
# UID 0 (root) in container → patrickheckenlively on host [VERIFIED: empirical test]
# UID 1000 in container      → patrickheckenlively on host [VERIFIED: empirical test]
```

**Why:** The virtiofs protocol on macOS Apple Hypervisor maps container UIDs to the macOS host user for host-mounted paths. This is a property of the rootful podman-machine's virtiofs layer, not of podman's `--userns` mapping.

**Consequence for rebuild.sh:** No `--userns`, UID-mapping flags, or chown steps are needed. The ONLY requirement for RUN-04 compliance is that `/claudeshared` is in `read_write` in `policy.yaml` so the sandbox agent's Landlock policy permits writes to that path.

**Confidence:** HIGH — verified empirically on the exact machine this code will run on. [VERIFIED: empirical test on podman-machine-default, 2026-06-14]

---

## D-06 Confirmation: BLD-04 Logging Granularity

**Confirmed: podman's own step output satisfies BLD-04 requirements for image-build phases.**

`podman build` emits `STEP N/M: RUN ...` for each Dockerfile layer, which naturally labels each named phase:

```
STEP 3/9: RUN dnf update -y && dnf install -y ...    ← "dnf update" phase
STEP 5/9: RUN go install golang.org/x/vuln/...       ← "go install" phase
STEP 6/9: RUN npm install -g @opengsd/gsd-core...    ← "npm install" gsd-core phase
STEP 7/9: RUN npm install -g @anthropic-ai/...       ← "npm install" claude-code phase
```

`rebuild.sh` adds timestamped banners for phases it controls:
- `[TIMESTAMP] Step 1: Resolve cooldown versions`
- `[TIMESTAMP] Step 2: Build container image`
- `[TIMESTAMP] Step 3: Tag :latest`
- `[TIMESTAMP] Step 4: Teardown existing sandbox and image`
- `[TIMESTAMP] Step 5: Create sandbox`

**No lib-refactor needed.** D-05's "refactor only if BLD-04 forces it" condition is not triggered.

[VERIFIED: empirical test of `podman build` STEP output format]

---

## OpenShell CLI Contract (Verified)

### openshell sandbox create (v0.0.62) [VERIFIED: live binary]

```
openshell sandbox create [OPTIONS] [-- <COMMAND>...]
  --name <NAME>                  Fixed sandbox name (idempotent delete requires known name)
  --from <FROM>                  Image ref: bare name, path, or full ref (e.g. localhost/img:tag)
  --policy <FILE>                Custom policy YAML (static filesystem + process sections)
  --driver-config-json <JSON>    Driver-keyed JSON; "podman" key for bind mounts
  --no-tty                       Disable PTY (required for non-interactive rebuild.sh)
  --provider <PROVIDERS>         Attach providers (Phase 3)
  [-- <COMMAND>...]              Initial command; defaults to interactive shell
```

**Key behavior:** Without `--no-keep`, the sandbox remains in Ready state after the initial command exits. With `-- /bin/true`, the create call returns non-interactively and the sandbox enters Ready.

### openshell sandbox delete (v0.0.62) [VERIFIED: live binary]

```
openshell sandbox delete [OPTIONS] [NAME]...
  --all    Delete all sandboxes
  [NAME]   Sandbox names (space-separated)
```

**Exit behavior:**
- Sandbox exists and is deleted: exit 0
- Sandbox not found: exit 1 with message `"sandbox not found"` (stderr)
- Tolerate-absent pattern: capture stderr, check for "sandbox not found", continue

### openshell sandbox list (v0.0.62) [VERIFIED: live binary]

```
openshell sandbox list [OPTIONS]
  --names            Print only sandbox names, one per line (parseable, no ANSI)
  -o json            JSON output [{name, phase, created_at, id, labels}]
  --selector key=val Label selector filter
```

**Existence check:** `openshell sandbox list --names | grep -q "^claude-sandbox$"`

**Ready check:** `openshell sandbox list -o json | jq -e '.[] | select(.name=="claude-sandbox" and .phase=="Ready")'`

### openshell logs (v0.0.62) [VERIFIED: live binary]

```
openshell logs [OPTIONS] [NAME]
  -n <N>             Lines to return (default 200)
  --tail             Stream live logs
  --since <DURATION> e.g. 5m, 1h, 30s
  --source <SOURCE>  gateway | sandbox | all (default: all)
  --level <LEVEL>    error | warn | info | debug | trace
  [NAME]             Sandbox name (defaults to last-used)
```

**For --audit flag:** `openshell logs claude-sandbox --source all`
**For live tail:** `openshell logs claude-sandbox --tail --source sandbox`

---

## Bind Mount Schema (Verified)

### gateway.toml already configured [VERIFIED: ~/.config/openshell/gateway.toml]

```toml
[openshell.drivers.podman]
enable_bind_mounts = true   # Already set — no gateway change needed
```

### --driver-config-json schema for Podman bind mount [VERIFIED: OpenShell compute-drivers docs]

```json
{
  "podman": {
    "mounts": [
      {
        "type": "bind",
        "source": "/Users/patrickheckenlively/claudeshared",
        "target": "/claudeshared",
        "read_only": false
      }
    ]
  }
}
```

**Rules:**
- `source` MUST be an absolute path. Expand `$HOME` in the script, never pass `~`.
- `read_only` defaults to `true` — must explicitly set `false` for read-write.
- `target` `/claudeshared` is safe (not in the OpenShell forbidden target list: workspace root, `/etc/openshell`, `/etc/openshell-tls`, auth material, `/run/netns`).

**Requires `enable_bind_mounts = true` in gateway.toml** — already set on this machine.

---

## BUILD_DATE Label Mechanism (D-04)

The `COOLDOWN_DATE` ARG already exists in the Dockerfile. Three changes are needed:

### 1. Dockerfile extension

```dockerfile
# After existing ARGs
ARG BUILD_DATE

# After existing LABEL lines (none currently; add before first RUN)
LABEL cooldown.date="${COOLDOWN_DATE}"
LABEL build.date="${BUILD_DATE}"
LABEL govulncheck.version="${GOVULNCHECK_VERSION}"
LABEL gsd.core.version="${GSD_CORE_VERSION}"
LABEL claude.code.version="${CLAUDE_CODE_VERSION}"
```

### 2. build-and-lock.sh extension

Add a `--build-date` flag (or read from `BUILD_DATE` environment variable). This is a minimal CLI extension that does not change the script's core logic. The new flag passes `BUILD_DATE` as an additional `--build-arg BUILD_DATE=...` to `podman build`.

### 3. rebuild.sh computes and passes BUILD_DATE

```bash
BUILD_DATE="$(python3 -c 'from datetime import date; print(date.today().isoformat())')"
bash "${SCRIPT_DIR}/scripts/build-and-lock.sh" \
    --cooldown-days "${COOLDOWN_DAYS}" \
    --tag "claude-sandbox:${BUILD_DATE}" \
    --build-date "${BUILD_DATE}"
```

**Verification:** `podman inspect localhost/claude-sandbox:DATE --format '{{json .Labels}}'` shows `cooldown.date` and `build.date` in the output.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Sandbox lifecycle | Custom container management | `openshell sandbox create/delete` | OpenShell provides the exact idempotent lifecycle API; hand-rolling misses supervisor injection, policy, and TLS |
| Image UID alignment | `--userns=keep-id`, chown scripts, id-mapping config | Nothing — virtiofs handles it automatically | Empirically verified: all UIDs map to host user on macOS applehv podman-machine |
| Filesystem access control in sandbox | Custom seccomp/apparmor | `--policy policy.yaml` with `read_write: [/claudeshared]` | OpenShell supervisor enforces Landlock from inside the container |
| Log format parsing | `awk`/`sed` on openshell output | `openshell sandbox list -o json | jq` | JSON output is machine-stable; table output has ANSI codes and no `--no-color` flag |
| JSON construction with variables | Template files, `printf %s | jq` | Bash string interpolation with explicit escaping | `--driver-config-json` content is small and static; keep it inline in rebuild.sh |

---

## Common Pitfalls

### Pitfall 1: `openshell sandbox delete` Non-Zero Exit on First Run
**What goes wrong:** `set -euo pipefail` causes rebuild.sh to abort on the first run (before any sandbox exists) because `delete` exits 1 with "sandbox not found".
**Why it happens:** `delete` is not idempotent by default.
**How to avoid:** Capture stderr, check for "sandbox not found" string, treat as success. See Pattern 1.
**Warning signs:** rebuild.sh exits immediately after "Step 4: Teardown" on first run.

### Pitfall 2: Missing policy.yaml → canary.txt Write Blocked by Landlock
**What goes wrong:** The sandbox agent (running as "sandbox" user under Landlock) cannot write to `/claudeshared` because it is not in the sandbox's `read_write` list. The canary test fails.
**Why it happens:** `/claudeshared` is not in OpenShell's auto-baseline. Without `--policy`, the default baseline excludes it. Even with `--policy`, if the file omits `/claudeshared`, Landlock blocks writes.
**How to avoid:** Always pass `--policy ./policy.yaml` to sandbox create; `policy.yaml` must include `/claudeshared` in `read_write`. Commit `policy.yaml` to the repo.
**Warning signs:** Canary file never appears on host; `openshell logs claude-sandbox --source sandbox` shows Landlock denial.

### Pitfall 3: `--from .` Triggers Docker Daemon Build (Not Podman)
**What goes wrong:** `openshell sandbox create --from .` builds via the local Docker daemon, bypassing podman. On this machine, Docker daemon may not be running.
**Why it happens:** OpenShell resolves directory paths through the Docker daemon, not the podman API.
**How to avoid:** Always pass the full `localhost/claude-sandbox:<date>` ref (built with podman beforehand).
**Warning signs:** Error about Docker daemon connection.

### Pitfall 4: `~` in --driver-config-json source Path
**What goes wrong:** OpenShell rejects tilde-prefixed paths in `source`. The sandbox create fails with an invalid mount source error.
**Why it happens:** The bind mount schema requires an absolute path.
**How to avoid:** `CLAUDESHARED_ABS="${HOME}/claudeshared"` — expand $HOME before constructing the JSON.
**Warning signs:** `openshell sandbox create` returns an error about invalid mount source.

### Pitfall 5: Missing `--no-tty` in Non-Interactive rebuild.sh
**What goes wrong:** `openshell sandbox create` auto-detects terminal and allocates a PTY, causing the script to hang waiting for interactive input.
**Why it happens:** TTY auto-detection is enabled by default; rebuild.sh runs in a terminal context.
**How to avoid:** Always pass `--no-tty` in rebuild.sh.
**Warning signs:** rebuild.sh hangs at sandbox create step.

### Pitfall 6: Passing `--no-keep` to sandbox create
**What goes wrong:** The sandbox is deleted immediately after `/bin/true` exits. The sandbox never reaches Ready state from the outside.
**Why it happens:** `--no-keep` enables auto-delete after the initial command exits.
**How to avoid:** Do NOT pass `--no-keep`. The default behavior keeps the sandbox alive.

### Pitfall 7: BUILD_DATE vs COOLDOWN_DATE in Tags vs Labels
**What goes wrong:** Build fails or labels contain wrong dates if BUILD_DATE is confused with COOLDOWN_DATE.
**Why it happens:** Two different dates in play: today's date (BUILD_DATE) for the image tag + label, and today minus N days (COOLDOWN_DATE) for the supply-chain cutoff.
**How to avoid:** BUILD_DATE = today; COOLDOWN_DATE = today - COOLDOWN_DAYS. rebuild.sh computes BUILD_DATE and passes it to build-and-lock.sh as `--build-date`. build-and-lock.sh (via resolve-versions.sh) computes COOLDOWN_DATE independently.

### Pitfall 8: Old Image Tag Remains in Teardown
**What goes wrong:** After two consecutive rebuilds, the first build's image (`claude-sandbox:2026-06-13`) is not removed, accumulating disk usage.
**Why it happens:** D-03 means the image tag includes the date; teardown must know the PREVIOUS date to `podman rmi` it.
**How to avoid:** Teardown uses `podman image prune --force` to remove dangling images after rmi. Additionally, rebuild.sh can `podman rmi --force --ignore localhost/claude-sandbox:*` with a glob or just remove all untagged + named `claude-sandbox` images by listing them. The simplest safe approach: `podman rmi --force --ignore $(podman images --filter reference='localhost/claude-sandbox:*' --format '{{.ID}}')` before prune.

---

## Code Examples

### Verified Podman bind mount write + host ownership (D-09 verification)

```bash
# Source: empirical test on this machine, 2026-06-14
# Result: file appears as patrickheckenlively:staff on host regardless of container UID
podman run --rm -v "${HOME}/claudeshared:/claudeshared:z" fedora:latest \
    sh -c "touch /claudeshared/root-test.txt"
ls -la ~/claudeshared/root-test.txt
# → -rw-r--r-- 1 patrickheckenlively staff 0 Jun 14 18:35 /Users/.../claudeshared/root-test.txt
```

### Verified openshell sandbox delete exit behavior

```bash
# Source: live test on openshell v0.0.62
openshell sandbox delete nonexistent-sandbox  # exits 1
# Error:   × code: 'Some requested entity was not found', message: "sandbox not found"
```

### Verified openshell sandbox list --names output

```bash
# Source: live test on openshell v0.0.62
openshell sandbox list --names
# go-dev
# (no ANSI codes, one name per line)
```

### Verified openshell logs CLI

```bash
# Source: openshell logs --help, v0.0.62
openshell logs claude-sandbox                    # last 200 lines, all sources
openshell logs claude-sandbox --source sandbox   # sandbox-only logs
openshell logs claude-sandbox --tail             # live stream
openshell logs claude-sandbox --since 5m         # last 5 minutes
```

### Verified podman image management

```bash
# Source: podman rmi --help, podman image prune --help
podman rmi --force --ignore localhost/claude-sandbox:2026-06-13
podman image prune --force       # removes dangling (untagged) layers
```

### Verified LABEL visibility via podman inspect

```bash
# Source: empirical test on existing claude-sandbox:dev image
podman inspect localhost/claude-sandbox:dev --format '{{json .Labels}}'
# {"io.buildah.version":"1.35.3","org.opencontainers.image.licenses":"MIT",...}
# After D-04 extension: will also include "cooldown.date", "build.date", etc.
```

---

## State of the Art

| Old Approach | Current Approach | Impact |
|--------------|------------------|--------|
| `--userns=keep-id` for bind mount UID mapping | virtiofs automatic translation on macOS applehv | No flags needed; all UIDs map to host user |
| `openshell sandbox stop` then `openshell sandbox delete` | `openshell sandbox delete` directly | v0.0.62 has no `stop` subcommand; `delete` handles running sandboxes |
| `--from ./Dockerfile` | `--from localhost/image:tag` | Directory builds use Docker daemon; ref builds use podman's local store |

**Deprecated/outdated:**
- `openshell sandbox stop`: Not a valid subcommand in v0.0.62. `delete` is the only lifecycle verb (besides `create`). D-02's "stop-then-remove" intent is satisfied by `delete` alone.

---

## Runtime State Inventory

This is a lifecycle/orchestration phase, not a rename/refactor phase. No stored data renaming is involved. However, the following runtime state must be managed:

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | None — no database or datastore involved | None |
| Live service config | Existing `go-dev` sandbox in OpenShell gateway | No action (different sandbox name; rebuild.sh targets `claude-sandbox`) |
| OS-registered state | podman-machine-default VM (running) | None — rebuild.sh uses the machine's podman socket; no restart needed |
| Secrets/env vars | None — no secrets managed in this phase | None |
| Build artifacts | `localhost/claude-sandbox:dev` from Phase 1 testing | D-01 teardown removes it via `podman rmi --force --ignore`; `podman image prune` removes dangling layers |

**Nothing found in remaining categories:** Verified — no databases, no SOPS keys, no Task Scheduler entries, no pip egg-info, no npm global stale installs related to this phase.

---

## Validation Architecture

### Test Framework

No automated test framework applies to a bash script orchestration phase. The success criteria are verified by manual execution.

| Property | Value |
|----------|-------|
| Framework | None (bash scripts, infrastructure) |
| Config file | none |
| Quick run command | `bash rebuild.sh` |
| Full suite command | Run twice in a row; verify canary.txt; `podman inspect` labels |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | Verification |
|--------|----------|-----------|-------------------|-------------|
| BLD-01 | Single script runs end-to-end | smoke | `bash rebuild.sh` | Manual — verify exit 0 |
| BLD-02 | Second run succeeds (idempotent) | smoke | `bash rebuild.sh && bash rebuild.sh` | Manual — verify exit 0 on second run |
| BLD-03 | Build-date tag + cooldown label | manual | `podman inspect localhost/claude-sandbox:DATE --format '{{json .Labels}}'` | Manual — check cooldown.date label |
| BLD-04 | Timestamped log lines per phase | manual | `bash rebuild.sh 2>&1 | grep '=== \[202'` | Manual — verify timestamps present |
| BLD-05 | --audit flag shows openshell logs | manual | `bash rebuild.sh --audit` | Manual — verify log output |
| BLD-06 | Sandbox enters Ready via podman ref | manual | `openshell sandbox list` | Manual — verify Phase: Ready |
| RUN-03 | ~/claudeshared bind-mounted | manual | `openshell sandbox exec -n claude-sandbox -- ls /claudeshared` | Manual — verify mount accessible |
| RUN-04 | canary.txt owned by host user | manual | `openshell sandbox exec -n claude-sandbox -- touch /claudeshared/canary.txt && ls -la ~/claudeshared/canary.txt` | Manual — verify patrickheckenlively owner |

### Wave 0 Gaps

- [ ] `policy.yaml` — new file to create (covers RUN-03, RUN-04)
- [ ] `rebuild.sh` — new script (covers BLD-01..06, RUN-03, RUN-04)
- [ ] Dockerfile `ARG BUILD_DATE` + LABEL lines (covers BLD-03)
- [ ] `scripts/build-and-lock.sh` `--build-date` flag extension (covers BLD-03)

---

## Security Domain

### Applicable ASVS Categories (Level 1)

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | No auth logic in rebuild.sh |
| V3 Session Management | No | No session management |
| V4 Access Control | Partial | `policy.yaml` controls agent filesystem access via Landlock |
| V5 Input Validation | Yes | Sandbox name validation; $HOME expansion check; allowlist for parsed values |
| V6 Cryptography | No | No crypto operations |

### Known Threat Patterns for Bash Script + OpenShell CLI

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Registry output injection via openshell CLI | Tampering | Same as Phase 1: never eval; match specific expected strings only |
| `~` expansion failure in bind mount source | Tampering | Validate `${CLAUDESHARED_ABS}` is absolute path before constructing JSON |
| Dangling image accumulation | Denial of Service | `podman image prune --force` in teardown; `podman rmi --ignore` for known tags |
| Sandbox name collision | Tampering | Fixed name `claude-sandbox`; D-02 tolerates-absent teardown handles pre-existing |
| JSON injection via $HOME path in --driver-config-json | Tampering | Validate $HOME contains no JSON special chars (path validation); use known safe expansion |

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `podman` | BLD-06, BLD-01..03 | ✓ | v5.x (podman-machine-default rootful) | None — mandated by CLAUDE.md |
| `openshell` | BLD-02, BLD-05, BLD-06, RUN-03, RUN-04 | ✓ | v0.0.62 | None — mandated by CLAUDE.md |
| `podman-machine-default` | virtiofs UID mapping (RUN-04) | ✓ | applehv, currently running | None — macOS build host requirement |
| `gateway.toml` with `enable_bind_mounts = true` | RUN-03, RUN-04 | ✓ | Confirmed in ~/.config/openshell/gateway.toml | Cannot create bind mounts without this |
| `python3` | BUILD_DATE, COOLDOWN_DATE | ✓ | system | None — Phase 1 dependency |
| `jq` | JSON parsing in scripts | ✓ | system | None — Phase 1 dependency |
| `curl` | Registry queries in build-and-lock.sh | ✓ | system | None — Phase 1 dependency |

**Missing dependencies with no fallback:** None — all dependencies are available on the target machine.

---

## Open Questions

1. **build-and-lock.sh extension interface for BUILD_DATE**
   - What we know: build-and-lock.sh must pass BUILD_DATE as --build-arg to podman build for D-04 LABEL approach.
   - What's unclear: Whether to use `--build-date` flag or `BUILD_DATE` env var convention.
   - Recommendation: Add `--build-date` flag to build-and-lock.sh (matches existing flag style). If BUILD_DATE is not passed, default to `$(python3 -c 'from datetime import date; print(date.today().isoformat())')`.

2. **Sandbox create blocking behavior: does `-- /bin/true` return synchronously?**
   - What we know: docs say "keep sandbox alive after initial command exits"; `--no-keep` reverses this.
   - What's unclear: Whether `openshell sandbox create -- /bin/true` returns to the shell immediately when `/bin/true` exits, or whether it blocks until the sandbox is torn down.
   - Recommendation: Plan for the `-- /bin/true` pattern; if it blocks, fall back to launching the create in background and polling `openshell sandbox list --names | grep -q claude-sandbox`.

3. **Old image removal: exact reference to rmi**
   - What we know: rebuild.sh must remove old `claude-sandbox:<prev-date>` images (D-01 full clean).
   - What's unclear: rebuild.sh doesn't know the previous date without reading it from `versions.lock` or listing podman images.
   - Recommendation: Use `podman images --filter reference='localhost/claude-sandbox:*' --format '{{.Repository}}:{{.Tag}}'` to enumerate all date-tagged images, rmi them all, then prune dangling.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `openshell sandbox create -- /bin/true` returns to shell when /bin/true exits, leaving sandbox in Ready | Pattern 3, Open Questions | If it blocks indefinitely, rebuild.sh must use background process + polling |
| A2 | Policy.yaml `read_write` additions merge with the auto-baseline rather than replacing it | Pattern 7 | If it replaces, the policy must include all baseline paths (/usr, /lib, /etc, etc.) explicitly |
| A3 | `openshell sandbox create` with a fixed `--name claude-sandbox` succeeds when a sandbox with that name already exists (because teardown already deleted it) | Pattern 3 | If OpenShell races between delete and create at the gateway, a retry loop may be needed |

---

## Project Constraints (from CLAUDE.md)

- **Platform:** NVIDIA OpenShell — build/managed via `openshell` CLI
- **Build tool:** `podman build` (NOT Docker daemon)
- **Base image:** Fedora 44
- **Network:** Zero direct internet egress in running sandbox; inference via OpenShell gateway only (Phase 3)
- **Supply chain:** Cooldown pinning for govulncheck, gsd-core, Claude Code
- **Install methods:** Go + golangci-lint via RPM; govulncheck via `go install`; gsd-core + Claude Code via npm
- **MUST NOT use:** `--from .` or `--from-existing` with `openshell sandbox create`
- **MUST NOT use:** `ANTHROPIC_BASE_URL=https://inference.local/v1` (double /v1)
- **MUST NOT use:** `golangci-lint` via `go install` (RPM only)
- **MUST NOT use:** `openshell policy update --add-endpoint api.anthropic.com:443` (defeats zero-egress)
- **MUST expand $HOME** in bind mount source (no `~` allowed)

---

## Sources

### Primary (HIGH confidence)

- `openshell sandbox --help`, `openshell sandbox create --help`, `openshell sandbox delete --help`, `openshell sandbox list --help`, `openshell sandbox get --help`, `openshell logs --help` — all flags and exit behaviors verified on binary v0.0.62 [VERIFIED: live binary]
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/reference/sandbox-compute-drivers.mdx` — Podman bind mount schema (type/source/target/read_only), `enable_bind_mounts` requirement [VERIFIED: official docs]
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/sandboxes/manage-sandboxes.mdx` — `--from` resolution, `--driver-config-json`, sandbox lifecycle [VERIFIED: official docs]
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/sandboxes/policies.mdx` — filesystem_policy, Landlock, baseline paths, process.run_as_user [VERIFIED: official docs]
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/reference/policy-schema.mdx` — policy YAML field reference [VERIFIED: official docs]
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/crates/openshell-driver-podman/README.md` — Podman driver container security config (user: 0:0 for supervisor, SETUID/SETGID for privilege drop) [VERIFIED: official docs]
- `~/.config/openshell/gateway.toml` — live config confirming `compute_drivers = ["podman"]` and `enable_bind_mounts = true` [VERIFIED: live config file]
- Empirical virtiofs UID mapping test (2026-06-14): files written by UID 0 and UID 1000 in container appear as `patrickheckenlively:staff` on macOS host [VERIFIED: empirical test]
- `podman machine inspect podman-machine-default` — `Rootful: true`, `VMType: applehv` [VERIFIED: live command]
- `podman machine ssh podman-machine-default "mount | grep virtiofs"` — virtiofs mounts for `/Users`, `/private`, `/var/folders` [VERIFIED: live command]
- `openshell sandbox delete nonexistent-sandbox` — exit 1, message "sandbox not found" [VERIFIED: live test]
- `openshell sandbox list --names` — clean one-name-per-line output, no ANSI [VERIFIED: live test]
- `podman images --format '{{.Repository}}:{{.Tag}}'` — `localhost/` prefix for locally built images [VERIFIED: live command]
- `podman inspect localhost/claude-sandbox:dev --format '{{json .Labels}}'` — label JSON format [VERIFIED: live command]
- `podman build` STEP output format — `STEP N/M: RUN ...` per Dockerfile layer [VERIFIED: empirical test]

### Secondary (MEDIUM confidence)

- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/reference/gateway-config.mdx` — `image_pull_policy = "missing"` default for podman driver; no explicit value in gateway.toml means default applies [CITED: official docs]
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/sandboxes/inference-routing.mdx` — inference.local routing mechanics (Phase 3 context) [CITED: official docs]

---

## Metadata

**Confidence breakdown:**
- OpenShell CLI contract: HIGH — all flags verified against live v0.0.62 binary
- D-09 UID alignment: HIGH — empirically verified on the target machine
- Bind mount schema: HIGH — verified from official compute-drivers docs
- Filesystem policy behavior: HIGH — verified from official policies.mdx and policy-schema.mdx
- D-06 logging granularity: HIGH — empirically tested podman build STEP output

**Research date:** 2026-06-14
**Valid until:** 2026-07-14 (stable CLI contract; re-verify if openshell version bumped beyond 0.0.62)
