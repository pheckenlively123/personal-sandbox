---
scope: phase-01
milestone: v1.0
audited: 2026-06-14
status: passed
note: "Phase-scoped audit (milestone v1.0 is 25% complete; full milestone audit deferred until all 4 phases done)"
scores:
  requirements: 12/12
  phase_verification: 1/1
  integration: n/a (single phase — no cross-phase seams yet)
  nyquist: skipped (workflow.nyquist_validation=false)
gaps: []
tech_debt:
  - phase: 01-dockerfile-and-supply-chain-pinning
    items:
      - "WR-01 (re-review): verify-pins.sh allpkgs jq tests has('version') before .missing/.invalid — an {invalid:true, version:X} node is date-checked only; latent, zero affected nodes in current snapshot"
      - "WR-02 (re-review): Dockerfile npm --before uses T23:59:59Z while resolver/verifier use CUTOFF_EXCL next-day-midnight — theoretical 1-second resolve-vs-install mismatch on the cutoff day; explicitly deferred in 01-03"
      - "IN-01 (re-review): build-and-lock.sh process-substitution exit code not propagated; post-loop empty-var guard is adequate for current resolver behavior"
      - "WR-03 (re-review): verify-pins.sh counts one network failure as two VIOLATIONS — fail-closed intact, audit count inflated"
      - "WR-04 (re-review): test-cache-bust.sh uses a string-proximity heuristic that can default to PASS if podman output format changes"
      - "REQUIREMENTS.md hygiene: VER-01 and ERG-01 appear in the v2 body but are missing from the Traceability table (flagged by phase.complete) — add rows to keep traceability in sync"
      - "SUMMARY convention: 01-01 and 01-02 SUMMARY frontmatter use dependency_graph but omit requirements_completed; 3-source cross-check fell back to VERIFICATION.md evidence for IMG-01..05, PIN-02, PIN-06"
---

# Phase 01 Audit — Dockerfile and Supply-Chain Pinning

**Scope:** Phase 01 only (requested). Milestone v1.0 is 1/4 phases complete; a full
`/gsd-audit-milestone` is premature and deferred until Phases 2–4 are executed.

**Verdict:** PASSED — all 12 Phase 01 requirements satisfied, no critical gaps. Accumulated
tech debt is WARNING/INFO-level and was deliberately deferred during execution.

## Requirements Coverage (3-Source Cross-Reference)

| REQ-ID | Description | REQUIREMENTS.md | VERIFICATION.md | SUMMARY frontmatter | Final |
|--------|-------------|-----------------|-----------------|---------------------|-------|
| IMG-01 | FROM fedora:44 | [x] Complete | SATISFIED (Dockerfile:1) | via dependency_graph | satisfied |
| IMG-02 | dnf update cache-busted per rebuild | [x] Complete | SATISFIED (ARG ordering + test) | via dependency_graph | satisfied |
| IMG-03 | Go via RPM | [x] Complete | SATISFIED (Dockerfile dnf) | via dependency_graph | satisfied |
| IMG-04 | golangci-lint via RPM | [x] Complete | SATISFIED (Dockerfile dnf) | via dependency_graph | satisfied |
| IMG-05 | toolkit cloned at build time | [x] Complete | SATISFIED (Dockerfile:47-48) | via dependency_graph | satisfied |
| PIN-01 | cooldown = build date − N (rolling) | [x] Complete | SATISFIED (resolve-versions.sh:56) | 01-03 listed | satisfied |
| PIN-02 | overridable via --cooldown-days | [x] Complete | SATISFIED (behavioral spot-check) | via dependency_graph | satisfied |
| PIN-03 | govulncheck pinned ≤ cooldown | [x] Complete | SATISFIED (go install @VERSION) | 01-03 listed | satisfied |
| PIN-04 | gsd-core + transitive via --before | [x] Complete | SATISFIED (npm --before) | 01-03 listed | satisfied |
| PIN-05 | Claude Code pinned ≤ cooldown | [x] Complete | SATISFIED (npm --before) | 01-03 listed | satisfied |
| PIN-06 | versions.lock with timestamps | [x] Complete | SATISFIED (lock fields) | via dependency_graph | satisfied |
| PIN-07 | pin-held verification fails build | [x] Complete | SATISFIED (CR-01 closed; CUTOFF_EXCL) | 01-03 listed | satisfied |

**Score: 12/12 satisfied.** No unsatisfied or orphaned requirements. VER-01/ERG-01 are v2
(future milestone), correctly out of scope.

## Phase Verification

| Phase | VERIFICATION.md | Status | Score | Human items |
|-------|-----------------|--------|-------|-------------|
| 01 | present | verified | 5/5 truths | closed via 01-UAT.md (3/3 passed on podman host) |

## Integration

Cross-phase integration: **N/A** — Phase 01 is the only built phase; no downstream phases
exist to wire against. Intra-phase pipeline wiring (resolve-versions.sh → build-and-lock.sh →
Dockerfile → image extraction → versions.lock → verify-pins.sh) is verified WIRED in
`01-VERIFICATION.md` (Key Link Verification, 7/7 links). Phase 2 seams are documented in the
SUMMARY `dependency_graph` blocks (resolve-versions.sh and build-and-lock.sh are the declared
Phase 2 wrap points).

## Security

`01-SECURITY.md` present — threats_open: 0, 14 threats dispositioned (13 mitigated + verified,
1 accepted risk AR-01 deferred to Phase 4 MCP audit).

## Nyquist

Skipped — `workflow.nyquist_validation` is `false` in config.json.

## Tech Debt

See frontmatter `tech_debt`. 5 WARNING/INFO code findings (all deliberately deferred in 01-03)
plus 2 documentation-hygiene items (REQUIREMENTS.md traceability rows for VER-01/ERG-01; SUMMARY
`requirements_completed` convention in 01-01/01-02). None block phase or milestone progress.
