# Phase 2: Rebuild Script and Sandbox Lifecycle - Pattern Map

**Mapped:** 2026-06-14
**Files analyzed:** 4 (rebuild.sh, policy.yaml, Dockerfile extension, build-and-lock.sh extension)
**Analogs found:** 3 / 4 (policy.yaml has no existing analog)

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `rebuild.sh` | orchestrator script | request-response (subprocess delegation) | `scripts/build-and-lock.sh` | exact — same conventions, same shell patterns |
| `policy.yaml` | config | static declaration | none in codebase | no analog |
| `Dockerfile` (extend) | config | build-time transform | `Dockerfile` itself (lines 1-9) | self-referential extension |
| `scripts/build-and-lock.sh` (extend) | utility script | request-response | `scripts/build-and-lock.sh` (lines 26-54) | self-referential extension |

---

## Pattern Assignments

### `rebuild.sh` (orchestrator script, request-response)

**Analog:** `scripts/build-and-lock.sh`

**Shebang + strict mode + SCRIPT_DIR/PROJECT_ROOT** (`scripts/build-and-lock.sh` lines 1-19):
```bash
#!/usr/bin/env bash
# rebuild.sh — [description]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}" && pwd)"
# Note: rebuild.sh lives at project root, not inside scripts/;
# PROJECT_ROOT is therefore the same as SCRIPT_DIR for this file.
# Use: PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

**Defaults + argument parsing** (`scripts/build-and-lock.sh` lines 21-54):
```bash
# --- Defaults ---
COOLDOWN_DAYS=4

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cooldown-days)
            if [[ -z "${2-}" ]]; then
                echo "ERROR: --cooldown-days requires an argument" >&2
                exit 1
            fi
            COOLDOWN_DAYS="$2"
            shift 2
            ;;
        --cooldown-days=*)
            COOLDOWN_DAYS="${1#--cooldown-days=}"
            shift
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Usage: $0 [--cooldown-days N]" >&2
            exit 1
            ;;
    esac
done
```
Apply this pattern for `rebuild.sh`'s `--cooldown-days` and `--audit` flags. For `--audit`, add a subcommand branch that calls `audit_sandbox()` (see Pattern 6 below) and exits immediately without running the build.

**Timestamped step banner helper** (new for Phase 2, not in analog — use RESEARCH.md Pattern 4):
```bash
ts() { python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }

log_step() {
    echo "" >&2
    echo "=== [$(ts)] Step $1: $2 ===" >&2
}
log_info()  { echo "INFO: $1" >&2; }
log_error() { echo "ERROR: $1" >&2; }
```
This extends Phase 1's `=== Step N: ... ===` convention (see `scripts/build-and-lock.sh` lines 56, 112, 125, 159, 236) by prepending an ISO-8601 UTC timestamp in brackets. Use `log_step`, `log_info`, `log_error` throughout rebuild.sh.

**BUILD_DATE computation** (pattern from `scripts/build-and-lock.sh` line 191):
```bash
BUILD_DATE="$(python3 -c 'from datetime import date; print(date.today().isoformat())')"
```
Compute once at the top of the script, before calling build-and-lock.sh.

**Subprocess delegation to build-and-lock.sh** (D-05; extends the Step 1 pattern in `scripts/build-and-lock.sh` lines 56-95):
```bash
log_step 1 "Resolve cooldown versions and build container image"
bash "${PROJECT_ROOT}/scripts/build-and-lock.sh" \
    --cooldown-days "${COOLDOWN_DAYS}" \
    --tag "claude-sandbox:${BUILD_DATE}" \
    --build-date "${BUILD_DATE}"
log_info "build-and-lock.sh completed successfully"
```

**:latest tag step** (after build-and-lock.sh returns; new for Phase 2):
```bash
log_step 2 "Tag :latest alias"
podman tag "localhost/claude-sandbox:${BUILD_DATE}" "localhost/claude-sandbox:latest"
log_info "Tagged localhost/claude-sandbox:latest"
```

**Tolerate-absent teardown — sandbox** (RESEARCH.md Pattern 1):
```bash
log_step 3 "Teardown existing sandbox and images"
SANDBOX_NAME="claude-sandbox"

DELETE_OUT=$(openshell sandbox delete "${SANDBOX_NAME}" 2>&1) && true
DELETE_RC=$?
if [[ $DELETE_RC -ne 0 ]]; then
    if echo "${DELETE_OUT}" | grep -q "sandbox not found"; then
        log_info "Sandbox ${SANDBOX_NAME} not found — nothing to tear down"
    else
        log_error "openshell sandbox delete failed: ${DELETE_OUT}"
        exit 1
    fi
else
    log_info "Sandbox ${SANDBOX_NAME} deleted"
