# Phase 2: Rebuild Script and Sandbox Lifecycle - Context

**Gathered:** 2026-06-14
**Status:** Ready for planning

<domain>
## Phase Boundary

Deliver a single, idempotent `rebuild.sh` that orchestrates the full sandbox
lifecycle end-to-end: compute the rolling cooldown → resolve pinned versions →
`podman build` the image → tear down any existing sandbox/image → create a fresh
OpenShell sandbox with the `~/claudeshared` bind mount and correct UID alignment.
It **wraps** the Phase 1 resolver+build seam (`scripts/build-and-lock.sh`) rather
than re-implementing resolution.

**In scope (Phase 2):** `rebuild.sh` orchestration; idempotent teardown +
recreate (BLD-02); build-date image tag + cooldown image **label** (BLD-03);
per-phase timestamped logging (BLD-04); `~/claudeshared` read-write bind mount
(RUN-03) with host-user UID ownership alignment (RUN-04); a documented
egress-audit step exposed via a dedicated `--audit` flag (BLD-05); handing the
podman-built image **reference** to `openshell sandbox create --from <image-ref>`
(BLD-06, not `--from .`).

**Out of scope (later phases):**
- Network isolation / zero-egress policy enforcement and the inference-provider
  preflight (`openshell inference get`) — **Phase 3**.
- Asserting the egress policy contains no direct Anthropic endpoint — **Phase 3**
  (distinct from Phase 2's BLD-05 `--audit` log-surfacing of `openshell logs`).
- Claude launch flags (`--dangerously-skip-permissions`, `--plugin-dir`) and the
  MCP/plugin audit — **Phase 4** (RUN-01, RUN-02).
</domain>

<decisions>
## Implementation Decisions

### Teardown scope & idempotency (BLD-02)
- **D-01:** On every run, teardown performs a **full clean**: remove the existing
  sandbox, remove the previously-built image (`podman rmi`), and prune dangling
  layers from the rebuild. Every run starts from a known-empty state. (A full
  rebuild cost per run is accepted.)
- **D-02:** Teardown is **force + tolerate-absent**: if the sandbox is present,
  stop-then-remove with force (no prompt, Running state never blocks); if the
  sandbox/image is not found (first run), log and continue with exit 0. This is
  what makes run #1 and run #2 both succeed — directly satisfies ROADMAP success
  criterion #1. Hard-error only on genuinely unexpected failures (e.g. the
  `openshell` CLI itself missing).

### Image tag & cooldown label (BLD-03)
- **D-03:** Tag each build with the **build date AND move `:latest`**:
  `claude-sandbox:<build-date>` + `claude-sandbox:latest`. `rebuild.sh` hands the
  **date-pinned** ref to `openshell sandbox create --from` (immutable reference);
  `:latest` is a stable human handle. Accumulation is not a concern because D-01
  removes the old image each run.
