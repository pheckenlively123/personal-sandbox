# personal-sandbox

Create and maintain a personal, network-isolated development sandbox for running Claude Code
with `--dangerously-skip-permissions` safely — built as an NVIDIA OpenShell sandbox from a
Fedora 44 image, on macOS or Linux.

This README is the **operator guide**: verbs, OAuth login, audit, and the validation checklist.
For agent onboarding and the layered domain docs, see the **Documentation** section below.

## Documentation

| Doc | What it covers |
|-----|----------------|
| [`AGENTS.md`](AGENTS.md) | Agent-agnostic onboarding (any AI tool). Project orientation, repo structure, cross-cutting conventions, and the docs index. Read this first if you're an AI agent working in the repo. |
| [`CLAUDE.md`](CLAUDE.md) | Large Claude-specific project doc + deep tech detail (version tables, build pattern, rationale). |
| [`docs/security-guidelines.md`](docs/security-guidelines.md) | The fail-closed security playbook — egress allowlists, `read_write` grants, OAuth-token handling. |
| [`docs/error-handling-guidelines.md`](docs/error-handling-guidelines.md) | Bash discipline — `set -euo pipefail` footguns, fail-closed validation, traps, exit codes. |
| [`docs/testing-guidelines.md`](docs/testing-guidelines.md) | Negative-path guard tests — prove the guard, seed tampered input, assert exact exit codes. |
| [`docs/integration-guidelines.md`](docs/integration-guidelines.md) | Seams between podman, OpenShell CLI, npm, the Go proxy, and the claude binary. |
| [`docs/supply-chain-guidelines.md`](docs/supply-chain-guidelines.md) | Rolling cooldown pin discipline and the required npm flag set. |

The five `docs/*-guidelines.md` files hold the domain depth — this README links to them rather than
duplicating them.

## Tech stack

Short version (see `AGENTS.md` / `CLAUDE.md` for depth):

- **Base image:** Fedora 44.
- **Build:** `podman build` (not the Docker daemon). The image reference is handed to
  `openshell sandbox create --from <image-ref>`.
- **Runtime:** NVIDIA OpenShell CLI (sandbox create / exec / policy / logs).
- **Bundled toolchain:** Go (RPM `golang` + `golangci-lint`), `govulncheck` (via `go install`),
  plus the claude-engineering-toolkit plugins cloned to `/opt/claude-engineering-toolkit`.
- **npm-installed:** `@anthropic-ai/claude-code` and `@opengsd/gsd-core`.
- **Pinning:** rolling supply-chain **cooldown** — every external dependency frozen to "latest
  published on or before `today − 4 days`" (default; overridable with `--cooldown-days N`).

## Repo structure

