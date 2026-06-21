# Supply-Chain & Dependency-Pinning Guidelines

The **rolling cooldown pin** is the defining engineering concern of this project: every externally-installed dependency is frozen to "the latest version published on or before the cooldown date" (default `today − 4 days`). This narrows the supply-chain attack window — a malicious release published in the last 4 days is never installed. These rules are grounded in `scripts/resolve-versions.sh`, `scripts/verify-pins.sh`, `scripts/build-and-lock.sh`, and `Dockerfile`.

## The pinned dependencies and their mechanisms

| Dependency | Source | Pin mechanism |
|---|---|---|
| `golang`, `golangci-lint` | Fedora 44 RPM | `dnf install` (distro cooldown) — no explicit pin needed |
| `govulncheck` | `proxy.golang.org` | `go install golang.org/x/vuln/cmd/govulncheck@vX.Y.Z` — **explicit tag**, never `@latest` |
| `@opengsd/gsd-core` | `registry.npmjs.org` | `npm install -g pkg@VER --before=DATE` (+ `--ignore-scripts`) |
| `@anthropic-ai/claude-code` | `registry.npmjs.org` | `npm install -g pkg@VER --before=DATE` (+ `--allow-scripts @anthropic-ai/claude-code`) |
| `claude-engineering-toolkit` | git HEAD | **Not pinned** — operator-trusted fork, cloned at build time |

## Exclusive-boundary date semantics (the CR-01 fix)

"Latest as of `COOLDOWN_DATE`" means **published strictly before next-day midnight UTC** — the whole cooldown day is inclusive.

- Both `resolve-versions.sh` and `verify-pins.sh` compute `CUTOFF_EXCL="${NEXT_DAY}T00:00:00.000Z"` and compare publish timestamps lexicographically against it. A version is eligible iff `PUB_TIME < CUTOFF_EXCL`.
- **Do not** revert to the old `${DATE}T23:59:59Z` string. npm timestamps are millisecond-precision (`...T23:59:59.NNNZ`); a string like `23:59:59.500Z` sorts *after* `23:59:59Z`, so a late-in-the-day legitimate release would be wrongly rejected. No `T23:59:59.NNNZ` value ever reaches `T00:00:00.000Z` of the next day, so `CUTOFF_EXCL` is correct at full precision.
- The `CUTOFF="${DATE}T23:59:59Z"` variable still exists in both scripts but is **display/log only** — never the comparison operand.
- Version-tag filtering: only release-form tags are eligible (no pseudo-versions, no pre-releases). The exact regex differs by registry:
  - **govulncheck** (bash, Go proxy): `^v[0-9]+\.[0-9]+\.[0-9]+$` — the `v` prefix is **required**.
  - **npm packages** (jq, npm registry): `^[0-9]+\.[0-9]+\.[0-9]+$` — no `v` prefix.

  Among eligible versions the **most recently published** is chosen (sorted by publish time, not semver).

## The required npm flag set (every `npm install -g`)

Both npm installs in the `Dockerfile` MUST carry these flags. Each matters:

- `pkg@${VERSION}` — explicit pre-resolved top-level pin from `resolve-versions.sh`. claude-code ships ~daily; without it `@latest` would resolve post-cooldown.
- `--before="${COOLDOWN_DATE}T23:59:59Z"` — pins the **entire transitive tree** (direct AND transitive deps) to versions published on or before the cooldown date. This is the load-bearing supply-chain control.
- `--allow-git=none --allow-remote=none --allow-directory=none` — these default to permissive (`all`); without them, git-ref, tarball-URL, and local-directory dependency sources remain allowed. We require **registry semver only**.
- Script policy (differs per package):
  - **gsd-core → `--ignore-scripts`** — gsd-core 1.4.0 has no install/preinstall/postinstall scripts; real setup is the explicit `gsd-core --claude --global` call. Explicit and durable across npm versions.
  - **claude-code → `--allow-scripts @anthropic-ai/claude-code`** — claude-code requires its first-party `postinstall: node install.cjs`. This permits *only* its own script and blocks all transitive-dep scripts.

> The `Dockerfile` `--before` value is the `T23:59:59Z` string passed to npm. This is npm's documented date-filter input (a date fence, coarse-grained) and is independent of the exclusive-boundary comparison used by the resolver/verifier — those two scripts do the millisecond-precise gating. Do not "fix" the Dockerfile string to match `CUTOFF_EXCL`; npm's `--before` semantics are date-level.

## Never use (hard prohibitions)

