---
phase: 01
slug: dockerfile-and-supply-chain-pinning
status: verified
threats_open: 0
asvs_level: 1
created: 2026-06-14
---

# Phase 01 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.
> Verified by gsd-security-auditor against the implementation (Dockerfile, resolver, verifier, tests).

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| host resolver → public registries | proxy.golang.org / registry.npmjs.org responses parsed by jq | untrusted version metadata + publish timestamps |
| host → podman build (in-image network) | git clone of operator fork + npm/dnf fetches at build time | package tarballs, RPMs, toolkit source |
| `--cooldown-days N` CLI arg → resolver | operator-supplied integer crosses into date arithmetic | untrusted shell input |
| versions.lock / versions-npm.json → verifier | build-produced artifacts are the verifier's input | pinned versions + npm dependency tree |
| resolver stdout → build-and-lock.sh shell | KEY=VALUE lines with registry-controlled version strings | untrusted version strings |
| public registry timestamps → cutoff comparison | millisecond-precision publish instants cross into the cooldown decision | boundary-second timestamps |

---

## Threat Register

| Threat ID | Category | Component | Disposition | Mitigation (evidence) | Status |
|-----------|----------|-----------|-------------|------------------------|--------|
| T-01-01 | Tampering | npm install pin bypass (`@latest`/missing `--before`) | mitigate | Dockerfile:39,44 — `@${VERSION}` ARG + `--before="${COOLDOWN_DATE}T23:59:59Z"`; no `@latest` in Dockerfile/resolve/build scripts | closed |
| T-01-02 | Spoofing | stale cached dnf layer serving outdated RPMs | mitigate | Dockerfile:6 `ARG COOLDOWN_DATE` precedes Dockerfile:15 `RUN dnf update` — cache-bust ordering | closed |
| T-01-03 | Tampering | unvalidated `--cooldown-days` shell input | mitigate | resolve-versions.sh:50 — integer + positivity check, `exit 1` on malformed input | closed |
| T-01-04 | Denial of Service | registry unavailable during resolve | mitigate | resolve-versions.sh:94-97,144-147,169-172 — fail fast `exit 1` on empty/failed curl | closed |
| T-01-05 | Tampering | toolkit `git clone` pulls untrusted HEAD | accept | Accepted risk (see log); Dockerfile:47 `(T-01-05 accept)`; operator owns fork per CLAUDE.md | closed |
| T-01-06 | Information Disclosure | credential baked into image ENV/ARG | mitigate | No credential ARGs/ENVs/keys in Dockerfile; only `ENV ANTHROPIC_BASE_URL=https://inference.local` | closed |
| T-01-SC | Tampering | npm package installs (supply chain) | mitigate | Dockerfile:39,44 explicit pin + `--before`; verify-pins.sh wired as terminal gate at build-and-lock.sh:239 | closed |
| T-01-07 | Elevation of Privilege | verifier fails OPEN, defeating PIN-07 | mitigate | verify-pins.sh:24 `set -euo pipefail`; 68-93 exit 1 on missing/malformed input; 180-181 exit 1 on registry failure | closed |
| T-01-08 | Tampering | transitive dep postdates cooldown, top-level clean | mitigate | verify-pins.sh:215-225 recursive `allpkgs` jq; 236-268 loops + re-queries every transitive pair | closed |
| T-01-09 | Spoofing | stale dnf cache serves pre-roll RPMs | mitigate | tests/test-cache-bust.sh:105,115 — CACHED detection with dnf check; distinct DATE1/DATE2 builds | closed |
| T-01-10 | Elevation of Privilege | boundary-second timestamp mis-classified | mitigate | verify-pins.sh:115 `CUTOFF_EXCL` next-day-midnight; resolve-versions.sh:88,126,154,177 same bound; test-pin-held.sh Cases 2,3 | closed |
| T-01-11 | Tampering | `eval` of registry-controlled resolver output | mitigate | build-and-lock.sh:71-95 — allowlist `case`, regex on COOLDOWN_DATE + versions, `printf -v`; no `eval` | closed |
| T-01-12 | Denial of Service | `npm ls` non-zero exit aborts build | mitigate | Dockerfile:61 — `{ npm ls ... \|\| true; } && jq empty /versions-npm.json` | closed |
| T-01-13 | Tampering | unresolved/missing transitive dep silently dropped | mitigate | verify-pins.sh:221 emits `__MISSING__` sentinel; 242-244 sentinel increments VIOLATIONS, exits non-zero | closed |

*Status: open · closed*
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*

---

## Accepted Risks Log

| Risk ID | Threat Ref | Rationale | Residual Risk | Accepted By | Deferred To | Date |
|---------|------------|-----------|---------------|-------------|-------------|------|
| AR-01 | T-01-05 | Operator explicitly owns and maintains the fork `pheckenlWork/claude-engineering-toolkit` (stated in CLAUDE.md, documented at Dockerfile:47 `(T-01-05 accept)`). Cooldown pinning for the toolkit is out of scope per CLAUDE.md. | MCP network calls from the toolkit plugin could make unintended requests at runtime | Operator (Patrick Heckenlively) | Phase 4 — MCP network call audit | 2026-06-14 |

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-06-14 | 14 | 14 | 0 | gsd-security-auditor (sonnet) |

---

## Notes

- **WR-03 through WR-06** (cosmetic/observability findings from 01-REVIEW.md) were recorded in 01-03-SUMMARY.md as deferred informational findings. They do not affect the fail-closed correctness of PIN-07 and are out of scope for this threat register.
- **IN-02** (govulncheck pre-release filter) was folded into resolve-versions.sh:110 (`^v[0-9]+\.[0-9]+\.[0-9]+$` regex guard on Go-proxy tag selection). Not a separate threat — recorded for completeness.
- No unregistered threat flags: 01-02-SUMMARY.md states no new threat surface was introduced; 01-01 and 01-03 SUMMARYs contain no `## Threat Flags` section.

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed
- [x] `status: verified` set in frontmatter

**Approval:** verified 2026-06-14
