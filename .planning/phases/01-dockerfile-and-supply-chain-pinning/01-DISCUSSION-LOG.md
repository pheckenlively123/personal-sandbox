# Phase 1: Dockerfile and Supply-Chain Pinning - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-13
**Phase:** 1-Dockerfile and Supply-Chain Pinning
**Areas discussed:** Version resolution split, Pin-held verification, versions.lock, Base image pin, Resolver scope, Resolver form

---

## Version Resolution Split (Phase 1 ↔ Phase 2)

| Option | Description | Selected |
|--------|-------------|----------|
| ARGs + thin resolver helper | Dockerfile takes COOLDOWN_DATE + version ARGs; Phase 1 ships a standalone resolver so the image is independently buildable/testable. Phase 2 wraps it. | ✓ |
| ARGs only, defer resolver | Dockerfile with ARGs + defaults only; all resolution in Phase 2's rebuild.sh. | |
| Self-contained, resolve in-image | Dockerfile resolves versions itself at build time; only COOLDOWN_DATE passed in. | |

**User's choice:** ARGs + thin resolver helper
**Notes:** Phase 1 must be testable on its own; resolver is the explicit hand-off seam to Phase 2.

---

## Pin-Held Verification (PIN-07)

| Option | Description | Selected |
|--------|-------------|----------|
| In-Dockerfile RUN step | RUN queries publish dates and exits non-zero on violation, inside the build. | |
| Host-side post-build check | Build produces versions.lock; separate host script validates dates and fails. | ✓ |
| Both | In-build RUN gate + host-side re-check. | |

**User's choice:** Host-side post-build check
**Notes:** Recorded as a deliberate refinement of ROADMAP success criterion #5 — `podman build` succeeds, pipeline fails afterward. Verifies what npm `--before` actually resolved (incl. transitive deps). Planner should not force this into a Dockerfile RUN.

---

## versions.lock (PIN-06)

| Option | Description | Selected |
|--------|-------------|----------|
| JSON, generated in-image | RUN queries installed versions, writes structured JSON, extracted from image. | |
| Plain text/key=value, in-image | Human-readable name=version@timestamp lines. | |
| You decide | Planner picks format based on what PIN-07 verification consumes. | ✓ |

**User's choice:** You decide
**Notes:** Deferred to planner; structured JSON recommended as safer default for the host-side verifier.

---

## Base Image Pin

| Option | Description | Selected |
|--------|-------------|----------|
| Tag only (fedora:44) | FROM fedora:44; reproducibility from cooldown pins + rolling dnf update. | ✓ |
| Digest-pinned base | FROM fedora:44@sha256:... resolved per build. | |
| You decide | Let research weigh it. | |

**User's choice:** Tag only (fedora:44)
**Notes:** Digest pin would conflict with the intentionally-rolling dnf update design.

---

## Resolver Scope

| Option | Description | Selected |
|--------|-------------|----------|
| Top-level versions + COOLDOWN_DATE | Resolver sets top-level pins + date; npm --before pins transitive deps in-image. | |
| Full tree incl. transitive | Resolver pre-resolves full npm tree host-side. | |
| You decide | Planner settles resolver depth. | ✓ |

**User's choice:** You decide
**Notes:** Recommended lighter top-level approach unless research shows `npm --before` non-determinism.

---

## Resolver Form

| Option | Description | Selected |
|--------|-------------|----------|
| Bash script | Standalone bash (curl/jq) printing resolved versions; composes into rebuild.sh. | |
| Go program | Small Go program (toolchain already present); typed/testable. | |
| You decide | Planner chooses on simplicity + Phase 2 composability. | ✓ |

**User's choice:** You decide
**Notes:** Bash composes most naturally into Phase 2's rebuild.sh; Go available if typed resolution preferred.

---

## Claude's Discretion

- Resolver depth (top-level vs full transitive tree)
- Resolver implementation language/form (bash vs Go)
- versions.lock format and generation mechanism (JSON vs text; in-image vs host-side)

## Deferred Ideas

- None new — discussion stayed within phase scope. ERG-01 (Makefile) and VER-01 (`policy prove`) remain v2; Phase 2 owns rebuild.sh orchestration, image tagging/labels, logging, and the bind mount.