- **`@latest` / dist-tags** (npm or `go install`) — ignores cooldown; resolves to whatever is current. Always pin an explicit version/tag.
- **`--min-release-age=N`** (npm 11 native cooldown) — silently ignored by Fedora 44's bundled npm; it would install `@latest` instead. Always use `--before`.
- **`npx ... --before`** — `npx` does not support `--before`; it cannot pin the transitive tree. Use `npm install -g`.
- **Omitting any flag above** — permissive defaults reopen script execution or non-registry sources.
- **Hardcoding versions in the `Dockerfile`** — all versions arrive via `ARG`; the file contains zero literal versions.

## How the lock files and Dockerfile ARGs interact

`scripts/build-and-lock.sh` is the end-to-end driver (`./rebuild.sh` wraps it). Flow:

1. **Resolve** — runs `resolve-versions.sh`, parses its `KEY=VALUE` stdout through an **allowlist** (not `eval` — CR-02; registry-controlled output is injection-untrusted). Validates `COOLDOWN_DATE` as `YYYY-MM-DD` and each `*_VERSION` against a semver charset.
2. **Build** — `podman build` passes `COOLDOWN_DATE`, `GOVULNCHECK_VERSION`, `GSD_CORE_VERSION`, `CLAUDE_CODE_VERSION`, `BUILD_DATE` as `--build-arg`s.
   - **ARG-before-RUN cache-bust:** `COOLDOWN_DATE` is the **first** `ARG`, declared before any `RUN dnf`. When the cooldown date changes, its layer cache is invalidated, forcing all downstream install layers to rebuild — so a re-pin actually re-pulls. `LABEL`s are declared from ARGs but do not trigger layer execution / do not bust the cache.
3. **Extract** — `podman create` + `podman cp` pull `/versions-npm.json` (from `npm ls -g --json --depth=Infinity`, captured with `|| true` then `jq empty`-validated) and `/versions-govulncheck.txt`.
4. **Assemble `versions.lock`** — jq writes `{cooldown_date, build_date, cooldown_days, packages:{govulncheck, @opengsd/gsd-core, @anthropic-ai/claude-code → {version, publish_date, registry}}, npm_transitive_snapshot}`.
5. **Verify** — runs `verify-pins.sh` as the final gate.

`versions.lock` = top-level pins + cooldown metadata. `versions-npm.json` = full transitive snapshot of what npm `--before` *actually resolved*. Both are committed and are the inputs to the verifier.

## The fail-closed verify-pins gate (PIN-07 / D-03 / D-04)

`scripts/verify-pins.sh` re-queries each pinned version's **true publish date** from its registry and exits non-zero if anything postdates the cooldown window. It **never exits 0 on uncertainty**:

- Missing `versions.lock` / `versions-npm.json`, malformed JSON, missing `cooldown_date`, or any missing expected field → `exit 1`.
- Any registry/network query failure → counted as a violation (does not skip).
- A publish date `>= CUTOFF_EXCL` (next-day-or-later) → violation.
- **Transitive coverage (D-04):** flattens the entire `versions-npm.json` tree and checks every `{pkg, version}` pair, not just top-level pins — caching registry docs per package.
- **`__MISSING__` sentinel (WR-02):** nodes that npm marked `missing`/`invalid` lack a version field; the flattener emits `pkg\t__MISSING__` and the loop counts each as a violation. An unresolvable dep fails the build rather than being silently dropped.
- Any violation count `> 0` → `exit 1`, failing the pipeline closed.

## How to bump or re-pin a dependency

The pin is **rolling** — you normally do not edit version numbers by hand.

1. To re-pin to the current cooldown window, just re-run the build: `bash scripts/build-and-lock.sh` (or `./rebuild.sh`). It re-resolves the latest-on-or-before-cooldown versions, rebuilds (cooldown-date ARG busts the cache), regenerates `versions.lock` + `versions-npm.json`, and runs the verifier.
2. To change the window width, pass `--cooldown-days N` (must be a positive integer; default 4). A larger N pins older/more-vetted versions.
3. **Commit the regenerated `versions.lock`, `versions-npm.json`, and `versions-govulncheck.txt` together** — they are the reproducibility record for that build.
4. Never hand-edit `versions.lock` to advance a version past the window — `verify-pins.sh` re-checks against the registry and will fail closed.
5. RPM deps (`golang`, `golangci-lint`) are not in the lock; they ride Fedora 44's `dnf` and the `COOLDOWN_DATE` cache-bust. `govulncheck` is pinned by explicit `@vX.Y.Z` tag (resolved from Go proxy timestamps), never `@latest`.
6. To preview what a re-pin would select without building: `bash scripts/resolve-versions.sh [--cooldown-days N]` (prints the `KEY=VALUE` pins to stdout).
