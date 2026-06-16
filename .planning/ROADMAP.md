# Roadmap: Claude Sandbox (Fedora 44 / OpenShell)

**Milestone:** v1 — Working network-isolated Claude Code sandbox
**Granularity:** Coarse
**Mode:** MVP (vertical slices — each phase produces a running, testable increment)
**Requirements:** 27 v1 requirements across IMG/PIN/NET/RUN/BLD

---

## Phases

- [x] **Phase 1: Dockerfile and Supply-Chain Pinning** - Working image that installs all tooling with rolling cooldown pinning (verification gaps found — PIN-07 gap closure pending) (completed 2026-06-14)
- [x] **Phase 2: Rebuild Script and Sandbox Lifecycle** - Idempotent rebuild.sh that builds the image and recreates the sandbox cleanly (completed 2026-06-15)
- [ ] **Phase 3: Network Isolation and Inference Validation** - Running sandbox with zero direct egress and working model inference via the gateway
- [ ] **Phase 4: Claude Code Launch and MCP Audit** - Claude running autonomously inside the sandbox with toolkit plugins loaded and audited

---

## Phase Details

### Phase 1: Dockerfile and Supply-Chain Pinning

**Goal**: A `podman build` of the Dockerfile succeeds and produces an image with all required tooling installed at cooldown-pinned versions, with a `versions.lock` artifact capturing exact resolved versions.
**Mode:** mvp
**Depends on**: Nothing (first phase)
**Requirements**: IMG-01, IMG-02, IMG-03, IMG-04, IMG-05, PIN-01, PIN-02, PIN-03, PIN-04, PIN-05, PIN-06, PIN-07
**Success Criteria** (what must be TRUE):

  1. `podman build` completes successfully from the Fedora 44 base, installing Go toolchain, golangci-lint, govulncheck, gsd-core, Claude Code CLI, and claude-engineering-toolkit
  2. The build log shows no `CACHED` entry for the `dnf update -y` step when `COOLDOWN_DATE` changes between runs — confirming the cache-bust ARG is working
  3. `govulncheck --version` inside the built image shows a release date on or before the cooldown date (build date minus 4 days), never the current day's `@latest`
  4. A `versions.lock` file records the exact pinned versions of govulncheck, gsd-core, and Claude Code CLI with their cooldown-resolved timestamps
  5. The build fails (exit non-zero) if any pinned package's publish date is after the cooldown date (PIN-07 pin-held verification)**Plans:** 3/3 plans complete

**Wave 1**

- [x] 01-01-PLAN.md — Walking-skeleton resolve->build->lock loop (resolver, Dockerfile, build-and-lock driver, versions.lock)

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 01-02-PLAN.md — Pin-held verifier (PIN-07, fail-closed) + cache-bust & negative-path guarantee tests

**Wave 3** *(gap closure — blocked on Wave 2)*

- [x] 01-03-PLAN.md — Fix CR-01 boundary cutoff comparison (CUTOFF_EXCL) + WARNING hardening (eval allowlist, npm-ls guard, missing-dep surfacing)

### Phase 2: Rebuild Script and Sandbox Lifecycle

**Goal**: A single `rebuild.sh` script runs end-to-end: computes the rolling cooldown, resolves versions, builds the image with podman, tears down any existing sandbox, and creates a new sandbox with the `~/claudeshared` bind mount configured and correct UID alignment.
**Mode:** mvp
**Depends on**: Phase 1
**Requirements**: BLD-01, BLD-02, BLD-03, BLD-04, BLD-05, BLD-06, RUN-03, RUN-04
**Success Criteria** (what must be TRUE):

  1. Running `./rebuild.sh` twice in a row completes without error on the second run — confirming idempotent teardown-and-recreate (no "sandbox already exists" failure)
  2. The image produced is tagged with the build date and carries the cooldown date as an image label, visible via `podman inspect`
  3. `rebuild.sh` output shows timestamped log lines for each major phase (dnf update, npm install, go install, sandbox create)
  4. A file created inside the sandbox at `~/claudeshared/canary.txt` appears on the host at the correct path and is owned by the macOS host user (confirming UID alignment)
  5. The rebuild script hands the podman-built image reference to `openshell sandbox create --from <image-ref>` (not `--from .`) and the sandbox enters the Ready state

