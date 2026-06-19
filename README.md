# personal-sandbox
Create and maintain a personal sandbox using NVIDIA OpenShell on macOS/Linux.

## Architecture B — api.anthropic.com-only direct egress

The sandbox allows Claude Code to connect **directly** to `api.anthropic.com:443` using your
Claude **subscription OAuth login** (no `ANTHROPIC_API_KEY`, no gateway brokering). The sandbox
network policy allows **only** `api.anthropic.com:443` — no `statsig.anthropic.com`, no
`sentry.io`, no open internet. That single egress is binary-scoped to the `claude` executable,
so arbitrary processes in the autonomous sandbox cannot reach Anthropic.

**Trade-off accepted:** the subscription OAuth token lives at `~/.claude/.credentials.json`
*inside* the sandbox (written by the in-sandbox login flow). Mitigations: egress is restricted
to `api.anthropic.com:443` only, and the policy is binary-scoped to `claude`. The sandbox is
deleted between sessions with `./rebuild.sh down`.

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

### Available verbs

```
./rebuild.sh [rebuild] [--cooldown-days N]  # Full clean rebuild (default)
./rebuild.sh status                          # Status summary (read-only)
./rebuild.sh connect                         # Attach to running sandbox shell
./rebuild.sh login                           # Connect + guide through Claude OAuth flow
./rebuild.sh down                            # Delete sandbox (idempotent; no native stop)
./rebuild.sh audit [--since <ts>]            # Surface openshell logs without rebuilding
```

`--cooldown-days N` overrides the supply-chain cooldown window (default: 4 days).

### What the rebuild does

1. **Preflight** — verifies `podman`, `openshell`, `python3`, and `jq` are on `PATH`.
2. **Resolve + build** — delegates to `scripts/build-and-lock.sh`, which resolves cooldown-pinned
   versions and runs `podman build`. The image is tagged `localhost/claude-sandbox:<YYYY-MM-DD>`.
3. **Tag `:latest`** — adds a `localhost/claude-sandbox:latest` alias to the date-tagged image.
4. **Teardown** — deletes the existing `claude-sandbox` sandbox (tolerate-absent) and removes
   old `localhost/claude-sandbox:*` images from the podman store.
5. **Create** — runs `openshell sandbox create --from localhost/claude-sandbox:<date>` with:
   - `--policy ./policy.yaml` — grants Landlock write access to `/claudeshared`; sets the
     `api.anthropic.com:443` passthrough network policy (binary-scoped to `claude`)
   - `--driver-config-json` bind mount: `$HOME/claudeshared` → `/claudeshared` (read-write)
   - `--no-tty -- /bin/true` — creates the sandbox without an interactive session
   After create, the script verifies the sandbox reaches `Ready` state before exiting.
6. **NET-04 policy assertion** — queries the live sandbox policy via `openshell policy get`
   and aborts if: `api.anthropic.com:443` is missing, has a `protocol` field (would break
   passthrough), lacks a claude binary scope, or if `statsig.anthropic.com`/`sentry.io` are
   present. Fatal gate.
7. **NET-05 egress smoke test** — runs `curl` from inside the sandbox:
   - `api.anthropic.com` → must be **reachable** (any HTTP status = pass; connection denied = fail)
   - `statsig.anthropic.com`, `sentry.io`, `www.google.com` → must be **blocked**
   Both sides are fatal gates (either failure aborts the rebuild).

### Shared workspace (`~/claudeshared`)

The `~/claudeshared` directory on the host is bind-mounted read-write at `/claudeshared` inside
the sandbox. Clone repos there on the host and they appear inside the sandbox (and vice versa).
Files written by the in-sandbox agent at `/claudeshared` appear on the host owned by your user
(UID alignment is automatic via virtiofs).

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

## Post-session egress audit

After a Claude session, surface the sandbox's network activity logs with:

```bash
./rebuild.sh audit
./rebuild.sh audit --since 2026-06-19T00:00:00Z   # filter by timestamp
```

This runs `openshell logs claude-sandbox --source all` and exits without running any build,
teardown, or create steps.

### What to look for in the logs

- **api.anthropic.com connections** — expected (the passthrough allow is active). Confirm all
  outbound connects from the sandbox go only to `api.anthropic.com`.
- **Outbound connection attempts to non-allowlisted hosts** — should be proxy-denied. If you see
  `statsig.anthropic.com`, `sentry.io`, or any other host, the egress policy is not active.
- **Landlock denials** — indicate a filesystem operation outside the policy.

---

## Widening the allowlist (if needed)

`statsig.anthropic.com` and `sentry.io` are intentionally blocked to minimize telemetry/exfil
surface. If Claude Code shows degraded behavior (noisy startup errors, feature gates not working),
the minimal follow-up is to add `statsig.anthropic.com:443` as a passthrough entry in `policy.yaml`
(same shape as the `api.anthropic.com` entry, same `binaries` scope). Do NOT add `sentry.io` unless
strictly required — it is an external crash-reporting host.

---

## Operator validation checklist

After a successful `./rebuild.sh` (all gates PASS) and `./rebuild.sh login` (OAuth complete):

### Steps

1. Confirm NET-04 and NET-05 both printed `PASS` in the rebuild output.

2. Connect to the running sandbox:
   ```bash
   ./rebuild.sh connect
   ```

3. Inside the sandbox, start Claude in fully-autonomous mode:
   ```bash
   claude --dangerously-skip-permissions
   ```
   **Note:** Use `--dangerously-skip-permissions` (not `--allow-dangerously-skip-permissions`).

4. Send at least two messages and confirm model responses are returned. Both round-trips should
   succeed going **direct to `api.anthropic.com`** (confirmed by the NET-05 smoke test above).

5. Verify that `statsig.anthropic.com` and `sentry.io` are blocked. From inside the sandbox:
   ```bash
   curl --max-time 5 https://statsig.anthropic.com   # should fail (connection denied)
   curl --max-time 5 https://sentry.io               # should fail (connection denied)
   curl --max-time 5 https://www.google.com          # should fail (connection denied)
   ```

6. Optionally confirm model switching:
   ```bash
   /model   # switch to Sonnet or Haiku mid-session
   ```

7. Exit Claude and the sandbox session when done:
   ```bash
   /exit
   exit
   ```

If model responses are not returned, check:
- `./rebuild.sh audit` for connection errors in the sandbox logs
- Confirm the OAuth login completed (`~/.claude/.credentials.json` exists inside the sandbox)
- Re-run `./rebuild.sh login` if the token may have expired