fi
```
Note: never use `eval` on CLI output — the `grep -q "sandbox not found"` pattern matches the exact expected string. (`scripts/build-and-lock.sh` lines 59-95 established the allowlist-validated parsing discipline; same principle applies here.)

**Tolerate-absent teardown — images** (RESEARCH.md Pattern 2):
```bash
# Remove all date-tagged claude-sandbox images (handles accumulation from prior runs)
OLD_IMAGES=$(podman images --filter reference='localhost/claude-sandbox:*' \
    --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
if [[ -n "${OLD_IMAGES}" ]]; then
    while IFS= read -r img; do
        [[ -z "${img}" ]] && continue
        log_info "Removing image: ${img}"
        podman rmi --force --ignore "${img}" >/dev/null 2>&1 || true
    done <<< "${OLD_IMAGES}"
fi
podman image prune --force >/dev/null 2>&1 || true
log_info "Image teardown complete"
```

**Sandbox create — bind mount + policy** (RESEARCH.md Pattern 3):
```bash
log_step 4 "Create sandbox"
CLAUDESHARED_ABS="${HOME}/claudeshared"
mkdir -p "${CLAUDESHARED_ABS}"

# Validate $HOME is an absolute path with no JSON special chars (T-01-11 mitigation)
if ! [[ "${CLAUDESHARED_ABS}" =~ ^/[^\"\'\\]+ ]]; then
    log_error "CLAUDESHARED_ABS is not a safe absolute path: ${CLAUDESHARED_ABS}"
    exit 1
fi

openshell sandbox create \
    --name "${SANDBOX_NAME}" \
    --from "localhost/claude-sandbox:${BUILD_DATE}" \
    --policy "${PROJECT_ROOT}/policy.yaml" \
    --driver-config-json "{\"podman\":{\"mounts\":[{\"type\":\"bind\",\"source\":\"${CLAUDESHARED_ABS}\",\"target\":\"/claudeshared\",\"read_only\":false}]}}" \
    --no-tty \
    -- /bin/true

log_info "Sandbox ${SANDBOX_NAME} created"
log_info "Verifying sandbox is in Ready state..."
if openshell sandbox list --names 2>/dev/null | grep -q "^${SANDBOX_NAME}$"; then
    log_info "Sandbox ${SANDBOX_NAME} is running"
else
    log_error "Sandbox ${SANDBOX_NAME} not found after create — check openshell logs"
    exit 1
fi
```

**--audit subcommand** (RESEARCH.md Pattern 6):
```bash
audit_sandbox() {
    local name="${1:-claude-sandbox}"
    local since="${2:-}"
    local since_arg=""
    [[ -n "$since" ]] && since_arg="--since ${since}"
    openshell logs "${name}" ${since_arg} --source all
}
```
Wire into argument parsing as a branch that runs `audit_sandbox "${SANDBOX_NAME}"` then exits 0 — does not trigger the build/teardown/create flow.

**Preflight tool check** (new for Phase 2; follows fail-closed discipline from `scripts/verify-pins.sh` lines 67-87):
```bash
for cmd in podman openshell python3 jq; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        log_error "Required tool not found on PATH: ${cmd}"
        exit 1
    fi
done
```

---

### `scripts/build-and-lock.sh` (extend — add `--build-date` flag)

**Analog:** `scripts/build-and-lock.sh` itself — minimal extension only.

**New flag in argument parsing block** (insert into existing `while [[ $# -gt 0 ]]` at lines 26-54; follow the same two-form convention for both `--flag VALUE` and `--flag=VALUE`):
```bash
        --build-date)
            if [[ -z "${2-}" ]]; then
                echo "ERROR: --build-date requires an argument" >&2
                exit 1
            fi
            BUILD_DATE="$2"
            shift 2
            ;;
        --build-date=*)
            BUILD_DATE="${1#--build-date=}"
            shift
            ;;
```

**Default for BUILD_DATE** (add to `--- Defaults ---` block at lines 21-24):
```bash
BUILD_DATE="$(python3 -c 'from datetime import date; print(date.today().isoformat())')"
```

**Allowlist-validate BUILD_DATE** (add after arg-parse loop; same discipline as `COOLDOWN_DAYS` validation in `scripts/resolve-versions.sh` lines 49-53):
```bash
if ! [[ "${BUILD_DATE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "ERROR: --build-date must be YYYY-MM-DD, got: '${BUILD_DATE}'" >&2
    exit 1
fi
```

**Pass BUILD_DATE to podman build** (extend the existing `podman build` invocation at lines 115-121 — add one `--build-arg` line):
```bash
podman build \
    --build-arg "COOLDOWN_DATE=${COOLDOWN_DATE}" \
    --build-arg "GOVULNCHECK_VERSION=${GOVULNCHECK_VERSION}" \
    --build-arg "GSD_CORE_VERSION=${GSD_CORE_VERSION}" \
    --build-arg "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}" \
    --build-arg "BUILD_DATE=${BUILD_DATE}" \          # <-- ADD THIS LINE
    --tag "${IMAGE_TAG}" \
    "${PROJECT_ROOT}"
```

---

### `Dockerfile` (extend — add `ARG BUILD_DATE` and LABEL lines)

**Analog:** `Dockerfile` lines 1-9 (existing ARG block).

**New ARG line** (insert after existing ARGs at line 9, before the first RUN):
```dockerfile
ARG BUILD_DATE
```
The final ARG block becomes:
```dockerfile
ARG COOLDOWN_DATE
ARG GOVULNCHECK_VERSION
ARG GSD_CORE_VERSION
ARG CLAUDE_CODE_VERSION
ARG BUILD_DATE
```

**LABEL lines** (RESEARCH.md Pattern 5 — insert after ARG block, before Step 1 RUN at line 15):
```dockerfile
LABEL cooldown.date="${COOLDOWN_DATE}"
LABEL build.date="${BUILD_DATE}"
LABEL govulncheck.version="${GOVULNCHECK_VERSION}"
LABEL gsd.core.version="${GSD_CORE_VERSION}"
LABEL claude.code.version="${CLAUDE_CODE_VERSION}"
```
Rationale (D-04): Labels declared in the Dockerfile via ARG travel with the image regardless of build entry point. Verified via `podman inspect localhost/claude-sandbox:dev --format '{{json .Labels}}'`.

**Placement rule:** LABEL lines must come AFTER all five ARG declarations and BEFORE the first RUN (cache-bust anchor is the `COOLDOWN_DATE` ARG, already at line 6; LABELs do not invalidate the cache because they don't trigger layer execution).

---

### `policy.yaml` (new config — no analog in codebase)

**No analog found.** Use RESEARCH.md Pattern 7 directly.

```yaml
# policy.yaml — OpenShell sandbox Landlock filesystem policy
# Source: OpenShell policies.mdx + policy-schema.mdx (verified official docs)
#
# This file is passed to `openshell sandbox create --policy ./policy.yaml`.
# The auto-baseline (read-only: /usr /lib /etc; read-write: /sandbox /tmp) is
# merged in automatically — only add paths beyond the baseline here.
#
# network_policies intentionally omitted for Phase 2.
# Phase 3 will add zero-egress enforcement.
version: 1

filesystem_policy:
  include_workdir: true
  read_write:
    - /claudeshared
```

**Key constraint:** Without `/claudeshared` in `read_write`, the sandbox agent cannot write canary files to the bind mount — the Landlock denial is silent from the sandbox perspective (RUN-04 success criterion would fail). This file MUST be committed to the repo root so `--policy "${PROJECT_ROOT}/policy.yaml"` resolves correctly.

---

## Shared Patterns

### strict mode + path resolution
**Source:** `scripts/build-and-lock.sh` lines 16-19 and `scripts/verify-pins.sh` lines 24-27
**Apply to:** `rebuild.sh`
```bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
```
For `rebuild.sh` at project root: `PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` (no `..` needed).

### stderr-only logging with INFO:/ERROR: prefix
**Source:** `scripts/build-and-lock.sh` lines 56-57, 106-109, 112-113
**Apply to:** `rebuild.sh` (all diagnostic output)
```bash
echo "INFO: ..."  >&2
echo "ERROR: ..." >&2
```
All informational and error output goes to stderr. Stdout is reserved for machine-parseable output only (rebuild.sh has none, so all output is stderr).

### Step banners to stderr
**Source:** `scripts/build-and-lock.sh` lines 56, 111, 125, 159, 236
**Apply to:** `rebuild.sh`
```bash
echo "=== Step N: [description] ===" >&2
```
Phase 2 extends this with the `log_step` wrapper that prepends an ISO-8601 UTC timestamp (see Pattern 4 under rebuild.sh above).

### allowlist-validated parsing (never eval)
**Source:** `scripts/build-and-lock.sh` lines 59-95
**Apply to:** rebuild.sh teardown (grep-match on openshell output); build-and-lock.sh extension (BUILD_DATE format validation)
```bash
# Pattern: match specific expected string; never eval CLI output
if echo "${DELETE_OUT}" | grep -q "sandbox not found"; then
    ...  # tolerate
else
    exit 1  # unexpected — hard error
fi
```

### fail-closed on missing inputs
**Source:** `scripts/verify-pins.sh` lines 67-87
**Apply to:** rebuild.sh preflight (tool existence check); build-and-lock.sh BUILD_DATE validation
```bash
if [[ ! -f "${LOCK_FILE}" ]]; then
    echo "FAIL: file not found at ${LOCK_FILE}" >&2
    exit 1
fi
```

### trap for cleanup
**Source:** `scripts/build-and-lock.sh` lines 132-138
**Apply to:** rebuild.sh if it creates any transient artifacts (none currently expected, but establish the pattern for future steps):
```bash
cleanup_container() {
    if [[ -n "${CID:-}" ]]; then
        echo "INFO: Removing container ${CID}" >&2
        podman rm "${CID}" >/dev/null 2>&1 || true
    fi
}
trap cleanup_container EXIT
```

---

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `policy.yaml` | config | static declaration | No OpenShell policy YAML files exist anywhere in the repo; no analog exists. Use RESEARCH.md Pattern 7 verbatim. |

---

## Metadata

**Analog search scope:** `scripts/` directory (all .sh files), `Dockerfile`, project root
**Files scanned:** 4 (build-and-lock.sh, resolve-versions.sh, verify-pins.sh, Dockerfile)
**Pattern extraction date:** 2026-06-14
