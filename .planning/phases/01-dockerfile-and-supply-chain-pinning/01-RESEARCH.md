# Phase 1: Dockerfile and Supply-Chain Pinning - Research

**Researched:** 2026-06-13
**Domain:** Container image build, supply-chain pinning, Podman/OCI, npm cooldown pinning
**Confidence:** HIGH (all versions verified against live registries; design choices anchored in CLAUDE.md)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**D-01:** The Dockerfile takes `COOLDOWN_DATE` + pinned-version build ARGs. Phase 1 also ships a small standalone resolver helper (queries the Go proxy + npm registry for "latest ≤ cooldown date") so the image can be built/tested on its own. Phase 2's `rebuild.sh` later wraps this same helper — do not duplicate the resolution logic in Phase 2.

**D-02:** Transitive npm dependencies are pinned in-image via `npm install -g pkg@VERSION --before=DATE`. The host resolver is responsible for top-level pins + the cooldown date; npm resolves the transitive tree at build time.

**D-03:** The pin-held check is a host-side post-build step, not a Dockerfile `RUN`. The build produces `versions.lock`; a host script then validates every recorded publish date against the cooldown date and exits non-zero on any violation.

**D-04 (deliberate refinement of ROADMAP success criterion #5):** Because the gate is host-side, the `podman build` itself succeeds and the pipeline fails afterward. This is intentional — it verifies what npm `--before` actually resolved (including transitive deps) rather than re-deriving inside the build. The planner should NOT try to force PIN-07 into a Dockerfile RUN. The net guarantee (a violating pin fails the overall rebuild) is preserved.

**D-05:** versions.lock must capture exact installed versions of gsd-core (+ transitive deps), Claude Code CLI, and govulncheck, each with its cooldown-resolved timestamp, in a form the host-side PIN-07 check can consume. Format and generation mechanism left to planning (see Discretion).

**D-06:** `FROM fedora:44` by tag only — no digest pin. Reproducibility comes from cooldown-pinning the tooling plus the intentionally-rolling `dnf update -y`; digest-pinning the base would conflict with the rolling-update design.

**D-07:** An `ARG COOLDOWN_DATE` (or equivalent cache-bust ARG) placed immediately before the `RUN dnf update -y` layer so a changed cooldown date busts the cache and updates actually re-pull.

### Claude's Discretion

- **Resolver depth:** Whether the host resolver outputs only top-level versions + COOLDOWN_DATE (relying on in-image `npm --before` for transitive pinning) or pre-resolves the full npm tree host-side. User said "you decide."
- **Resolver form:** Bash vs Go program. User said "you decide."
- **versions.lock format:** JSON vs plain text/key=value, and in-image vs host-side generation. Pick whatever the host-side PIN-07 verifier consumes most cleanly.

### Deferred Ideas (OUT OF SCOPE)

- ERG-01 (Makefile wrapper) and VER-01 (`policy prove` formal verification) are explicitly v2.
- Phase 2 owns: idempotent teardown/recreate, build-date image tag + cooldown image label, per-phase timestamped logging, bind mount.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| IMG-01 | Sandbox image builds from `FROM fedora:44` | Base image confirmed available; tag-only pin per D-06 |
| IMG-02 | All RPM packages updated during build (`dnf update -y`) with cache-bust per rebuild | ARG-before-RUN cache-bust mechanism verified (D-07) |
| IMG-03 | Go toolchain installed via RPM (`golang`) | golang-1.26.4-2.fc44 confirmed in Koji f44 tag |
| IMG-04 | golangci-lint installed via RPM | golangci-lint-2.11.3-1.fc44 confirmed in Koji f44 tag |
| IMG-05 | claude-engineering-toolkit cloned at build time from pheckenlWork/claude-engineering-toolkit | Repo confirmed reachable; build-time network available in podman build |
| PIN-01 | Cooldown date computed as build date minus N days (default 4), rolling | Resolver helper computes: `date -d "today - N days"` or `python3` date arithmetic |
| PIN-02 | Cooldown window overridable via `--cooldown-days N` arg to resolver helper | Resolver accepts CLI arg; default 4 |
| PIN-03 | govulncheck pinned to latest released version as of cooldown date (Go proxy) | v1.3.0 confirmed as latest ≤ 2026-06-09; Go proxy query pattern documented |
| PIN-04 | gsd-core pinned to latest as of cooldown date, `--before` applies to transitive deps | 1.4.3 confirmed as latest ≤ 2026-06-09; npm --before transitive behavior verified |
| PIN-05 | Claude Code CLI pinned to latest as of cooldown date | 2.1.170 confirmed as latest ≤ 2026-06-09 |
| PIN-06 | versions.lock captures exact installed versions + timestamps | In-image generation via Dockerfile RUN; extraction via `podman create` + `podman cp` |
| PIN-07 | Pin-held verification fails pipeline if any package postdates cooldown | Host-side verifier queries registry timestamps + compares; exits 1 on violation |
</phase_requirements>

---

## Summary

Phase 1 delivers three artifacts: (1) a `podman build`-able Dockerfile (`FROM fedora:44`) that installs the complete toolchain at cooldown-pinned versions, (2) a thin bash resolver helper that computes the rolling cooldown date and resolves top-level pinned versions from live registries, and (3) a host-side pin-held verifier that validates the installed versions against the cooldown date and exits non-zero on any violation.

All core design decisions are locked (D-01 through D-07 in CONTEXT.md). The technology stack is fully specified in CLAUDE.md and verified against live registries as of 2026-06-13: govulncheck v1.3.0, gsd-core 1.4.3, Claude Code 2.1.170 are the correct cooldown-pinned versions for today's build (cooldown date: 2026-06-09). CLAUDE.md's listed versions for gsd-core (1.4.0) and Claude Code (2.1.169) are outdated — three new gsd-core versions and one new Claude Code version were published on 2026-06-09, all within the inclusive cooldown window.

The primary discretion calls resolved by this research: (a) **bash for the resolver helper** (simpler, no compile step, composes naturally into Phase 2's rebuild.sh, jq available on host), (b) **top-level pins only from resolver** (npm --before handles transitive; determinism risk is LOW due to layer caching), and (c) **JSON format for versions.lock** generated inside the Dockerfile and extracted host-side via `podman create` + `podman cp`.

**Primary recommendation:** Follow the complete Dockerfile pattern in CLAUDE.md verbatim, substituting the refreshed version pins (1.4.3, 2.1.170), with a bash resolver helper producing JSON output consumed by both podman build and the pin-held verifier.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Cooldown date computation | Host (resolver helper) | — | Must run before podman build to compute build ARGs |
| Version resolution (top-level) | Host (resolver helper) | — | Queries Go proxy + npm registry; needs network; runs on host pre-build |
| Version resolution (transitive npm) | In-image (npm --before at build time) | — | npm resolves transitive tree from registry during RUN layer |
| Package installation | In-image (Dockerfile RUN) | — | dnf, go install, npm install -g execute inside the container build |
| versions.lock generation | In-image (Dockerfile RUN) | — | `npm ls -g --json` captures what was actually installed |
| versions.lock extraction | Host (post-build) | — | `podman create` + `podman cp` extracts from built image |
| Pin-held verification | Host (post-build script) | — | Queries registries for publish timestamps; compares to cooldown date |
| Toolkit source availability | Build-time network | — | `git clone` runs in Dockerfile RUN; has host network access |

---

## Standard Stack

### Core

| Tool | Version | Purpose | Source |
|------|---------|---------|--------|
| `fedora` base image | `44` (tag, no digest) | Container base OS | [VERIFIED: docker.io/library/fedora:44, last pushed 2026-05-28] |
| `golang` RPM | `1.26.4-2.fc44` | Go toolchain in image | [VERIFIED: Koji f44 tag, buildID 2957394-area] |
| `golangci-lint` RPM | `2.11.3-1.fc44` | Go linter in image | [VERIFIED: Koji buildID 2957394 confirmed golangci-lint-2.11.3-1.fc44] |
| `govulncheck` | `v1.3.0` | Go vulnerability scanner | [VERIFIED: proxy.golang.org, published 2026-04-22T22:03:04Z, still latest] |
| `@opengsd/gsd-core` | `1.4.3` | GSD workflow engine + Claude hooks | [VERIFIED: registry.npmjs.org, published 2026-06-09T17:49:11Z] |
| `@anthropic-ai/claude-code` | `2.1.170` | Claude Code CLI | [VERIFIED: registry.npmjs.org, published 2026-06-09T16:15:44Z] |
| `claude-engineering-toolkit` | latest HEAD | Claude plugins/agents | [VERIFIED: github.com/pheckenlWork/claude-engineering-toolkit, reachable] |
| `podman` | `5.8.2` (host) | Build driver | [VERIFIED: host `podman version`] |
| `npm` | `11.x` (Fedora 44 nodejs) | Package manager for in-image installs | [ASSUMED: Fedora 44 nodejs provides npm 11] |
| `jq` | `1.7.1` (host) | JSON parsing in bash resolver/verifier | [VERIFIED: host `jq --version`] |
| `bash` | `5.3.x` (host) | Resolver helper + verifier language | [VERIFIED: host `bash --version`] |

### Refreshed Version Pins (2026-06-13, cooldown: 2026-06-09)

**CLAUDE.md is outdated for gsd-core and Claude Code.** Three gsd-core versions and one Claude Code version were published on 2026-06-09 (within the inclusive cooldown window). The planner MUST use the values below, not those in CLAUDE.md:

| Package | CLAUDE.md Pin | Correct Pin (live registry) | Change |
|---------|--------------|---------------------------|--------|
| govulncheck | v1.3.0 | **v1.3.0** | Unchanged |
| @opengsd/gsd-core | 1.4.0 | **1.4.3** | Updated (3 new versions on cutoff day) |
| @anthropic-ai/claude-code | 2.1.169 | **2.1.170** | Updated (published 2026-06-09T16:15Z) |

**Supporting install packages (no change required):**

| Library | Purpose | When to Use |
|---------|---------|-------------|
| `nodejs`, `npm`, `git`, `ca-certificates` | RPM dependencies for npm installs and git clone | Install via `dnf install -y` before npm steps |

**Installation commands (Dockerfile):**

```bash
# System packages
RUN dnf install -y nodejs npm git ca-certificates

# govulncheck (via go install, version from ARG)
RUN go install golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}

# gsd-core (version + cooldown date from ARGs)
RUN npm install -g @opengsd/gsd-core@${GSD_CORE_VERSION} --before=${COOLDOWN_DATE} \
    && gsd-core --claude --global

# Claude Code CLI (version + cooldown date from ARGs)
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} --before=${COOLDOWN_DATE}

# Toolkit clone (latest HEAD, no cooldown)
RUN git clone https://github.com/pheckenlWork/claude-engineering-toolkit.git \
    /opt/claude-engineering-toolkit
```

---

## Package Legitimacy Audit

> Package Legitimacy Gate run via `gsd-tools query package-legitimacy check` on 2026-06-13.

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| @opengsd/gsd-core | npm | ~2 weeks (first release 2026-05-31) | 12,802/wk | github.com/open-gsd/gsd-core | SUS (too-new) | **Approved** — project's own toolchain, explicitly specified in CLAUDE.md and CONTEXT.md. Not a discovered package. |
| @anthropic-ai/claude-code | npm | ~6 months (2026-01-07) | 11,825,521/wk | no-repo-field (known Anthropic package) | SUS (too-new, no-repository) | **Approved** — Anthropic's official CLI, explicitly specified in CLAUDE.md. `postinstall: node install.cjs` is expected behavior (confirmed in CLAUDE.md "What NOT to Use" section). No `checkpoint:human-verify` needed. |

**Packages removed due to SLOP verdict:** none

**Packages flagged as SUS but pre-approved:** Both packages are locked decisions from CLAUDE.md — they are the project's own toolchain specifications, not discovered via WebSearch or training data. The seam flags them "too-new" because they are recent packages; this is expected for a new project's tooling stack.

**govulncheck:** Installed via `go install` from `proxy.golang.org` — not an npm package, no legitimacy check needed for this tool. The Go module path `golang.org/x/vuln` is the official Google-maintained vulnerability scanner.

---

## Architecture Patterns

### System Architecture Diagram

```
HOST MACHINE (macOS)
  │
  ├── resolve-versions.sh  ──────┬── curl proxy.golang.org ──→ govulncheck: v1.3.0
  │   (bash resolver helper)     ├── curl registry.npmjs.org ──→ gsd-core: 1.4.3
  │   Inputs: --cooldown-days N  └── curl registry.npmjs.org ──→ claude-code: 2.1.170
  │   Outputs: COOLDOWN_DATE, GOVULNCHECK_VERSION,
  │             GSD_CORE_VERSION, CLAUDE_CODE_VERSION
  │
  ├── podman build                    ←── reads build ARGs from resolver output
  │     │
  │     │  CONTAINER BUILD ENVIRONMENT (has host network via NAT)
  │     ├── FROM fedora:44
  │     ├── ARG COOLDOWN_DATE (cache-bust anchor)
  │     ├── RUN dnf update -y && dnf install -y ...    [cache busted by COOLDOWN_DATE]
  │     ├── RUN go install govulncheck@${GOVULNCHECK_VERSION}
  │     ├── RUN npm install -g gsd-core@${GSD_CORE_VERSION} --before=${COOLDOWN_DATE}
  │     │         └── npm resolves transitive deps ≤ COOLDOWN_DATE via Arborist
  │     ├── RUN npm install -g claude-code@${CLAUDE_CODE_VERSION} --before=${COOLDOWN_DATE}
  │     ├── RUN git clone ...claude-engineering-toolkit /opt/toolkit
  │     └── RUN npm ls -g --json > /versions-npm.json \
  │             && govulncheck --version > /versions-govulncheck.txt
  │
  ├── podman create sandbox-image → CID
  ├── podman cp $CID:/versions-npm.json ./versions-npm.json
  ├── podman cp $CID:/versions-govulncheck.txt ./versions-govulncheck.txt
  ├── [resolver merges into versions.lock JSON]
  ├── podman rm $CID
  │
  └── verify-pins.sh                  ←── reads versions.lock
        For each package in versions.lock:
          query registry timestamp
          compare timestamp ≤ COOLDOWN_DATE end-of-day
          exit 1 if violation
        exit 0 if all clean
```

### Recommended Project Structure

```
/
├── Dockerfile                    # Main build file (FROM fedora:44)
├── scripts/
│   ├── resolve-versions.sh       # Host-side resolver helper (Phase 1, consumed by Phase 2)
│   └── verify-pins.sh            # Host-side PIN-07 verifier
└── versions.lock                 # Generated artifact (git-ignored or committed per preference)
```

### Pattern 1: ARG Cache-Busting for dnf update

**What:** Place `ARG COOLDOWN_DATE` immediately before `RUN dnf update -y`. Changing the ARG value invalidates the build cache for all subsequent layers, forcing dnf to re-pull.

**When to use:** Every `dnf update -y` layer that must re-run when the cooldown date rolls.

**Why it works:** OCI build cache keys include ARG values in scope at each layer. When `COOLDOWN_DATE` changes (via `--build-arg`), the cache miss propagates to all downstream RUN layers. This is standard OCI/Buildah behavior used by `podman build`. [VERIFIED: docs.docker.com/build/cache/invalidation — "Build arguments do result in cache invalidation"]

**Example:**

```dockerfile
# Source: CLAUDE.md "Summary: Complete Dockerfile Pattern" + Docker cache invalidation docs
FROM fedora:44

# System packages ARG — placed BEFORE dnf update to bust cache when date changes
ARG COOLDOWN_DATE
ARG GOVULNCHECK_VERSION
ARG GSD_CORE_VERSION
ARG CLAUDE_CODE_VERSION

# Cache-busting: this layer re-runs whenever COOLDOWN_DATE changes
RUN dnf update -y && \
    dnf install -y golang golangci-lint nodejs npm git ca-certificates && \
    dnf clean all

# govulncheck — pinned to version from ARG
RUN go install golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}

# gsd-core — top-level pin + transitive date boundary
RUN npm install -g @opengsd/gsd-core@${GSD_CORE_VERSION} --before=${COOLDOWN_DATE} && \
    gsd-core --claude --global

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} --before=${COOLDOWN_DATE}

# Toolkit — latest HEAD, no cooldown (operator-maintained fork)
RUN git clone https://github.com/pheckenlWork/claude-engineering-toolkit.git \
    /opt/claude-engineering-toolkit

# Generate in-image version snapshot (extracted by host post-build)
RUN npm ls -g --json --depth=Infinity > /versions-npm.json && \
    govulncheck --version > /versions-govulncheck.txt && \
    echo "{}" > /versions.lock
```

### Pattern 2: Resolver Helper (Bash)

**What:** A bash script that computes COOLDOWN_DATE and queries live registries for the latest version of each pinned package on or before that date.

**When to use:** Run before every `podman build` call. Phase 2's rebuild.sh calls it and passes the output as `--build-arg` flags.

**CLI contract (wrapper-friendly for Phase 2):**

```bash
# Usage: ./scripts/resolve-versions.sh [--cooldown-days N]
# Outputs (one per line, KEY=VALUE, sourceable by bash):
#   COOLDOWN_DATE=2026-06-09
#   GOVULNCHECK_VERSION=v1.3.0
#   GSD_CORE_VERSION=1.4.3
#   CLAUDE_CODE_VERSION=2.1.170

# Key resolution patterns:
# govulncheck: fetch Go proxy list, for each tag get .info Time, find latest <= cutoff
VULN_LIST=$(curl -s "https://proxy.golang.org/golang.org/x/vuln/@v/list")
for TAG in $VULN_LIST; do
    INFO=$(curl -s "https://proxy.golang.org/golang.org/x/vuln/@v/${TAG}.info")
    PUB=$(echo "$INFO" | jq -r '.Time')
    # compare PUB <= "${COOLDOWN_DATE}T23:59:59Z" (ISO-8601 lexicographic)
done

# npm packages: fetch full registry doc, extract .time object, find latest <= cutoff
GSD_VER=$(curl -s "https://registry.npmjs.org/@opengsd/gsd-core" | \
    jq -r --arg cutoff "${COOLDOWN_DATE}T23:59:59Z" \
    '.time | to_entries | map(select(.key != "created" and .key != "modified" and (.value <= $cutoff))) | sort_by(.value) | last | .key')
```

**Output is designed to be `eval`-able or `source`-able:**
```bash
eval $(./scripts/resolve-versions.sh --cooldown-days 4)
podman build \
    --build-arg "COOLDOWN_DATE=${COOLDOWN_DATE}" \
    --build-arg "GOVULNCHECK_VERSION=${GOVULNCHECK_VERSION}" \
    --build-arg "GSD_CORE_VERSION=${GSD_CORE_VERSION}" \
    --build-arg "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}" \
    -t sandbox-image .
```

### Pattern 3: versions.lock — Hybrid Generation

**What:** The Dockerfile generates `/versions-npm.json` (from `npm ls -g --json`) and `/versions-govulncheck.txt` inside the image. The host extracts these files and merges them with the resolver's top-level timestamp data into a single `versions.lock` JSON.

**Why hybrid:** The Dockerfile captures what was actually installed (including transitive deps resolved by `--before`). The host verifier adds timestamps by querying registries (requires network; the running sandbox has no egress, but the host does).

**Extraction pattern:**
```bash
CID=$(podman create sandbox-image)
podman cp "${CID}:/versions-npm.json" ./versions-npm.json
podman cp "${CID}:/versions-govulncheck.txt" ./versions-govulncheck.txt
podman rm "${CID}"
```

**versions.lock JSON schema:**
```json
{
  "cooldown_date": "2026-06-09",
  "build_date": "2026-06-13",
  "cooldown_days": 4,
  "packages": {
    "govulncheck": {
      "version": "v1.3.0",
      "publish_date": "2026-04-22T22:03:04Z",
      "registry": "https://proxy.golang.org/golang.org/x/vuln"
    },
    "@opengsd/gsd-core": {
      "version": "1.4.3",
      "publish_date": "2026-06-09T17:49:11.123Z",
      "registry": "https://registry.npmjs.org"
    },
    "@anthropic-ai/claude-code": {
      "version": "2.1.170",
      "publish_date": "2026-06-09T16:15:44.470Z",
      "registry": "https://registry.npmjs.org"
    }
  },
  "npm_transitive_snapshot": "/path/to/versions-npm.json"
}
```

### Pattern 4: Pin-Held Verifier (verify-pins.sh)

**What:** A host-side bash script that reads `versions.lock`, queries each package's actual publish timestamp from the registry, and exits 1 if any timestamp is after `cooldown_date + T23:59:59Z`.

**Example (govulncheck):**
```bash
# govulncheck: query Go proxy .Time field
GOVULN_VER=$(jq -r '.packages.govulncheck.version' versions.lock)
GOVULN_TIME=$(curl -s "https://proxy.golang.org/golang.org/x/vuln/@v/${GOVULN_VER}.info" | jq -r '.Time')
CUTOFF="${COOLDOWN_DATE}T23:59:59Z"
if [[ "$GOVULN_TIME" > "$CUTOFF" ]]; then
    echo "FAIL: govulncheck ${GOVULN_VER} published ${GOVULN_TIME} > cutoff ${CUTOFF}" >&2
    exit 1
fi

# npm packages: query registry .time[version] field
GSD_VER=$(jq -r '.packages["@opengsd/gsd-core"].version' versions.lock)
GSD_TIME=$(curl -s "https://registry.npmjs.org/@opengsd/gsd-core" | jq -r ".time[\"${GSD_VER}\"]")
# ... same comparison pattern
```

**Verifier also checks transitive deps** (from versions-npm.json):
```bash
# Extract all transitive package+version pairs from versions-npm.json
# For each, query registry timestamp and compare against cutoff
# This is the key value of D-04: verifies what --before ACTUALLY resolved
```

### Anti-Patterns to Avoid

- **`npx @opengsd/gsd-core@latest --claude --global`:** `npx` does not support `--before`; `@latest` resolves to post-cooldown version. [CITED: CLAUDE.md "What NOT to Use"]
- **`ANTHROPIC_BASE_URL=https://inference.local/v1`:** Double `/v1/messages` path. Use `ANTHROPIC_BASE_URL=https://inference.local` (no trailing `/v1`). [CITED: CLAUDE.md]
- **`docker build` instead of `podman build`:** Gateway config already uses Podman driver. [CITED: CLAUDE.md]
- **Digest-pinning `FROM fedora:44@sha256:...`:** Conflicts with rolling-update design (D-06). [CITED: CONTEXT.md D-06]
- **`--min-release-age` instead of `--before=DATE`:** `--min-release-age` is relative (relative to the build machine's clock); `--before` is an absolute date that can be passed as a build ARG, making it reproducible. Use `--before`.
- **Forcing PIN-07 into a Dockerfile RUN:** Explicitly locked against by D-03/D-04. The podman build must succeed; the pipeline fails after.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Transitive npm dependency pinning | Custom lock generator | `npm install -g pkg@VERSION --before=DATE` | npm's Arborist resolver handles the full transitive tree with date filtering; custom lock generation is complex and error-prone |
| Go module version listing | Custom Go proxy scraper | `https://proxy.golang.org/golang.org/x/vuln/@v/list` + `.info` endpoint | Official Go module proxy API; canonical and stable |
| Post-build file extraction from image | Running the container | `podman create` + `podman cp` + `podman rm` | Creates a stopped container, copies the file, removes it — no network, no running process needed |
| ISO-8601 date comparison | Custom date parser | Bash string comparison (`[[ "$DATE_A" < "$DATE_B" ]]`) | UTC ISO-8601 strings are lexicographically sortable; `sort -V` and `jq | sort_by(.value)` both work correctly |

**Key insight:** The npm `--before` flag is a first-class registry feature in npm v11, not a workaround. It rebuilds the full Arborist resolution tree using only package versions available on or before the given date. Do not attempt to replicate this with a custom lockfile or version resolution script.

---

## Common Pitfalls

### Pitfall 1: Stale Version Pins from CLAUDE.md

**What goes wrong:** Using the CLAUDE.md-documented versions (gsd-core 1.4.0, Claude Code 2.1.169) instead of the live-refreshed pins. Both packages had new versions published ON the cooldown date (2026-06-09).

**Why it happens:** CLAUDE.md was written with an earlier cutoff date. The rolling cooldown means pins shift forward each rebuild.

**How to avoid:** The resolver helper queries live registries on every run. Never hard-code version strings in the Dockerfile — always accept them as `ARG` values from the resolver. The current correct pins (as of 2026-06-13, cooldown 2026-06-09):
- govulncheck: `v1.3.0`
- @opengsd/gsd-core: `1.4.3` (not 1.4.0)
- @anthropic-ai/claude-code: `2.1.170` (not 2.1.169)

**Warning signs:** versions.lock shows a gsd-core version < 1.4.3 or Claude Code < 2.1.170 for today's build.

### Pitfall 2: Inclusive vs. Exclusive Cooldown Boundary

**What goes wrong:** Treating the cooldown date as exclusive (strictly before) rather than inclusive (on or before). This would incorrectly reject gsd-core 1.4.3 (17:49 UTC on the cutoff day).

**Why it happens:** Ambiguity in "latest as of N days before build."

**How to avoid:** The cutoff is `COOLDOWN_DATE + T23:59:59Z` (end-of-day UTC). Compare timestamps with `<=`, not `<`. The jq pattern: `.value <= $cutoff` where `$cutoff = "${COOLDOWN_DATE}T23:59:59Z"`.

**Warning signs:** Resolver rejects versions published on the cutoff day itself.

### Pitfall 3: npm ls -g Only Shows Top Level Without --depth

**What goes wrong:** Running `npm ls -g --json` (no `--depth`) only returns direct globals. You miss transitive deps in the versions.lock snapshot.

**Why it happens:** npm ls depth defaults to 0 for global installs.

**How to avoid:** Use `npm ls -g --json --depth=Infinity` (or a large number like `--depth=10`). Verified empirically: `--depth=2` shows `ws@8.20.1` as a transitive dep of gsd-core.

### Pitfall 4: dnf Cache Not Busted

**What goes wrong:** The `ARG COOLDOWN_DATE` is declared AFTER the `RUN dnf update -y` layer, so changing the date doesn't bust the cache. The old RPMs are served from cache.

**Why it happens:** ARG values only affect the cache of layers declared after the ARG.

**How to avoid:** `ARG COOLDOWN_DATE` must appear as the first ARG, before any `RUN dnf` command. Verify success criterion #2: no `CACHED` on the dnf step when `COOLDOWN_DATE` changes.

### Pitfall 5: gsd-core --claude --global Writes to /root/.claude

**What goes wrong:** `gsd-core --claude --global` runs `bin/install.js` which writes hooks/commands to `~/.claude/`. Inside the Dockerfile (as root), this is `/root/.claude/`. This is correct for the sandbox (Claude runs as root by default), but the planner should be aware the install is user-specific.

**Why it happens:** gsd-core writes to the home directory, not a system-wide path.

**How to avoid:** No action needed — `~` inside the Dockerfile resolves to `/root` which is correct. Phase 4 will verify plugin loading from this path.

### Pitfall 6: npm postinstall for Claude Code

**What goes wrong:** `@anthropic-ai/claude-code` has `postinstall: node install.cjs` which runs automatically during `npm install -g`. This is expected behavior, but in a minimal Fedora container it may fail if Node.js or required system libraries are not installed first.

**Why it happens:** The postinstall script sets up native binaries and platform-specific packages.

**How to avoid:** Install `nodejs` and `npm` RPMs BEFORE the `npm install -g @anthropic-ai/claude-code` step. The `ca-certificates` RPM is also needed for HTTPS during npm install.

---

## Discretion Recommendations

### Resolver Form: Bash

**Recommendation:** Use bash for `scripts/resolve-versions.sh`.

**Rationale:** (a) The resolver runs on the macOS host before podman build — no compilation step needed. (b) jq 1.7.1 is available on the host for JSON parsing. (c) bash helper composes most naturally into Phase 2's `rebuild.sh` (source/eval pattern). (d) The Go toolchain IS available on the host, but compiling a Go program as a prerequisite to building a Go image is circular complexity. (e) The registry queries are straightforward curl + jq operations.

### Resolver Depth: Top-Level Only

**Recommendation:** The resolver outputs only top-level versions + COOLDOWN_DATE. npm `--before` handles transitive resolution at build time.

**Rationale:** (a) npm's Arborist resolver is authoritative for npm packages — duplicating its logic host-side is unnecessary work with no accuracy advantage. (b) Non-determinism risk is LOW: the Dockerfile layer cache means the same COOLDOWN_DATE produces the same cached layer, and Arborist's resolution algorithm is deterministic for the same inputs. (c) The in-image `npm ls -g --json --depth=Infinity` snapshot captures what was actually installed for the PIN-07 verifier — this is more reliable than pre-computing the tree host-side.

### versions.lock Format: JSON

**Recommendation:** JSON with the schema described in Pattern 3 above.

**Rationale:** (a) jq parses it cleanly in the verifier. (b) Structured fields (publish_date, cooldown_date) make the verifier logic straightforward. (c) The npm transitive snapshot is a separate file (`versions-npm.json`) referenced by path — keeping the main lock file focused on top-level pins and metadata.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| podman | Build driver (IMG-01) | ✓ | 5.8.2 | — (required, no fallback) |
| bash | Resolver helper, verifier | ✓ | 5.3.15 | — |
| jq | JSON parsing in resolver/verifier | ✓ | 1.7.1 | python3 -c (also available) |
| curl | Registry queries in resolver/verifier | ✓ | (macOS system) | — |
| python3 | Date arithmetic in resolver | ✓ | 3.14.5 | `date -d` (GNU date, macOS needs `gdate`) |
| git | Toolkit clone (IMG-05, build-time) | ✓ | 2.50.1 | — |
| fedora:44 | Base image | ✓ | (already in local podman cache) | Will pull from docker.io on first build |
| github.com/pheckenlWork/claude-engineering-toolkit | IMG-05 | ✓ | HEAD confirmed reachable | — |
| proxy.golang.org | govulncheck version resolution | ✓ | (host network) | — |
| registry.npmjs.org | gsd-core, claude-code version resolution | ✓ | (host network) | — |

**Missing dependencies with no fallback:** None — all required tools confirmed available on host.

**Note on `date -d`:** macOS `date` does not support `-d` (GNU date syntax). Use `python3 -c "from datetime import date, timedelta; ..."` for date arithmetic in the resolver helper. Alternatively, if `gdate` (GNU coreutils via Homebrew) is available, use that — but python3 is safer as a cross-platform dependency.

---

## Security Domain

> security_enforcement is enabled (ASVS Level 1). Phase 1 is a build-tooling phase with no user auth, sessions, or direct network exposure in the runtime artifact. ASVS scope is narrow.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | No auth in build scripts or Dockerfile |
| V3 Session Management | No | No sessions |
| V4 Access Control | Minimal | Script files should be executable by owner only (`chmod 700` or `755`) |
| V5 Input Validation | Yes | Resolver helper's `--cooldown-days N` arg must validate N is a positive integer; reject malformed date inputs |
| V6 Cryptography | No | No crypto operations in Phase 1 |

### Known Threat Patterns for Supply-Chain Build Scripts

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Malicious package via typosquat | Tampering | Top-level version pinning + `--before` date filter; packages are explicitly named in CLAUDE.md |
| Stale cached layer serving outdated packages | Spoofing | `ARG COOLDOWN_DATE` cache-bust forces re-pull on date change |
| Registry unavailability during resolver | Denial of Service | Resolver fails fast with clear error; build does not proceed without resolved versions |
| Credential in Dockerfile ENV/ARG | Info Disclosure | CLAUDE.md explicitly prohibits baking credentials into image; Phase 3 handles runtime credential injection |
| Unvalidated shell input in resolver | Tampering | `--cooldown-days N` validated as positive integer; cooldown date computed internally, not accepted as raw user input |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Fedora 44 nodejs RPM provides npm 11 (compatible with `--before` flag) | Standard Stack | npm older than v7 does not support `--before`; would need to install npm separately |
| A2 | `gsd-core --claude --global` is the correct install command for Fedora 44 (running as root, /root home) | Code Examples, Pitfall 5 | If the installer has different flags for root vs user mode, the hooks may not install correctly |
| A3 | The Dockerfile's `RUN git clone` has host network access during `podman build` (private network namespace with NAT) | Architecture diagram | If podman build uses `--network=none` by default in some configurations, the git clone would fail |

---

## Open Questions

1. **gsd-core 1.4.x vs 1.4.0: API changes?**
   - What we know: 1.4.3 is the correct cooldown pin (published 2026-06-09T17:49Z). 1.4.1, 1.4.2, 1.4.3 all published on the cutoff day — three new minor releases in one day.
   - What's unclear: Whether `gsd-core --claude --global` CLI contract changed between 1.4.0 and 1.4.3.
   - Recommendation: Treat as LOW risk — use 1.4.3, the resolver will always pick the latest on-or-before anyway. If the install fails, check gsd-core release notes.

2. **macOS `date` arithmetic for COOLDOWN_DATE computation**
   - What we know: `date -d "4 days ago"` is GNU-only; macOS `date -v-4d` is BSD-specific.
   - What's unclear: Whether the project assumes GNU coreutils (via Homebrew) or raw macOS tools.
   - Recommendation: Use `python3 -c "from datetime import date, timedelta; print((date.today() - timedelta(days=N)).isoformat())"` — python3 is confirmed available and cross-platform.

3. **Fedora 44 nodejs version (RPM) and npm compatibility**
   - What we know: CLAUDE.md says "nodejs: Available in F44, npm 11 expected." [ASSUMED]
   - What's unclear: Exact RPM version; whether `npm install -g ... --before` works without issues.
   - Recommendation: Add a `RUN node --version && npm --version` assertion layer in the Dockerfile for diagnostics.

---

## Sources

### Primary (HIGH confidence)
- `CLAUDE.md` (project-local) — authoritative tech-stack spec, install commands, anti-patterns, version compatibility matrix [VERIFIED: read directly]
- `https://registry.npmjs.org/@opengsd/gsd-core` — live registry query, all version timestamps, cooldown pin confirmed as 1.4.3 [VERIFIED: curl + python3 JSON parse]
- `https://registry.npmjs.org/@anthropic-ai/claude-code` — live registry query, all 2.1.x version timestamps, cooldown pin confirmed as 2.1.170 [VERIFIED: curl + python3 JSON parse]
- `https://proxy.golang.org/golang.org/x/vuln/@v/list` — live Go proxy, all 14 versions, v1.3.0 still latest [VERIFIED: curl]
- `https://proxy.golang.org/golang.org/x/vuln/@v/v1.3.0.info` — publish timestamp 2026-04-22T22:03:04Z [VERIFIED: WebFetch]
- `https://koji.fedoraproject.org` — golangci-lint-2.11.3-1.fc44 and golang-1.26.4-2.fc44 confirmed in f44 tag [VERIFIED: Koji search]
- Host tool versions — podman 5.8.2, bash 5.3.15, jq 1.7.1, python3 3.14.5, npm 11.16.0 [VERIFIED: live host]
- github.com/pheckenlWork/claude-engineering-toolkit — repo reachable, HEAD confirmed [VERIFIED: git ls-remote]
- docker.io/library/fedora:44 — last pushed 2026-05-28, in local podman cache [VERIFIED: podman + Docker Hub API]

### Secondary (MEDIUM confidence)
- `https://docs.npmjs.com/cli/v11/commands/npm-install#before` — `--before` rebuilds full transitive tree [CITED: official npm docs]
- `https://docs.docker.com/build/cache/invalidation/` — ARG changes invalidate subsequent build cache layers [CITED: official Docker docs]

### Tertiary (LOW confidence — training knowledge)
- npm ls --depth behavior for global installs (supplemented by live test on host)
- Fedora 44 nodejs RPM providing npm 11 [ASSUMED]

---

## Metadata

**Confidence breakdown:**
- Standard stack (versions): HIGH — all version pins verified against live registries
- Resolver helper design: HIGH — based on verified API endpoints and live tool availability
- versions.lock approach: MEDIUM — design is sound; `podman create + cp` pattern is standard but not tested end-to-end yet
- Pin-held verifier: MEDIUM — registry query pattern verified; full script not yet tested
- ASVS / security: HIGH — scope is narrow and well-defined for a build tooling phase

**Research date:** 2026-06-13
**Valid until:** 2026-06-17 (cooldown pins shift with each rebuild; re-run resolver before each build)
