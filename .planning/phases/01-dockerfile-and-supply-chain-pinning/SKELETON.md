# Walking Skeleton — Claude Sandbox (Fedora 44 / OpenShell)

**Phase:** 1
**Generated:** 2026-06-13

## Capability Proven End-to-End

> One sentence: the smallest end-to-end loop that exercises the whole supply-chain pipeline.

Running `scripts/build-and-lock.sh --cooldown-days 4` resolves the rolling cooldown date and
pinned tool versions on the host, builds a `fedora:44` image installing all six tools at those
pins, emits a `versions.lock`, and runs a host-side pin-held verifier that fails the pipeline
closed if any installed package postdates the cooldown — proving the full resolve -> build ->
lock -> verify loop works.

## Architectural Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Image base | `FROM fedora:44`, tag only (no digest) | D-06: reproducibility comes from cooldown-pinning the tooling + intentionally rolling `dnf update`; digest-pinning the base would conflict with the rolling-update design. |
| Build driver | `podman build` (not docker) | OpenShell gateway uses the Podman driver; CLAUDE.md "What NOT to Use" forbids the Docker daemon. |
| Version resolution | Host-side bash resolver (`scripts/resolve-versions.sh`) producing build ARGs | D-01: resolver is the explicit hand-off seam Phase 2's `rebuild.sh` wraps. Bash composes naturally via `eval`/source; no compile step; jq available on host. |
| Resolver depth | Top-level pins only; npm `--before` handles transitive at build time | D-02 + RESEARCH discretion: npm Arborist is authoritative for the transitive tree; duplicating it host-side adds no accuracy. |
| Transitive cooldown | In-image `npm install -g pkg@VERSION --before=${COOLDOWN_DATE}` | npm `--before` rebuilds the full Arborist tree with a date filter — a first-class registry feature, not a workaround. |
| Cache busting | `ARG COOLDOWN_DATE` declared immediately before `RUN dnf update -y` | D-07 / IMG-02: ARG change busts the cache so a rolled cooldown date actually re-pulls RPMs. |
| versions.lock | JSON, hybrid generation (in-image `npm ls` snapshot + host-merged timestamps) | D-05 + RESEARCH discretion: jq-parseable; in-image snapshot captures what was actually installed including transitive deps. |
| Pin-held verification (PIN-07) | Host-side post-build script (`scripts/verify-pins.sh`), fail-closed | D-03/D-04: verifies what `--before` ACTUALLY resolved (incl. transitive) rather than re-deriving inside the build; podman build succeeds, pipeline fails after on violation. |
| Resolver/verifier language | bash + jq + python3 (date arithmetic) | RESEARCH: all confirmed on host; `python3` for date math because macOS `date` lacks GNU `-d`. |
| Directory layout | `Dockerfile` at root; helpers in `scripts/`; tests in `tests/` | RESEARCH Recommended Project Structure; keeps the Phase 2 `rebuild.sh` hand-off clean. |

## Stack Touched in Phase 1

- [x] Project scaffold — `Dockerfile`, `scripts/`, `tests/`, `.dockerignore` created (greenfield repo had none)
- [x] Real "read/write" — host reads live registry timestamps (proxy.golang.org, registry.npmjs.org); writes `versions.lock`, `versions-npm.json`, `versions-govulncheck.txt`
- [x] Real interactive entry point — `scripts/build-and-lock.sh --cooldown-days N` runs the full loop; `scripts/resolve-versions.sh` is the reusable seam
- [x] Verification gate — `scripts/verify-pins.sh` fails the pipeline closed on any post-cooldown pin
- [x] Local full-stack run command — `bash scripts/build-and-lock.sh --cooldown-days 4` exercises resolve -> build -> lock -> verify end-to-end

## Out of Scope (Deferred to Later Slices)

> Explicit, to prevent later phases re-litigating Phase 1's minimalism.

- `rebuild.sh` orchestration, idempotent sandbox teardown/recreate, build-date image tag + cooldown image label, per-phase timestamped logging, the `~/claudeshared` bind mount, UID alignment — **Phase 2** (BLD-01..06, RUN-03/04).
- Zero-egress network policy, gateway inference brokering, `ANTHROPIC_BASE_URL`, provider credential injection, egress smoke test — **Phase 3** (NET-01..05).
- Claude launch flags (`--dangerously-skip-permissions`, `--plugin-dir`), MCP plugin audit, telemetry suppression — **Phase 4** (RUN-01/02).
- Cooldown pinning for claude-engineering-toolkit — out of scope by design (operator owns the fork, latest HEAD trusted).
- ERG-01 (Makefile wrapper) and VER-01 (`policy prove`) — v2, deferred.

## Subsequent Slice Plan

Each later phase adds one vertical slice on top of this skeleton without altering its
architectural decisions (the resolver seam, the Dockerfile, the lock/verify contract):

- **Phase 2:** `rebuild.sh` wraps `resolve-versions.sh` + `build-and-lock.sh`, then tears down and recreates the OpenShell sandbox with the bind mount — operator can rebuild the running sandbox on demand.
- **Phase 3:** the recreated sandbox enforces zero egress and brokers inference through the gateway — Claude can complete a model round-trip with no direct internet reach.
- **Phase 4:** Claude launches autonomously inside the isolated sandbox with the toolkit plugins loaded and audited.