See the **Repo structure** map in [`AGENTS.md`](AGENTS.md#repo-structure) for the full layout
(`rebuild.sh`, `Dockerfile`, `policy.yaml`, `scripts/`, `tests/`, `docs/`, `versions.lock`,
`.planning/`). The single operator entry point is `rebuild.sh`.

---

## Architecture B — two binary-scoped egress allowlists

The sandbox lets Claude Code connect **directly** to the Claude auth/API hosts using your Claude
**subscription OAuth login** (no `ANTHROPIC_API_KEY`, no gateway brokering). Networking is
**Architecture B**: **two** independently binary-scoped, TLS-passthrough egress allowlists — and
nothing else reaches the open internet.

### `claude_egress` — scoped to the `claude` binary

| Host | Port | Purpose |
|------|------|---------|
| `api.anthropic.com` | 443 | Model inference (Claude API) |
| `platform.claude.com` | 443 | Console/Claude account authentication (OAuth) |
| `claude.ai` | 443 | claude.ai account authentication (OAuth) |

Scoped to `/usr/bin/claude` and `/usr/local/bin/claude`.

### `go_egress` — scoped to the Go toolchain

| Host | Port | Purpose |
|------|------|---------|
| `proxy.golang.org` | 443 | Go module proxy |
| `sum.golang.org` | 443 | Go checksum database (`go.sum` verification) |
| `vuln.go.dev` | 443 | `govulncheck` vulnerability database |

Scoped to `/usr/bin/go`, `/usr/bin/golangci-lint`, and `/usr/local/bin/govulncheck`. This allowlist
exists so the engineering-toolkit Go reviewers — **lint-reviewer** (golangci-lint),
**test-reviewer** (`go test`), and **vuln-reviewer** (govulncheck) — can resolve modules and the
vulnerability DB while reviewing non-vendored Go projects under `/claudeshared`.

### Why two isolated scopes

Both allowlists use **opaque TLS passthrough** (no `protocol` field → the proxy never terminates
TLS or decrypts the stream). The two scopes are kept **isolated** — the `claude` binary cannot
reach the Go hosts, and the Go binaries cannot reach the Claude auth/API hosts. This isolation is
the core security invariant: it keeps the in-sandbox subscription OAuth token out of reach of any
process other than `claude`. All other egress is denied.

`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` is set in the image, which disables Claude Code's
auto-updater, telemetry (statsig), Sentry error-reporting, and feedback. This keeps
`statsig.anthropic.com`, `sentry.io`, and `downloads.claude.ai` unused — they are intentionally
absent from both allowlists and do not need to be added.

**NET-04** (live policy assertion) requires all three Claude hosts *and* all three Go hosts to be
present at port 443 with no `protocol` field, each correctly binary-scoped, with **no cross-scoping**
between them, and with `statsig.anthropic.com`/`sentry.io` absent. **NET-05** (egress smoke test)
asserts the deny posture using `curl` (blocked because it is not the `claude` or Go binaries).
**Reachability** of the Claude auth/API hosts is validated functionally by `./rebuild.sh login`
(which runs the actual `claude` binary).

**Trade-off accepted:** the subscription OAuth token lives at `~/.claude/.credentials.json`
*inside* the sandbox (written by the in-sandbox login flow). Mitigations: egress is restricted to
the six allowlisted hosts only, the two scopes are isolated, and the policy is binary-scoped. The
sandbox is deleted between sessions with `./rebuild.sh down`.

---

## Rebuilding the sandbox

`rebuild.sh` is the single entry point for all build and lifecycle operations. Run it from the
project root:

```bash
./rebuild.sh
```

Each run is a **full clean rebuild** (decision D-01): it tears down any existing `claude-sandbox`
and all `localhost/claude-sandbox:*` images before creating a fresh sandbox. The teardown step
tolerates an absent sandbox or images (decision D-02, idempotent). There is no partial-update path.

**First-time host setup (required):** the `~/claudeshared` bind mount needs the OpenShell gateway
to allow bind mounts, and the gateway must pin the supervisor image to the version it was built
for. Ensure `~/.config/openshell/gateway.toml` contains:

```toml
[openshell.drivers.podman]
enable_bind_mounts = true
# Pin to YOUR installed gateway version (`openshell --version`), NOT literally 0.0.62.
# The default is the floating `...supervisor:latest`, which is re-pulled (policy
# "newer") and can drift NEWER than the gateway — breaking the in-sandbox
# supervisor's netns setup ("Invalid argument (os error 22)" → "sandbox is not ready").
supervisor_image = "ghcr.io/nvidia/openshell/supervisor:0.0.62"
```

then restart the gateway so it reloads (Linux: `systemctl --user restart openshell`; macOS:
`brew services restart openshell`). The rebuild enforces both fail-closed (RUN-05 bind-mount preflight
step 5, RUN-06 supervisor-pin preflight step 6 below) and aborts with the exact instructions if either
is unset — it does **not** edit host config for you. Re-check the pin after `brew upgrade openshell`.

### Available verbs

```
./rebuild.sh [rebuild] [--cooldown-days N]  # Full clean rebuild (default)
./rebuild.sh status                          # Status summary (read-only)
./rebuild.sh connect                         # Attach to running sandbox shell
./rebuild.sh login                           # Connect + guide through Claude OAuth flow
./rebuild.sh claude                          # Launch autonomous Claude session (skip-permissions + plugins)
./rebuild.sh down                            # Delete sandbox (idempotent; no native stop)
./rebuild.sh audit [--since <ts>]            # Surface openshell logs without rebuilding
./rebuild.sh audit-plugins                   # Strict headless plugin audit (hard-fails on mismatch)
```

`--cooldown-days N` overrides the supply-chain cooldown window (default: 4 days).

- **`claude`** launches the autonomous session inside the running sandbox:
  `claude --dangerously-skip-permissions --plugin-dir /opt/claude-engineering-toolkit`
  (via `openshell sandbox exec --tty --workdir /claudeshared`). Prerequisites: sandbox created
  (`./rebuild.sh`) + OAuth login (`./rebuild.sh login`).
- **`audit`** is **log-surfacing only** — it runs `openshell logs` and never asserts policy.
- **`audit-plugins`** is the strict, hard-failing audit harness — it drives every toolkit
  agent/skill headless against the running sandbox and **exits 1** on any expected/actual mismatch.
  Distinct from `audit`. Prerequisites: sandbox Ready + OAuth'd.

### What the rebuild does

1. **Preflight** — verifies `podman`, `openshell`, `python3`, and `jq` are on `PATH`, then ensures
   podman is ready (machine-detect on macOS / `podman.socket` on Linux).
2. **Resolve + build** — delegates to `scripts/build-and-lock.sh`, which resolves cooldown-pinned
   versions and runs `podman build`. The image is tagged `localhost/claude-sandbox:<YYYY-MM-DD>`.
3. **Tag `:latest`** — adds a `localhost/claude-sandbox:latest` alias to the date-tagged image.
4. **Teardown** — deletes the existing `claude-sandbox` sandbox (tolerate-absent) and removes
   old `localhost/claude-sandbox:*` images from the podman store.
5. **Gateway bind-mount preflight (RUN-05)** — delegates to
   `scripts/preflight-gateway-bind-mount.sh`, which reads `~/.config/openshell/gateway.toml`
   and aborts (fail-closed) unless `enable_bind_mounts = true` is set under
   `[openshell.drivers.podman]`. It is **read-only** — it never modifies host config or
   restarts the gateway; on failure it prints exactly what to add and how to restart the
   gateway (Linux: `systemctl --user restart openshell`; macOS:
   `brew services restart openshell`). This turns the otherwise-cryptic mid-build podman
   bind-mount error on a fresh host into an actionable message before sandbox create.
6. **Supervisor-pin preflight (RUN-06)** — delegates to
   `scripts/preflight-supervisor-pin.sh`, which reads `~/.config/openshell/gateway.toml`
   and aborts (fail-closed) unless `supervisor_image` under `[openshell.drivers.podman]`
   is pinned to a **non-`:latest`** tag. The gateway otherwise defaults to the floating
   `...supervisor:latest` (pull policy `newer`); a freshly published `:latest` can drift
   newer than the installed gateway, breaking the in-sandbox supervisor's network-namespace
   setup (`Invalid argument (os error 22)` → `sandbox is not ready`). It is **read-only**
   (any tag other than `latest` passes — the version is not hardcoded, so it survives a
   `brew upgrade` + re-pin) and on failure prints the exact pin to add plus the restart command.
7. **Create** — runs `openshell sandbox create --from localhost/claude-sandbox:<date>` with:
   - `--policy ./policy.yaml` — grants Landlock write access to `/claudeshared` and the runtime
     user home; sets **both** egress allowlists (`claude_egress` + `go_egress`, passthrough,
     binary-scoped).
   - `--driver-config-json` bind mount: `$HOME/claudeshared` → `/claudeshared` (read-write).
   - `--no-tty -- /bin/true` — creates the sandbox without an interactive session.
   After create, the script verifies the sandbox is running before continuing.
8. **NET-04 policy assertion** — queries the live sandbox policy via `openshell policy get` and
   aborts (fatal gate) unless:
   - all three `claude_egress` hosts (`api.anthropic.com`, `platform.claude.com`, `claude.ai`)
     are present at port 443, passthrough (no `protocol` field), and `claude`-scoped;
   - all three `go_egress` hosts (`proxy.golang.org`, `sum.golang.org`, `vuln.go.dev`) are present
     at port 443, passthrough, and Go-toolchain-scoped;
   - the two scopes do **not** cross (no Go binary in `claude_egress`; no `*/claude` in `go_egress`);
   - `statsig.anthropic.com` and `sentry.io` are absent.
9. **NET-05 egress smoke test** — asserts **deny posture only** using `curl` from inside the
   sandbox. `curl` is neither the `claude` nor a Go binary, so binary-scoping blocks it from
   reaching ANY host. The test asserts that non-allowlisted targets are blocked:
   - `statsig.anthropic.com`, `sentry.io`, `www.google.com` → must be **blocked** (fatal gate).
   Reachability of the Claude auth/API hosts is validated functionally by `./rebuild.sh login`
   (the `claude` binary itself), not by `curl`.

### Shared workspace (`~/claudeshared`)

The `~/claudeshared` directory on the host is bind-mounted read-write at `/claudeshared` inside
the sandbox. Clone repos there on the host and they appear inside the sandbox (and vice versa).
Files written by the in-sandbox agent at `/claudeshared` appear on the host owned by your user
(UID alignment is automatic via virtiofs). `connect`, `login`, and `claude` all land you in
`/claudeshared`.

---

## Claude subscription login (one-time per session)

There is no host-side credential step. Claude Code performs the OAuth subscription login the
first time it runs inside the sandbox. Run:

```bash
./rebuild.sh login
```

This attaches to the running sandbox and prints guidance. Once inside, run:

```bash
claude
```

Claude Code will print a login URL. **Open that URL in a browser outside the sandbox**, authenticate
with your Claude subscription, then paste the returned code back into the in-sandbox prompt. The
token is stored at `~/.claude/.credentials.json` *inside* the sandbox.

After login, Claude Code uses the subscription credential for all subsequent requests (going
directly to `api.anthropic.com:443` via the policy passthrough). **No `ANTHROPIC_API_KEY`
is ever needed or used.**

**Model selection:** Claude Code's native `/model` command (Opus/Sonnet/Haiku) works normally —
there is no gateway model override. Switch models mid-session with `/model`.

**Token lifetime:** The OAuth token is stored inside the sandbox. `./rebuild.sh down` deletes the
sandbox (and the token). You will need to re-run `./rebuild.sh login` after each rebuild+down cycle.

---

## Running Claude autonomously

After login, launch the autonomous session in one step:

```bash
./rebuild.sh claude
```

This execs `claude --dangerously-skip-permissions --plugin-dir /opt/claude-engineering-toolkit`
inside the running sandbox, landing in `/claudeshared`. The `--plugin-dir` loads the
claude-engineering-toolkit agents and skills (including the Go reviewers backed by `go_egress`).
Use `--dangerously-skip-permissions` (this is what the verb passes) — not
`--allow-dangerously-skip-permissions`.

To attach to a plain shell instead (no Claude), use `./rebuild.sh connect`.

---

## Post-session egress audit

After a Claude session, surface the sandbox's network activity logs with:

```bash
./rebuild.sh audit
./rebuild.sh audit --since 2026-06-19T00:00:00Z   # filter by timestamp
```

This runs `openshell logs claude-sandbox --source all` and exits without running any build,
teardown, or create steps.

### What to look for in the logs

- **Connections to allowlisted hosts** — expected. Outbound connects from the `claude` binary
  should go only to `api.anthropic.com`, `platform.claude.com`, or `claude.ai`; outbound connects
  from the Go toolchain should go only to `proxy.golang.org`, `sum.golang.org`, or `vuln.go.dev`.
- **Outbound connection attempts to non-allowlisted hosts** — should be proxy-denied. If you see
  `statsig.anthropic.com`, `sentry.io`, or any other host with a *successful* connection, the
  egress policy is not active. (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` suppresses most such
  attempts at source, so only unexpected traffic would appear.)
- **Cross-scope hits** — a Go host reached by `claude`, or a Claude host reached by a Go binary,
  would indicate the isolation invariant is broken. NET-04 should have already failed in that case.
- **Landlock denials** — indicate a filesystem operation outside the policy.

For a stricter, hard-failing plugin/telemetry check, run `./rebuild.sh audit-plugins`.

---

## Widening the allowlist (if needed)

`statsig.anthropic.com` and `sentry.io` are intentionally blocked to minimize telemetry/exfil
surface. If Claude Code shows degraded behavior (noisy startup errors, feature gates not working),
the minimal follow-up is to add `statsig.anthropic.com:443` as a passthrough entry under
`claude_egress` in `policy.yaml` (same shape and `binaries` scope as the `api.anthropic.com` entry).
Do NOT add `sentry.io` unless strictly required — it is an external crash-reporting host.

Whenever you change `policy.yaml`, update the matching **NET-04** assertion in `rebuild.sh` in the
**same commit** (an unasserted policy claim is assumed, not enforced). Never add a `protocol` field,
never cross-scope the two allowlists, and read
[`docs/security-guidelines.md`](docs/security-guidelines.md) first.

---

## Operator validation checklist

After a successful `./rebuild.sh` (all gates PASS) and `./rebuild.sh login` (OAuth complete):

### Steps

1. Confirm NET-04 and NET-05 both printed `PASS` in the rebuild output.

2. Launch Claude autonomously:
   ```bash
   ./rebuild.sh claude
   ```
   (Or attach to a plain shell with `./rebuild.sh connect` and run
   `claude --dangerously-skip-permissions --plugin-dir /opt/claude-engineering-toolkit` by hand.)

3. Send at least two messages and confirm model responses are returned. Round-trips go direct
   to `api.anthropic.com` (inference) via the policy passthrough. OAuth login touched
   `platform.claude.com` and/or `claude.ai` — both are in the allowlist.

4. Verify that non-allowlisted hosts are blocked. From inside the sandbox
   (`./rebuild.sh connect`):
   ```bash
   curl --max-time 5 https://statsig.anthropic.com   # should fail (connection denied)
   curl --max-time 5 https://sentry.io               # should fail (connection denied)
   curl --max-time 5 https://www.google.com          # should fail (connection denied)
   ```

5. (Optional) If you'll use the Go reviewers, confirm the Go toolchain can resolve modules — run
   a toolkit Go review (lint/test/vuln) against a non-vendored Go repo under `/claudeshared`. Module
   fetches go to `proxy.golang.org`/`sum.golang.org`; `govulncheck` reaches `vuln.go.dev`.

6. (Optional) Confirm model switching with `/model` (Opus/Sonnet/Haiku) mid-session.

7. Exit Claude and the sandbox session when done:
   ```bash
   /exit
   exit
   ```

If model responses are not returned, check:
- `./rebuild.sh audit` for connection errors in the sandbox logs.
- Confirm the OAuth login completed (`~/.claude/.credentials.json` exists inside the sandbox).
- Re-run `./rebuild.sh login` if the token may have expired.