- **D-04 (Claude's discretion — recommendation locked):** The cooldown date +
  build metadata (build date, resolved versions) are attached as a
  podman-inspectable label via **`LABEL` lines in the Dockerfile fed by build
  ARGs**, not via `podman build --label` in the script. Provenance then travels
  with the image even if built outside `rebuild.sh`, and the ARGs are already
  plumbed through from `build-and-lock.sh`. Satisfies success criterion #2
  (`podman inspect` shows the cooldown label).

### rebuild.sh ↔ build-and-lock seam (BLD-01)
- **D-05 (Claude's discretion — recommendation locked):** `rebuild.sh` reuses the
  resolve→build→lock logic by **calling `scripts/build-and-lock.sh` as a
  subprocess** (passing the date `--tag`), then performs teardown + `openshell
  sandbox create`. Lowest risk to verified Phase 1 code; keeps `build-and-lock.sh`
  independently runnable. Refactor the shared block into a sourced `scripts/lib/`
  only if per-phase logging granularity (BLD-04) forces it. **D-01 from Phase 1
  remains in force: do not duplicate resolution logic.**
- **D-06 (BLD-04 logging interpretation — flagged for research/planning):** The
  `dnf update / npm install / go install` phases named in BLD-04 run **inside
  `podman build`** (image layers), so `rebuild.sh` cannot trivially wrap
  timestamped lines around each. Interpretation: `rebuild.sh` emits timestamped
  wrapper lines around the major phases it controls (resolve, build, teardown,
  create); the dnf/npm/go granularity comes from the `podman build` layer output
  itself. Research/planning should confirm this satisfies BLD-04 or decide whether
  the lib-refactor (D-05 alternative) is needed to surface finer per-step
  timestamps.

### Egress-audit surfacing (BLD-05)
- **D-07:** Expose the post-session egress review via a **dedicated `--audit`
  flag/subcommand** on `rebuild.sh` that runs the `openshell logs <sandbox>`
  query directly, **plus** a README section documenting what to look for. Scope
  boundary: this is **log surfacing only**. Asserting the egress *policy* contains
  no `api.anthropic.com` (Phase 3 success criterion #4) is **not** part of this
  flag and must not be built here.

### Bind mount & UID alignment (RUN-03, RUN-04)
- **D-08:** The bind mount config is **locked by CLAUDE.md**: `type: bind`,
  `source` = absolute `$HOME/claudeshared` (expand `$HOME` in the script — no
  `~`), `target` = `/claudeshared`, `read_only: false`. `rebuild.sh` must expand
  the absolute path and ensure the host source directory exists.
- **D-09 (deferred to research — mechanism only):** The **mechanism** for
  host-user UID ownership alignment (so a file written in-sandbox at
  `~/claudeshared/canary.txt` appears host-owned per success criterion #4) is left
  to the researcher — on macOS + podman-machine + OpenShell this is a real
  userns / run-as-UID / bind-mount-ownership problem requiring CLI verification.
  The *requirement* (host-user-owned canary) is locked; the *how* is research.

### Claude's Discretion
- Cooldown-label mechanism (D-04) → Dockerfile `LABEL` via ARG (recommended).
- Build seam (D-05) → call `build-and-lock.sh` as subprocess (recommended).
- BLD-04 logging granularity (D-06) → confirm during research/planning.
- UID-alignment mechanism (D-09) → researcher determines; requirement is fixed.
- Sandbox name, exact `openshell sandbox` subcommand names (rm/stop/create flags),
  and basic preflight (podman/openshell present) were NOT discussed and are left
  to research + planning — they require live CLI verification.
</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project specs & requirements
- `CLAUDE.md` — authoritative tech-stack spec. For this phase specifically:
  "Host Directory Mounts (`~/claudeshared`)" (bind schema, absolute-path/`$HOME`
  expansion rule, forbidden mount targets); "How `sandbox create --from` works"
  (image-ref resolution — bare name vs path vs full ref); "Podman driver" /
  podman-vs-docker separate image stores note (BLD-06); "What NOT to Use"
  (`--from .`, `--from-existing` anti-patterns); Sources block confirming
  `openshell` v0.0.62 + `enable_bind_mounts = true`. MUST read before planning.
- `.planning/REQUIREMENTS.md` §BLD (BLD-01..06) and §RUN (RUN-03, RUN-04) — the 8
  requirements this phase satisfies.
- `.planning/ROADMAP.md` → "Phase 2" — goal + 5 success criteria (notably #1
  idempotent rerun, #2 build-date tag + cooldown label via `podman inspect`, #3
  per-phase timestamped logs, #4 host-user-owned `canary.txt`, #5 `--from
  <image-ref>` not `--from .` and sandbox reaches Ready).
- `.planning/phases/01-dockerfile-and-supply-chain-pinning/01-CONTEXT.md` — Phase 1
  decisions, especially D-01 (resolver/build seam is the Phase 2 hand-off) and the
  "Phase 2 will own…" deferral list.

### Phase 1 artifacts to wrap / extend (in this repo)
- `scripts/build-and-lock.sh` — the resolve→podman build→extract→`versions.lock`
  →verify-pins driver. `rebuild.sh` wraps this (D-05). Note it currently tags
  `claude-sandbox:dev` — Phase 2 changes the tagging (D-03).
- `scripts/resolve-versions.sh` — cooldown + version resolver (called transitively
  via build-and-lock; do not re-implement).
- `scripts/verify-pins.sh` — PIN-07 host-side gate (runs at end of build-and-lock).
- `Dockerfile` — extend with `ARG` + `LABEL` lines for the cooldown/build-date/
  versions labels (D-04). Tagging is done by the build invocation.

### External resources (OpenShell CLI — verify live during research)
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/sandboxes/manage-sandboxes.mdx`
  — `--from`, `--driver-config-json`, sandbox lifecycle commands.
- `https://raw.githubusercontent.com/NVIDIA/OpenShell/main/docs/reference/sandbox-compute-drivers.mdx`
  — bind-mount schema + `enable_bind_mounts` (RUN-03/04, UID mapping context).
- `~/.config/openshell/gateway.toml` — live config: `compute_drivers = ["podman"]`,
  `enable_bind_mounts = true`.
- `openshell sandbox --help`, `openshell sandbox create --help`,
  `openshell logs --help` — verify exact subcommands/flags for teardown (D-02),
  create (BLD-06), and `--audit` (D-07).
</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/build-and-lock.sh` (251 lines) — already factors the full
  resolve→build→lock→verify pipeline behind a clean `--cooldown-days` / `--tag`
  CLI, written explicitly as "the Phase 2 hand-off seam." `rebuild.sh` calls it.
- Established script conventions from Phase 1 to match: `set -euo pipefail`;
  `SCRIPT_DIR`/`PROJECT_ROOT` resolution; all human/log output to **stderr**
  (`>&2`) with `INFO:`/`ERROR:` prefixes and `=== Step N: ... ===` banners;
  allowlist-validated parsing of registry-derived values (never `eval`).

### Established Patterns
- The `=== Step N ===` banner style is the natural anchor for BLD-04 timestamped
  per-phase logging — `rebuild.sh` should prefix these with timestamps.
- Phase 1 keeps verification host-side and fail-closed; Phase 2's teardown/create
  should follow the same explicit-error, idempotent discipline.

### Integration Points
- `rebuild.sh` is the new top-level entry point. It composes:
  build-and-lock.sh (build) → openshell teardown → openshell create. The
  date-pinned image tag (D-03) is the value passed from the build step into the
  `openshell sandbox create --from` step.
- Phase 3 will layer the `openshell inference get` preflight onto `rebuild.sh`;
  design the script so a preflight step slots in before `sandbox create`.
</code_context>

<specifics>
## Specific Ideas

- Full-clean teardown was an explicit preference: "every run starts from a
  known-empty state" (sandbox + old image + dangling prune), accepting the full
  rebuild cost — chosen over the faster cache-reuse / sandbox-only option.
- Egress audit chosen as an active `--audit` subcommand (operator runs it to get
  `openshell logs`), not just a printed reminder or docs-only note.
</specifics>

<deferred>
## Deferred Ideas

- **Preflight `openshell inference get`** to avoid the ~290s provider hang —
  Phase 3 (ROADMAP success criterion #3), not Phase 2.
- **Egress *policy* assertion** (no `api.anthropic.com` in the allowlist) —
  Phase 3 success criterion #4. Phase 2's `--audit` only surfaces `openshell
  logs`; it must not grow into policy verification.
- **Makefile wrapper (ERG-01)** and **`policy prove` formal verification
  (VER-01)** — explicitly v2 (carried forward from Phase 1).
- Optional `--prune`/`--clean` vs fast cache-reuse teardown toggle was offered but
  **rejected** in favor of always-full-clean (D-01); record kept in case a future
  phase wants a fast-iteration mode.

None raised during discussion that fall outside the v1 requirement set.
</deferred>

---

*Phase: 2-Rebuild Script and Sandbox Lifecycle*
*Context gathered: 2026-06-14*
