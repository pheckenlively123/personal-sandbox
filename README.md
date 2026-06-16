# personal-sandbox
Create and maintain a personal sandbox using NVIDIA sandbox on MacOS

## Rebuilding the sandbox

`rebuild.sh` is the single entry point for all build and lifecycle operations. Run it from the
project root:

```bash
./rebuild.sh
```

Each run is a **full clean rebuild** (decision D-01): it tears down any existing `claude-sandbox`
and all `localhost/claude-sandbox:*` images before creating a fresh sandbox. This means rebuilding
is safe to run at any time — the teardown step tolerates an absent sandbox or images (decision D-02,
idempotent). There is no partial-update path.

### Options

```
./rebuild.sh [--cooldown-days N]   # Override the supply-chain cooldown window (default: 4 days)
./rebuild.sh --audit               # Surface openshell logs without rebuilding (see below)
```

### What the rebuild does

0. **Provider preflight** — runs `openshell inference get` before anything else to confirm the
   inference provider is registered. Exits immediately with an actionable error if not configured,
   preventing the ~290s hang (OpenShell #759). This is a host-side operator action; see
   [One-time inference provider setup](#one-time-inference-provider-setup) below.
1. **Preflight** — verifies `podman`, `openshell`, `python3`, and `jq` are on `PATH`.
2. **Resolve + build** — delegates to `scripts/build-and-lock.sh`, which resolves cooldown-pinned
   versions and runs `podman build`. The image is tagged `localhost/claude-sandbox:<YYYY-MM-DD>`.
3. **Tag `:latest`** — adds a `localhost/claude-sandbox:latest` alias to the date-tagged image.
4. **Teardown** — deletes the existing `claude-sandbox` sandbox (tolerate-absent) and removes
   old `localhost/claude-sandbox:*` images from the podman store.
5. **Create** — runs `openshell sandbox create --from localhost/claude-sandbox:<date>` with:
   - `--policy ./policy.yaml` — grants the sandbox Landlock write access to `/claudeshared`
   - `--driver-config-json` bind mount: `$HOME/claudeshared` → `/claudeshared` (read-write)
   - `--no-tty -- /bin/true` — creates the sandbox without an interactive session

   After create, the script verifies the sandbox reaches `Ready` state before exiting.

6. **NET-04 policy assertion** — queries the live sandbox policy via `openshell policy get`
   and exits non-zero if any direct Anthropic endpoint is found. Confirms zero-egress is
   enforced at the policy level (not just assumed from the source YAML).
7. **NET-05 egress smoke test** — runs `curl` from inside the sandbox against two independent
   targets (`https://api.anthropic.com` and `https://example.com`). Exits non-zero if either
   connection succeeds (proving deny-all, not just an Anthropic-specific block).
8. **D-06 round-trip (non-fatal)** — fires one model request through `inference.local` from
   inside the sandbox and reports PASS or WARN in the final summary banner. Never blocks the
   rebuild — WARN means the inference provider setup (above) is not yet complete.

### Shared workspace (`~/claudeshared`)

The `~/claudeshared` directory on the host is bind-mounted read-write at `/claudeshared` inside
the sandbox. Clone repos there on the host and they appear inside the sandbox (and vice versa).
Files written by the in-sandbox agent at `/claudeshared` appear on the host owned by your user
(UID alignment is automatic via virtiofs).

---

## Post-session egress audit

After a Claude session, you can surface the sandbox's network activity logs with:

```bash
./rebuild.sh --audit
```

This runs `openshell logs claude-sandbox --source all` and prints the output to your terminal.
It exits immediately without running any build, teardown, or create steps.

### What to look for in the logs

Review the output for outbound connection attempts or denials. Specifically:

- **Outbound connection attempts to non-gateway hosts** — should not appear; all model inference
  is routed through `inference.local` (the OpenShell gateway). If you see direct connections to
  `api.anthropic.com` or other external hosts, the egress policy is not active.
- **Landlock denials** — indicate the sandbox attempted a filesystem operation outside its policy.
  A denial at `/claudeshared` means `policy.yaml` was not applied correctly.

**Note:** `--audit` only surfaces logs for after-the-fact review. It does not assert or verify the
egress policy. Zero-egress enforcement (empty `network_policies` in a sandbox policy) is delivered
in Phase 3 of this project. The `--audit` flag is the BLD-05 operator review surface; treat it as
an observation tool, not a security gate.

---

## One-time inference provider setup

This is a **host-side operator action** — `rebuild.sh` asserts that it has been done (Step 0
preflight) but never performs it. Credentials are never baked into the image or Dockerfile
(NET-03/D-04): the OpenShell gateway injects the real subscription credential host-side by reading
your existing Claude Code OAuth state. No `ANTHROPIC_API_KEY` is involved.

Run these commands once on the host before the first `./rebuild.sh`:

```bash
# Register the inference provider using your existing Claude Code subscription login
# (reads ~/.claude/.credentials.json / macOS keychain — OAuth, no API key needed)
openshell provider create --name claude-code --type claude-code --from-existing

# Point the gateway at the provider and set the model
# Replace <MODEL> with the model name your Claude subscription provides
# (e.g. claude-opus-4-5, claude-sonnet-4-5 — confirm with `openshell inference get` after set)
openshell inference set --provider claude-code --model <MODEL>

# Verify registration
openshell inference get

# Check provider credential freshness
openshell provider refresh status claude-code
```

**Note:** `--type claude-code` is the assumed subscription/OAuth profile type; confirm the exact
value on first run if `openshell provider create` reports an unrecognized type. `--from-existing`
reads your host Claude Code OAuth state — it is only valid as a host-shell command, never inside
the Dockerfile or sandbox (per CLAUDE.md "What NOT to Use"). Until this setup is complete, `./rebuild.sh`
will exit at Step 0 with an actionable error, and the Step 7 round-trip will report WARN.

---

## Operator validation checklist

After a successful `./rebuild.sh` (all gates PASS), confirm the full multi-turn interactive session
works (criterion #2: live multi-turn interactive session, ≥2 round-trips):

### Steps

1. Connect to the running sandbox:

   ```bash
   openshell sandbox connect claude-sandbox
   ```

2. Inside the sandbox, start Claude in fully-autonomous mode:

   ```bash
   claude --dangerously-skip-permissions
   ```

   **Note:** Use `--dangerously-skip-permissions` (not `--allow-dangerously-skip-permissions`).
   The latter prompts interactively on each risky action and is not suitable for autonomous operation.

3. Send at least two messages and confirm model responses are returned. Both round-trips should
   succeed through `inference.local` (the OpenShell gateway), with no direct egress to
   `api.anthropic.com` (confirmed by the NET-05 smoke test and NET-04 policy assertion earlier
   in the rebuild).

4. Exit Claude and the sandbox session when done:

   ```bash
   /exit
   exit
   ```

If model responses are not returned, check:
- `./rebuild.sh --audit` for connection errors in the sandbox logs
- `openshell provider refresh status claude-code` on the host (credential may need refresh)
- `openshell inference get` to confirm the provider is still registered