**Plans:** 2/2 plans complete

**Wave 1**

- [x] 02-01-PLAN.md — Image provenance slice: Dockerfile ARG BUILD_DATE + cooldown/build LABELs and build-and-lock.sh --build-date flag (BLD-03)

**Wave 2** *(blocked on Wave 1)*

- [x] 02-02-PLAN.md — End-to-end rebuild.sh slice: preflight → build → :latest → idempotent teardown → sandbox create with bind mount + policy.yaml, plus --audit (BLD-01/02/04/05/06, RUN-03/04)

### Phase 3: Network Isolation and Inference Validation

**Goal**: The running sandbox has zero direct internet egress enforced by the OpenShell policy, and Claude Code can successfully complete a model round-trip through the gateway inference broker — no direct connection to `api.anthropic.com` from inside the sandbox.
**Mode:** mvp
**Depends on**: Phase 2
**Requirements**: NET-01, NET-02, NET-03, NET-04, NET-05
**Success Criteria** (what must be TRUE):

  1. `curl https://api.anthropic.com` from inside the running sandbox fails with a proxy error or connection refused (not a successful response)
  2. Claude Code inside the sandbox completes a live multi-turn interactive session — at least two model round-trips succeed via `inference.local` — confirming the gateway broker is working
  3. `rebuild.sh` runs `openshell inference get` as a preflight check before `sandbox create` and exits with a clear error message if the provider is not registered (preventing the 290-second hang)
  4. The rebuild script asserts the egress policy contains no `api.anthropic.com` or other direct Anthropic endpoint — confirming the zero-egress guarantee has not been violated

**Plans:** 2 plans

**Wave 1**

- [ ] 03-01-PLAN.md — Blocking egress-isolation gates: provider preflight (Step 0, NET-03/D-03), live policy assertion (Step 5, NET-04/D-02), blocking egress smoke test (Step 6, NET-05/D-05/NET-01)

**Wave 2** *(blocked on Wave 1 — shares rebuild.sh)*

- [ ] 03-02-PLAN.md — Inference-validation slice: non-fatal round-trip (Step 7, NET-02/D-06), summary banner update, and README operator setup + validation checklist (NET-03/D-04/D-07)

### Phase 4: Claude Code Launch and MCP Audit

**Goal**: Claude launches inside the sandbox with `--dangerously-skip-permissions` and `--plugin-dir` pointing at the cloned toolkit; every plugin either works correctly or fails with a clean expected error (not a network timeout); telemetry noise is suppressed.
**Mode:** mvp
**Depends on**: Phase 3
**Requirements**: RUN-01, RUN-02
**Success Criteria** (what must be TRUE):

  1. `claude --dangerously-skip-permissions --plugin-dir /opt/claude-engineering-toolkit` launches inside the sandbox without errors and reports the toolkit agents/skills as loaded
  2. Each claude-engineering-toolkit plugin is invoked once inside the zero-egress sandbox and either succeeds or fails with a clear, deterministic error — no plugin hangs for more than 10 seconds waiting on a network call
  3. Claude Code startup produces no telemetry or auto-update connection errors in the sandbox logs (confirming `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` is effective)

**Plans**: TBD

---

## Progress Table

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Dockerfile and Supply-Chain Pinning | 3/3 | Complete    | 2026-06-14 |
| 2. Rebuild Script and Sandbox Lifecycle | 2/2 | Complete    | 2026-06-15 |
| 3. Network Isolation and Inference Validation | 0/2 | Planned | - |
| 4. Claude Code Launch and MCP Audit | 0/? | Not started | - |

---

## Coverage

**Total v1 requirements:** 27
**Mapped:** 27/27

| Phase | Requirements |
|-------|-------------|
| Phase 1 | IMG-01, IMG-02, IMG-03, IMG-04, IMG-05, PIN-01, PIN-02, PIN-03, PIN-04, PIN-05, PIN-06, PIN-07 (12 reqs) |
| Phase 2 | BLD-01, BLD-02, BLD-03, BLD-04, BLD-05, BLD-06, RUN-03, RUN-04 (8 reqs) |
| Phase 3 | NET-01, NET-02, NET-03, NET-04, NET-05 (5 reqs) |
| Phase 4 | RUN-01, RUN-02 (2 reqs) |

---
*Roadmap created: 2026-06-13*
