# Requirements: Claude Sandbox (Fedora 44 / OpenShell)

**Defined:** 2026-06-13
**Core Value:** Claude can run fully autonomous (`--dangerously-skip-permissions`) inside a sandbox with a **three-host, binary-scoped, TLS-passthrough egress allowlist** — api.anthropic.com:443 (inference), platform.claude.com:443 (Console auth), claude.ai:443 (auth) — and nothing else reaches the open internet (Architecture B). Claude authenticates via in-sandbox subscription OAuth; no gateway, no ANTHROPIC_API_KEY.

## v1 Requirements

Requirements for the initial release. Each maps to a roadmap phase.

### Image & Base (IMG)

- [x] **IMG-01**: Sandbox image builds from a Fedora 44 base (`FROM fedora:44`)
- [x] **IMG-02**: All RPM packages are updated during build (`dnf update -y`), with the build cache busted per rebuild so updates actually re-pull
- [x] **IMG-03**: Go toolchain is installed via RPM (`golang`)
- [x] **IMG-04**: golangci-lint is installed via RPM
- [x] **IMG-05**: claude-engineering-toolkit is cloned into the image at build time from `https://github.com/pheckenlWork/claude-engineering-toolkit.git` (default branch, latest HEAD)

### Supply-Chain Cooldown (PIN)

- [x] **PIN-01**: Cooldown date is computed as build date minus N days (default 4), rolling on each rebuild
- [x] **PIN-02**: Cooldown window is overridable via a rebuild-script argument (e.g. `--cooldown-days N`)
- [x] **PIN-03**: govulncheck is installed via `go install`, pinned to the latest released version as of the cooldown date (resolved host-side from the Go proxy, passed in as a build arg)
- [x] **PIN-04**: gsd-core is installed pinned to the latest version as of the cooldown date, with the cooldown applied to all of its transitive dependencies (npm `--before`)
- [x] **PIN-05**: Claude Code CLI is installed pinned to the latest version as of the cooldown date
- [x] **PIN-06**: A resolved version manifest (`versions.lock`) capturing exact installed versions of gsd-core (+ deps), Claude Code, and govulncheck is produced on each build
- [x] **PIN-07**: A pin-held verification step fails the build if any installed pinned package's publish date is after the cooldown date

### Network Isolation & Inference (NET)

- [x] **NET-01**: The running sandbox has a 3-host TLS-passthrough egress allowlist (api.anthropic.com, platform.claude.com, claude.ai — all :443, binary-scoped to claude); all other egress denied. *(superseded by Architecture B — see CLAUDE.md "Network Policy — Three-Host Claude Egress Allowlist"; the original zero-egress/deny-all intent is fulfilled by the deny-all-except-allowlist posture)*
- [x] **NET-02**: Claude Code connects directly to api.anthropic.com via subscription OAuth (in-sandbox `./rebuild.sh login`); no ANTHROPIC_BASE_URL override, no gateway. *(superseded by Architecture B — the original gateway brokering approach was replaced; Claude uses its built-in default endpoint, api.anthropic.com, directly)*
- [x] **NET-03**: Anthropic credentials live inside the sandbox at `~/.claude/.credentials.json`, written by the in-sandbox Claude OAuth login flow (`./rebuild.sh login`). No host-side provider setup, no `ANTHROPIC_API_KEY`, no `openshell provider create --from-existing`. *(superseded by Architecture B — original provider-injection mechanism replaced by in-sandbox OAuth)*
- [x] **NET-04**: The rebuild script asserts the egress policy contains all three claude auth/API hosts (api.anthropic.com, platform.claude.com, claude.ai) as TLS-passthrough endpoints binary-scoped to the claude binary; statsig.anthropic.com and sentry.io are asserted ABSENT. *(Architecture B: direction INVERTED from original — must now ASSERT api.anthropic.com IS present as passthrough, not absent)*
- [x] **NET-05**: The rebuild script runs a network egress smoke test (deny posture only) confirming non-allowlisted hosts (statsig/sentry/google) are blocked from inside the sandbox. Claude auth/API host reachability is validated functionally by `./rebuild.sh login`. *(Architecture B: asserts deny posture for non-allowlisted hosts only; curl is not the claude binary so binary-scoping prevents curl from reaching any host)*

### Runtime & Claude Launch (RUN)

- [x] **RUN-01**: Claude is launched with `--dangerously-skip-permissions`
- [x] **RUN-02**: Claude is launched with `--plugin-dir` pointed at the cloned claude-engineering-toolkit so its agents and skills are loaded
- [x] **RUN-03**: `~/claudeshared` is bind-mounted into the sandbox with read-write access
- [x] **RUN-04**: The bind mount has correct UID/ownership alignment so Claude can read and write files that remain editable from the host

