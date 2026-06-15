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
