# Phase 1: Dockerfile and Supply-Chain Pinning - Context

**Gathered:** 2026-06-13
**Status:** Ready for planning

<domain>
## Phase Boundary

Deliver a `podman build`-able Dockerfile (`FROM fedora:44`) that installs the full
toolchain — Go (RPM), golangci-lint (RPM), govulncheck (`go install`), gsd-core (npm),
Claude Code CLI (npm), and the claude-engineering-toolkit (git clone, latest HEAD) — at
**cooldown-pinned** versions. Phase 1 also ships a **thin host-side resolver helper** that
computes the cooldown date and resolves the top-level pinned versions so the Dockerfile is
**independently buildable and testable now**, plus produces a `versions.lock` artifact and a
**host-side pin-held verification** that fails the pipeline when any installed pinned package
postdates the cooldown date.

**In scope (Phase 1):** Dockerfile, thin resolver helper, versions.lock generation, pin-held
verification gate, cache-bust ARG for `dnf update`.

**Out of scope (later phases):** the full `rebuild.sh` orchestration + idempotent sandbox
lifecycle (Phase 2 — wraps this resolver), network isolation / gateway inference (Phase 3),
Claude launch flags + MCP plugin audit (Phase 4). The bind mount (RUN-03/04) is Phase 2.
</domain>

<decisions>
## Implementation Decisions

### Version Resolution Boundary (Phase 1 ↔ Phase 2)
- **D-01:** The Dockerfile takes `COOLDOWN_DATE` + pinned-version build ARGs. Phase 1 **also**
  ships a small standalone **resolver helper** (queries the Go proxy + npm registry for "latest
  ≤ cooldown date") so the image can be built/tested on its own. Phase 2's `rebuild.sh` later
  wraps this same helper — do not duplicate the resolution logic in Phase 2.
- **D-02:** Transitive npm dependencies are pinned **in-image** via `npm install -g pkg@VERSION
  --before=DATE`. The host resolver is responsible for top-level pins + the cooldown date; npm
  resolves the transitive tree at build time. (See Claude's Discretion for resolver depth/form.)

### Pin-Held Verification (PIN-07)
- **D-03:** The pin-held check is a **host-side post-build step**, not a Dockerfile `RUN`. The
  build produces `versions.lock`; a host script then validates every recorded publish date
  against the cooldown date and exits non-zero on any violation.
- **D-04 (deliberate refinement of ROADMAP success criterion #5):** Because the gate is
  host-side, the `podman build` itself succeeds and the **pipeline** fails afterward. This is
  intentional — it verifies what npm `--before` *actually* resolved (including transitive deps)
  rather than re-deriving inside the build. The planner should NOT try to force PIN-07 into a
  Dockerfile `RUN`. The net guarantee (a violating pin fails the overall rebuild) is preserved.

### versions.lock (PIN-06)
- **D-05:** Must capture exact installed versions of gsd-core (+ transitive deps), Claude Code
  CLI, and govulncheck, each with its cooldown-resolved timestamp, in a form the host-side
  PIN-07 check can consume. Format and generation mechanism left to planning (see Discretion).

### Base Image
- **D-06:** `FROM fedora:44` by **tag only** — no digest pin. Reproducibility comes from
  cooldown-pinning the tooling plus the intentionally-rolling `dnf update -y`; digest-pinning
  the base would conflict with the rolling-update design.

### Cache Busting (IMG-02)
- **D-07:** An `ARG COOLDOWN_DATE` (or equivalent cache-bust ARG) placed immediately before the
  `RUN dnf update -y` layer so a changed cooldown date busts the cache and updates actually
  re-pull. Validated by ROADMAP success criterion #2 (no `CACHED` on the dnf step across
  differing `COOLDOWN_DATE`).

### Claude's Discretion
- **Resolver depth:** Whether the host resolver outputs only top-level versions + COOLDOWN_DATE
  (relying on in-image `npm --before` for transitive pinning) or pre-resolves the full npm tree
  host-side. User said "you decide" — recommend the lighter top-level approach unless research
  shows `--before` non-determinism; avoid duplicating npm's work.
- **Resolver form:** Bash vs Go program. User said "you decide" — weigh simplicity and clean
  composability into Phase 2's `rebuild.sh` (a bash helper composes most naturally; the Go
  toolchain is already present if typed/testable resolution is preferred).
- **versions.lock format:** JSON vs plain text/key=value, and in-image vs host-side generation.
  Pick whatever the host-side PIN-07 verifier consumes most cleanly (structured JSON is the
  safer default for machine parsing).
</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project specs & requirements
- `CLAUDE.md` — authoritative tech-stack spec: exact install mechanisms, pinned versions
  (govulncheck v1.3.0, gsd-core 1.4.0, Claude Code 2.1.169 as of the documented cutoff),
  `npm --before` semantics, the complete Dockerfile pattern, "What NOT to Use" anti-patterns,
  and version-compatibility matrix. MUST read before planning.
- `.planning/REQUIREMENTS.md` §IMG (IMG-01..05) and §PIN (PIN-01..07) — the 12 requirements
  this phase satisfies.
- `.planning/ROADMAP.md` → "Phase 1" — goal + 5 success criteria (notably #2 cache-bust, #3
  govulncheck date ≤ cooldown, #4 versions.lock, #5 pin-held fail).

### External resources (queried host-side by the resolver)
- `https://proxy.golang.org/golang.org/x/vuln/@v/<tag>.info` — Go proxy timestamps for
  govulncheck version selection (PIN-03).
- `https://registry.npmjs.org/@opengsd/gsd-core` and `.../@anthropic-ai/claude-code` — npm
  registry for gsd-core / Claude Code version selection (PIN-04, PIN-05).
- `https://docs.npmjs.com/cli/v11/commands/npm-install#before` — `--before` applies to all
  transitive deps (basis for D-02).
- claude-engineering-toolkit clone source: `https://github.com/pheckenlWork/claude-engineering-toolkit.git`
  (default branch, latest HEAD, no cooldown — IMG-05).
</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- None yet — greenfield repo. Tracked files are only `CLAUDE.md`, `LICENSE`, `README.md`. No
  existing Dockerfile, scripts, or `.planning/codebase/` maps.

### Established Patterns
- `CLAUDE.md` "Summary: Complete Dockerfile Pattern" section is the canonical skeleton to
  follow (system packages → govulncheck → gsd-core → Claude Code → toolkit clone).

### Integration Points
- The resolver helper is the explicit hand-off seam to Phase 2: `rebuild.sh` will call it to
  compute cooldown + versions, then pass them as build ARGs. Design its CLI/output contract to
  be wrapper-friendly.
</code_context>

<specifics>
## Specific Ideas

- All exact pinned versions, RPM versions (golang 1.26.4-2.fc44, golangci-lint 2.11.3-1.fc44),
  and install commands are already enumerated in `CLAUDE.md` — treat that file as the source of
  truth rather than re-researching from scratch; research should confirm/refresh against the
  rolling cooldown, not rediscover.
</specifics>

<deferred>
## Deferred Ideas

- ERG-01 (Makefile wrapper) and VER-01 (`policy prove` formal verification) are explicitly v2
  — not this phase.
- Phase 2 will own idempotent teardown/recreate, build-date image tag + cooldown image label,
  per-phase timestamped logging, and the bind mount. Keep them out of Phase 1.

None raised during discussion that aren't already tracked in REQUIREMENTS.md — discussion
stayed within phase scope.
</deferred>

---

*Phase: 1-Dockerfile and Supply-Chain Pinning*
*Context gathered: 2026-06-13*