### Rebuild Script & Lifecycle (BLD)

- [x] **BLD-01**: A single script rebuilds the sandbox on demand
- [x] **BLD-02**: Rebuild is idempotent — it tears down any existing sandbox/image and recreates cleanly
- [x] **BLD-03**: The image is tagged with the build date and records the cooldown date as an image label
- [x] **BLD-04**: The rebuild script emits timestamped log lines per phase (dnf update, npm install, go install, sandbox create)
- [x] **BLD-05**: The rebuild script surfaces a documented `openshell logs` egress-audit step for post-session review
- [x] **BLD-06**: The container image is built with **podman** (`podman build`), not the Docker daemon; the rebuild script hands the resulting image reference to `openshell sandbox create --from <image-ref>` (build-phase planning must confirm how OpenShell resolves a podman-built image, since podman and docker use separate local image stores)

## v2 Requirements

Deferred to a future release. Tracked but not in the current roadmap.

### Verification (VER)

- **VER-01**: `policy prove` formal network-policy verification, if/when the OpenShell CLI exposes it publicly (currently unconfirmed in public docs as of 2026-06-13)

### Ergonomics (ERG)

- **ERG-01**: Makefile wrapper (`make sandbox`, `make verify`, `make logs`) for command discoverability

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Unconstrained open internet egress | Defeats the Architecture B 3-host allowlist guarantee; direct reach is limited to the three Claude auth/API hosts only |
| Persistent "never rebuild" sandbox with in-place updates | Destroys reproducibility and makes cooldown pinning meaningless |
| Per-package GPG/Sigstore signature verification | Incomplete coverage and high build complexity; rely on npm lockfile + cooldown + Go `go.sum` instead |
| Cooldown pinning for claude-engineering-toolkit | Operator maintains the fork, so latest HEAD is trusted |
| Multi-user / shared-host hardening | Single-developer tool by design |
| GPU / CUDA passthrough | Not required for this workload; adds attack surface |
| In-sandbox secrets manager (vault, etc.) | Claude credentials live at `~/.claude/.credentials.json` inside the sandbox (in-sandbox OAuth); no extra secrets store needed |
| Watch-mode auto-rebuild on file change | Operator should control when supply-chain state is re-pinned |

## Traceability

Populated at roadmap creation. Each requirement maps to exactly one phase.

| Requirement | Phase | Status |
|-------------|-------|--------|
| IMG-01 | Phase 1 | Complete |
| IMG-02 | Phase 1 | Complete |
| IMG-03 | Phase 1 | Complete |
| IMG-04 | Phase 1 | Complete |
| IMG-05 | Phase 1 | Complete |
| PIN-01 | Phase 1 | Complete |
| PIN-02 | Phase 1 | Complete |
| PIN-03 | Phase 1 | Complete |
| PIN-04 | Phase 1 | Complete |
| PIN-05 | Phase 1 | Complete |
| PIN-06 | Phase 1 | Complete |
| PIN-07 | Phase 1 | Complete |
| NET-01 | Phase 3 | Complete |
| NET-02 | Phase 3 | Complete |
| NET-03 | Phase 3 | Complete |
| NET-04 | Phase 3 | Complete |
| NET-05 | Phase 3 | Complete |
| RUN-01 | Phase 4 | Complete |
| RUN-02 | Phase 4 | Complete |
| RUN-03 | Phase 2 | Complete |
| RUN-04 | Phase 2 | Complete |
| BLD-01 | Phase 2 | Complete |
| BLD-02 | Phase 2 | Complete |
| BLD-03 | Phase 2 | Complete |
| BLD-04 | Phase 2 | Complete |
| BLD-05 | Phase 2 | Complete |
| BLD-06 | Phase 2 | Complete |

**Coverage:**

- v1 requirements: 27 total
- Mapped to phases: 27
- Unmapped: 0 (all requirements mapped)

| Phase | Requirements | Count |
|-------|-------------|-------|
| Phase 1: Dockerfile and Supply-Chain Pinning | IMG-01..05, PIN-01..07 | 12 |
| Phase 2: Rebuild Script and Sandbox Lifecycle | BLD-01..06, RUN-03, RUN-04 | 8 |
| Phase 3: Network Isolation and Inference Validation | NET-01..05 | 5 |
| Phase 4: Claude Code Launch and MCP Audit | RUN-01, RUN-02 | 2 |

---
*Requirements defined: 2026-06-13*
*Last updated: 2026-06-13 after roadmap creation — traceability complete*
