# Requirements: Claude Sandbox (Fedora 44 / OpenShell)

**Defined:** 2026-06-13
**Core Value:** Claude can run fully autonomous (`--dangerously-skip-permissions`) inside a sandbox with zero direct network egress — all inference brokered through the OpenShell gateway.

## v1 Requirements

Requirements for the initial release. Each maps to a roadmap phase.

### Image & Base (IMG)

- [ ] **IMG-01**: Sandbox image builds from a Fedora 44 base (`FROM fedora:44`)
- [ ] **IMG-02**: All RPM packages are updated during build (`dnf update -y`), with the build cache busted per rebuild so updates actually re-pull
- [ ] **IMG-03**: Go toolchain is installed via RPM (`golang`)
- [ ] **IMG-04**: golangci-lint is installed via RPM
- [ ] **IMG-05**: claude-engineering-toolkit is cloned into the image at build time from `https://github.com/pheckenlWork/claude-engineering-toolkit.git` (default branch, latest HEAD)

### Supply-Chain Cooldown (PIN)

- [ ] **PIN-01**: Cooldown date is computed as build date minus N days (default 4), rolling on each rebuild
- [ ] **PIN-02**: Cooldown window is overridable via a rebuild-script argument (e.g. `--cooldown-days N`)
- [ ] **PIN-03**: govulncheck is installed via `go install`, pinned to the latest released version as of the cooldown date (resolved host-side from the Go proxy, passed in as a build arg)
- [ ] **PIN-04**: gsd-core is installed pinned to the latest version as of the cooldown date, with the cooldown applied to all of its transitive dependencies (npm `--before`)
- [ ] **PIN-05**: Claude Code CLI is installed pinned to the latest version as of the cooldown date
- [ ] **PIN-06**: A resolved version manifest (`versions.lock`) capturing exact installed versions of gsd-core (+ deps), Claude Code, and govulncheck is produced on each build
- [ ] **PIN-07**: A pin-held verification step fails the build if any installed pinned package's publish date is after the cooldown date

### Network Isolation & Inference (NET)

- [ ] **NET-01**: The running sandbox has zero direct internet egress (deny-all egress policy)
- [ ] **NET-02**: Model inference is brokered through the OpenShell gateway — `ANTHROPIC_BASE_URL` points at the gateway inference endpoint, not the public Anthropic API
- [ ] **NET-03**: Anthropic credentials are injected at sandbox runtime via the OpenShell provider mechanism, never baked into the image. Primary path is the **Claude subscription login** (no `ANTHROPIC_API_KEY`): the gateway loads the existing `claude-code` provider credential from host state (`openshell provider create … --from-existing`) and handles token refresh host-side via `openshell provider refresh`. Claude Code in the sandbox sends to `inference.local` with a placeholder credential; the gateway attaches the real subscription credential when forwarding. (Inference phase confirms exact `provider create`/`inference set` flags.)
- [ ] **NET-04**: The rebuild script asserts the egress policy contains no `api.anthropic.com` (or other direct Anthropic) endpoint
- [ ] **NET-05**: The rebuild script runs a network egress smoke test confirming an outbound request from inside the sandbox fails, before handing control to the operator

### Runtime & Claude Launch (RUN)

- [ ] **RUN-01**: Claude is launched with `--dangerously-skip-permissions`
- [ ] **RUN-02**: Claude is launched with `--plugin-dir` pointed at the cloned claude-engineering-toolkit so its agents and skills are loaded
- [ ] **RUN-03**: `~/claudeshared` is bind-mounted into the sandbox with read-write access
- [ ] **RUN-04**: The bind mount has correct UID/ownership alignment so Claude can read and write files that remain editable from the host

### Rebuild Script & Lifecycle (BLD)

- [ ] **BLD-01**: A single script rebuilds the sandbox on demand
- [ ] **BLD-02**: Rebuild is idempotent — it tears down any existing sandbox/image and recreates cleanly
- [ ] **BLD-03**: The image is tagged with the build date and records the cooldown date as an image label
- [ ] **BLD-04**: The rebuild script emits timestamped log lines per phase (dnf update, npm install, go install, sandbox create)
- [ ] **BLD-05**: The rebuild script surfaces a documented `openshell logs` egress-audit step for post-session review
- [ ] **BLD-06**: The container image is built with **podman** (`podman build`), not the Docker daemon; the rebuild script hands the resulting image reference to `openshell sandbox create --from <image-ref>` (build-phase planning must confirm how OpenShell resolves a podman-built image, since podman and docker use separate local image stores)

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
| Direct egress allowlist to `api.anthropic.com` | Defeats the zero-egress guarantee; gateway brokering is precisely what prevents direct internet reach |
| Persistent "never rebuild" sandbox with in-place updates | Destroys reproducibility and makes cooldown pinning meaningless |
| Per-package GPG/Sigstore signature verification | Incomplete coverage and high build complexity; rely on npm lockfile + cooldown + Go `go.sum` instead |
| Cooldown pinning for claude-engineering-toolkit | Operator maintains the fork, so latest HEAD is trusted |
| Multi-user / shared-host hardening | Single-developer tool by design |
| GPU / CUDA passthrough | Not required for this workload; adds attack surface |
| In-sandbox secrets manager (vault, etc.) | Gateway injects inference credentials via env at runtime; no extra secrets store needed |
| Watch-mode auto-rebuild on file change | Operator should control when supply-chain state is re-pinned |

## Traceability

Populated at roadmap creation. Each requirement maps to exactly one phase.

| Requirement | Phase | Status |
|-------------|-------|--------|
| IMG-01 | Phase 1 | Pending |
| IMG-02 | Phase 1 | Pending |
| IMG-03 | Phase 1 | Pending |
| IMG-04 | Phase 1 | Pending |
| IMG-05 | Phase 1 | Pending |
| PIN-01 | Phase 1 | Pending |
| PIN-02 | Phase 1 | Pending |
| PIN-03 | Phase 1 | Pending |
| PIN-04 | Phase 1 | Pending |
| PIN-05 | Phase 1 | Pending |
| PIN-06 | Phase 1 | Pending |
| PIN-07 | Phase 1 | Pending |
| NET-01 | Phase 3 | Pending |
| NET-02 | Phase 3 | Pending |
| NET-03 | Phase 3 | Pending |
| NET-04 | Phase 3 | Pending |
| NET-05 | Phase 3 | Pending |
| RUN-01 | Phase 4 | Pending |
| RUN-02 | Phase 4 | Pending |
| RUN-03 | Phase 2 | Pending |
| RUN-04 | Phase 2 | Pending |
| BLD-01 | Phase 2 | Pending |
| BLD-02 | Phase 2 | Pending |
| BLD-03 | Phase 2 | Pending |
| BLD-04 | Phase 2 | Pending |
| BLD-05 | Phase 2 | Pending |
| BLD-06 | Phase 2 | Pending |

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
