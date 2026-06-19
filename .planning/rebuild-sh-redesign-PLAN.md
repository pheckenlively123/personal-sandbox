# rebuild.sh Redesign Plan — Architecture B (hardened to api.anthropic.com-only direct egress)

Status: PLAN ONLY (no code changes in this task)
Author context: investigated against the live OpenShell source/docs at `~/git/OpenShell`
Target repo: `/Users/patrickheckenlively/git/personal-sandbox`

> **This revision SUPERSEDES the prior plan.** The earlier pass concluded the only stock-OpenShell
> path was an `ANTHROPIC_API_KEY` (console key) brokered through `inference.local`, and recommended
> driving the `claude-code` provider from an explicit key. The operator has **rejected** that model.
> This document re-grounds the design on the decided architecture below.

---

## 1. Context / Decision (LOCKED by operator)

The project is **abandoning the `inference.local` zero-egress / gateway-brokered model**. The new
architecture is **"B, hardened to api.anthropic.com-only":**

- **Claude Code runs INSIDE the sandbox and talks DIRECTLY to `api.anthropic.com:443`** using the
  operator's **Claude subscription via the normal OAuth login flow** (login URL copied to a browser
  *outside* the sandbox; the auth code is pasted back into the in-sandbox prompt).
  **No `ANTHROPIC_API_KEY`. No `inference.local`. No gateway model-forcing. No host-side provider.**
- The sandbox network policy must **allowlist EXACTLY `api.anthropic.com:443` and nothing else.**
  Explicitly **NOT** `statsig.anthropic.com` and **NOT** `sentry.io` (the stock `claude-code`
  provider profile bundles those two — we drop them to shrink the telemetry/exfil surface). The
  open internet stays blocked (e.g. `curl google.com` from inside ⇒ blocked / `403`-class).
- The egress allow should, as a hardening step, be **bound to the `claude` binary** so only the
  Claude Code executable — not arbitrary processes in the autonomous sandbox — can reach Anthropic.

This intentionally changes CLAUDE.md's stated **core value** (was: "zero direct network egress, all
inference brokered through the OpenShell gateway, subscription with no API key"). The new core value
is: **the sandbox has a single, binary-scoped, TLS-opaque egress hole to `api.anthropic.com:443`
for Claude Code's subscription OAuth traffic, and nothing else reaches the open internet.**

### Why this is materially different from the old model

| Aspect | Old (inference.local) | New (B-hardened) |
|---|---|---|
| Egress | Zero (`network_policies: {}`) | One L4 passthrough entry: `api.anthropic.com:443` |
| Credential | Provider record (console API key), injected host-side | Subscription OAuth token, lives **inside** the sandbox at `~/.claude/.credentials.json` |
| Who decrypts TLS | Gateway terminates & re-injects credential | **Nobody** — passthrough, proxy never sees plaintext |
| Model selection | Gateway force-overrides one model | Claude Code native `/model` (Opus/Sonnet/Haiku on the fly) restored |
| Host setup | `provider create` + `inference set` | None — login happens in-sandbox |

---

## 2. Findings (with OpenShell source citations)

All paths below are under `/Users/patrickheckenlively/git/OpenShell`.

### Finding 1 — Exact `network_policies` syntax for an `api.anthropic.com:443`-only PASSTHROUGH allow

**The passthrough (opaque, non-TLS-terminating) allow is expressed by OMITTING `protocol`.** This is
the single most load-bearing fact for the design:

- Policy schema, endpoint `protocol` field: *"Set to `rest` for HTTP method/path inspection … **Omit
  for TCP passthrough.**"* (`docs/reference/policy-schema.mdx:158`)
- Policy doc, network_policies semantics: *"For endpoints with `protocol: rest`, the proxy
  auto-detects TLS and terminates it … **Endpoints without `protocol` allow the TCP stream through
  without inspecting payloads.**"* (`docs/sandboxes/policies.mdx:59`)
- Simple-endpoint example confirms the shape and the no-decrypt behavior: *"Endpoints without
  `protocol` use TCP passthrough, where the proxy allows the stream without inspecting payloads."*
  (`docs/sandboxes/policies.mdx:493`; YAML example at `:481-491`)
- Credential-injection requires plaintext, which only `rest`/terminate provides — confirming that a
  no-`protocol` endpoint is **not** decrypted: *"This resolution requires the proxy to see plaintext
  HTTP. Endpoints must use `protocol: rest` … or explicit `tls: terminate`. **Endpoints without TLS
  termination pass traffic through as an opaque stream**, and credential placeholders are forwarded
  unresolved."* (`docs/sandboxes/manage-providers.mdx:206`)

So a no-`protocol` endpoint is exactly what we want: the OAuth bearer token in the TLS stream is
**never** visible to the proxy. **Do NOT use `protocol: rest`** (would terminate TLS and expose the
subscription token / break OAuth pinning), and **do NOT attach the `claude-code` provider** (its
profile sets `protocol: rest`, `access: read-write`, `enforcement: enforce` on all three hosts and
brings `statsig.anthropic.com` + `sentry.io`) — see `providers/claude-code.yaml:18-34`.

**`tls` field nuance (important):** `tls: terminate` and `tls: passthrough` are **deprecated and have
NO effect** — the proxy decides termination from `protocol`, auto-detecting TLS by peeking the first
bytes. *"The values `terminate` and `passthrough` are deprecated and log a warning … have no effect
on behavior."* (`docs/reference/policy-schema.mdx:159`). The one meaningful value is **`tls: skip`**,
which *disables auto-detection* for "edge cases such as client-certificate mTLS or non-standard
protocols." For a plain HTTPS host like `api.anthropic.com`, omitting `protocol` already yields an
opaque stream; `tls: skip` is an optional belt-and-suspenders to guarantee the proxy never even
peeks/auto-terminates. **Recommendation: omit `protocol` (mandatory) and optionally add `tls: skip`
to be explicit that no termination is wanted.** (If `tls: skip` ever interferes with the connection,
the no-`protocol`-alone form is the documented passthrough and is sufficient.)

**Exact network policy block to add (the api.anthropic.com-only passthrough):**

```yaml
network_policies:
  anthropic_api:
    name: anthropic-api
    endpoints:
      - host: api.anthropic.com
        port: 443
        # NO protocol  -> opaque TCP/TLS passthrough; proxy never decrypts the OAuth stream.
        # tls: skip     # optional: also disable TLS auto-detection (belt-and-suspenders)
    binaries:
      - { path: /usr/bin/claude }
      - { path: /usr/local/bin/claude }
```

This goes into the project's existing `policy.yaml` (today it has **no** `network_policies` section
at all — see `policy.yaml:15-16` "Egress policy … intentionally deferred to Phase 3 … Do not add a
network section here"). Phase 3 created an **empty** `network_policies` for zero-egress; B-hardened
now needs **exactly this one named entry**. The static `filesystem_policy`/`landlock`/`process`
sections stay verbatim (they reproduce the built-in default the supervisor needs; dropping them
re-introduces the "Permission denied (os error 13)" provisioning failure noted in `policy.yaml:10-13`).

`--policy` is carried into create exactly as today (`rebuild.sh:492`,
`crates/openshell-cli/src/main.rs:1238-1241`: "Path to a custom sandbox policy YAML file. Overrides
the built-in default"). `network_policies` is the **dynamic** section, so it is also hot-reloadable
post-create via `openshell policy update`/`set` (`docs/sandboxes/policies.mdx:15,50,167`) — useful
for the verification gates but not required for steady state.

### Finding 2 — Binary-scoped egress is FEASIBLE and is how OpenShell already models Claude

**The `binaries:` list on a network_policy entry restricts which executables may use the endpoints.**
*"Only the listed binaries are permitted to connect to the listed endpoints."*
(`docs/reference/policy-schema.mdx:137`). *"A connection is allowed only when both [endpoint and
calling binary] match an entry in the same policy block."* (`docs/sandboxes/policies.mdx:59`).

- Worked example binds Claude + gh to api.github.com via `binaries: [{path: /usr/local/bin/claude},
  {path: /usr/bin/gh}]` (`docs/sandboxes/policies.mdx:546-548`).
- The OPA engine matches the binary against the socket-owning process's `exe`, its **ancestors**
  (process-tree walk), and uses `cmdline_paths` only as a *non-granting* hint
  (`crates/openshell-sandbox/src/opa.rs:42-53`). Critically, Claude Code's `exe` is `node`, and the
  engine correctly allows it because `/usr/local/bin/claude` appears as an **ancestor / declared
  binary**, not via the spoofable cmdline (`opa.rs` tests `allowed_binary_and_endpoint` at
  `:1268-1287`, `ancestor_binary_allowed` at `:1477-1500`, and `cmdline_path_does_not_grant_access`
  at `:1642-1671`). The stock `claude_code` test fixture binds exactly to
  `/usr/local/bin/claude` (`opa.rs:1229-1232`).
- The stock provider profile lists **both** candidate paths: `binaries: [/usr/bin/claude,
  /usr/local/bin/claude]` (`providers/claude-code.yaml:34`). We mirror both for robustness.

**Claude binary path in THIS image:** installed via `npm install -g @anthropic-ai/claude-code`
(`Dockerfile:65`). RPM `nodejs` on Fedora puts global bins under `/usr/bin` (prefix `/usr`), so the
likely real path is `/usr/bin/claude`, but npm prefix can vary; listing **both** `/usr/bin/claude`
and `/usr/local/bin/claude` covers it. *Operator must confirm with `command -v claude` / `readlink
-f $(command -v claude)` inside the image* (open question §7). Note the binary is a node script, so
the match relies on the ancestor/declared-path logic above — confirmed supported.

> Hardening verdict: **include the `binaries:` scope.** It costs nothing and means a rogue process in
> the `--dangerously-skip-permissions` sandbox cannot use the Anthropic hole for exfiltration —
> only Claude Code can. If a binary-path mismatch ever blocks Claude, the fallback is to widen to a
> glob (`/usr/*/bin/claude`) or, last resort, drop `binaries` to host-only scoping — but start scoped.

### Finding 3 — In-sandbox subscription OAuth login flow (no host-side credential step)

**Confirmed: there is NO host-side credential step in B-hardened.** No `provider create`, no
`inference set`, no `ANTHROPIC_API_KEY`. Claude Code itself performs the OAuth subscription login the
first time it runs inside the sandbox:

- The documented `inference.local` invocation explicitly notes that **default Claude Code does the
  OAuth login**, and that `--bare` is the flag that *skips* it: *"`--bare` skips the OAuth login
  flow and uses `ANTHROPIC_API_KEY` directly."* (`docs/sandboxes/inference-routing.mdx:205,208`). In
  B-hardened we want the **opposite of `--bare`** — i.e. run plain `claude` so the OAuth flow runs.
- OAuth is interactive: Claude prints a login URL, the operator opens it in a browser **outside** the
  sandbox, authenticates with the subscription, and pastes the returned code back into the
  in-sandbox prompt. The resulting token lands at `~/.claude/.credentials.json` **inside the
  sandbox** (the sandbox's own home, not the host). `rebuild.sh` cannot fully automate the
  browser/paste step.
- The egress for this flow is satisfied by the `api.anthropic.com:443` passthrough (Finding 1).
  Outbound to `inference.local` is irrelevant now (and `inference.local` is the *only* host that
  bypasses the proxy per `docs/sandboxes/policies.mdx:59`; everything else, including Anthropic, is
  policy-gated).

**Workflow `rebuild.sh login` should drive:** `openshell sandbox connect <name>` into the sandbox,
then run `claude` (no `--bare`) so the OAuth prompt appears; the README documents the
browser-outside / paste-code step. Re-running `login` re-attaches if the token expired. No
`openshell provider *` command is involved at any point.

### Finding 4 — Dockerfile / runtime change: drop `ANTHROPIC_BASE_URL=https://inference.local`

**`ANTHROPIC_BASE_URL` is set in the image and must be removed** so Claude Code falls back to its
default `api.anthropic.com`:

- `Dockerfile:106-107`: `ENV ANTHROPIC_BASE_URL=https://inference.local`. Removing this ENV makes
  Claude Code use its built-in default base URL (`api.anthropic.com`). No other `ANTHROPIC_BASE_URL`
  assignment exists in the repo (grep confirmed only `Dockerfile:107`, plus prose in README).
- `Dockerfile:108` `CMD ["claude", "--dangerously-skip-permissions", "--plugin-dir", ...]` stays —
  but note this CMD runs at sandbox *create* with `-- /bin/true` override today; the interactive
  login uses `connect` + `claude`. (The CMD is fine to keep for the eventual autonomous run; just do
  NOT add `--bare`, since `--bare` would bypass the subscription OAuth login we now rely on.)
- No `inference.local` assumption may remain in image/runtime.

### Finding 5 — Invert the NET gates: from "deny all egress" to "verify the allowlist"

The current gates **contradict** B-hardened and must be re-purposed (still fatal / fail-closed):

- **NET-04 today** (`assert_no_anthropic_egress`, `rebuild.sh:189-203`) fails if **any** Anthropic
  endpoint appears in the effective policy. Under B-hardened that is exactly backwards. **New NET-04
  (policy assertion):** assert the effective live policy CONTAINS an `api.anthropic.com:443` endpoint
  that is **passthrough** (no `protocol`) and is **binary-scoped to claude**, AND assert it does
  **NOT** contain `statsig.anthropic.com`, `sentry.io`, or any `protocol: rest`/TLS-terminating
  Anthropic endpoint. Query via `openshell policy get <name> --full -o json` (same source as today,
  `rebuild.sh:192`).
  - PASS requires (all): `api.anthropic.com` present with `port 443`, no `protocol` field on it,
    `binaries[].path` matching `*/claude`.
  - FAIL if any of: `statsig.anthropic.com` present, `sentry.io` present, `api.anthropic.com` carries
    `protocol: rest`/`websocket`/`graphql`, or `api.anthropic.com` absent entirely.
- **NET-05 today** (`run_egress_smoke_test`, `rebuild.sh:214-228`) PASSes only when **every** target
  (including `api.anthropic.com`) is BLOCKED. Under B-hardened `api.anthropic.com` must be
  **reachable**. **New NET-05 (egress smoke test):** in-sandbox curl, three assertions —
  1. `https://api.anthropic.com` **reachable** (TCP/TLS connect succeeds — PASS = curl can open the
     connection; a `401/4xx` HTTP body is still a PASS because it proves the proxy allowed the
     stream. Use `curl -sS -o /dev/null -w '%{http_code}' --max-time 8` and treat
     "connection established / any HTTP status" as reachable; only a connection-refused / proxy-deny
     (curl exit 7/35/28-class or empty) is a FAIL).
  2. `https://statsig.anthropic.com` **BLOCKED** (curl connect fails — proxy denies).
  3. `https://sentry.io` **BLOCKED**.
  4. `https://www.google.com` (arbitrary host) **BLOCKED** — proves deny-all-except-allowlist
     (operator's stated `curl google.com → 403`).
  Keep the existing `openshell sandbox exec --no-tty -- curl …` mechanism and the `2>/dev/null`
  stderr suppression (`rebuild.sh:220`). Both gates remain **fatal** (`exit 1` on violation).
- **D-06 round-trip** (`run_inference_round_trip`, `rebuild.sh:247-273`) targeted
  `inference.local/v1/messages` and is now obsolete. **Remove it** (there is no `inference.local`
  and no placeholder-key round-trip; a real subscription round-trip requires interactive OAuth, which
  is the operator's `login` + validation-checklist step, not an automated curl). The reachability
  half is already covered by new NET-05 assertion #1.

### Finding 6 — Remove obsolete model machinery (deliberate simplification)

With the gateway no longer in the inference path, **the gateway no longer force-overrides the model**,
so Claude Code's native `/model` selection (Opus/Sonnet/Haiku, switchable mid-session) works again.
Therefore **remove** from `rebuild.sh`:

- `ensure_inference_provider()` (`rebuild.sh:64-133`) — entire function.
- `check_inference_provider()` (`rebuild.sh:152-179`) — entire function (the OpenShell #759
  "missing-provider ~290s hang" no longer applies because no provider/inference route is configured).
- `--model` / `--set-model` flags, `MODEL` default, `SET_MODEL_MODE`, the model-id allowlist guard,
  and the `--set-model` fast-switch block (`rebuild.sh:293-294, 317-342, 354-362, 385-393`).
- All `openshell inference set` / `openshell provider create|update` calls.
- Step 0 wiring (`rebuild.sh:396-403`).

Document this as a **simplification win**: fewer host preconditions, no gateway model coupling, and
**on-the-fly model selection restored**.

### Finding 7 — Single entry point, verb-first surface (grounded in real subcommands)

`openshell sandbox` subcommands (`crates/openshell-cli/src/main.rs:1166-1452`): `create`, `get`,
`list`, **`delete`** (`:1335-1345`, `--all` at `:1342`), `exec` (`:1360-1391`), **`connect`**
(`:1393-1406`, reconnects to last-used when no name), `upload`, `download`, `ssh-config`. **There is
NO native `stop`/`start`/`pause`/`resume`** — lifecycle = create/delete/connect/exec. `openshell
logs` backs `audit`. There is **no `openshell provider login`** for Claude; the only `Login` verb is
`gateway login` (edge-proxy OIDC, unrelated — `main.rs:1029`). The "login" we add is purely a
convenience wrapper around `connect` + `claude` (Finding 3).

Final verb surface (defaults to `rebuild`):

```
./rebuild.sh                         # full clean rebuild (default verb)
./rebuild.sh rebuild [--cooldown-days N]
./rebuild.sh status                  # podman + gateway + sandbox + effective-policy summary (read-only)
./rebuild.sh connect                 # openshell sandbox connect claude-sandbox
./rebuild.sh login                   # connect + launch `claude` OAuth flow (browser-outside, paste code)
./rebuild.sh down                    # openshell sandbox delete claude-sandbox (idempotent; no native stop)
./rebuild.sh audit [--since <ts>]    # openshell logs claude-sandbox --source all
```

**Dropped:** `set-model` and `set-key` (no model machinery, no API key). Keep `--cooldown-days`
and `--audit` as backward-compat aliases only.

### Finding 8 — Portability fixes (carried over from prior plan; still required)

- **Keychain / `.credentials.json` host-read references are removed.** Under B-hardened the only
  `~/.claude/.credentials.json` that exists is **inside the sandbox** (written by the in-sandbox
  OAuth flow). There is no host keychain read and no `--from-existing`. Delete the macOS-keychain
  prose at `rebuild.sh:61,105,118` and `README.md:39-41,110-111`.
- **`podman machine` → portable `ensure_podman_ready()`.** Replace the unconditional `podman machine
  inspect/start` (`rebuild.sh:65-80`) with: detect a configured machine
  (`podman machine list --format '{{.Name}}'` non-empty ⇒ macOS/machine host → inspect+start if not
  running); else native Linux/Fedora → `systemctl --user start podman.socket 2>/dev/null || true`
  (socket path `$XDG_RUNTIME_DIR/podman/podman.sock` per
  `crates/openshell-driver-podman/src/config.rs:219-243`; systemd-user socket per
  `docs/reference/sandbox-compute-drivers.mdx:237`). Single readiness gate on `podman info
  >/dev/null 2>&1` with a platform-appropriate hint on failure. This is still needed because the
  OpenShell **gateway/driver** runs the sandbox via the podman socket even though inference no longer
  flows through it.
- Existing portable bits stay: `python3` timestamps (`rebuild.sh:37,408`), `jq`/`awk`/`grep -qE`,
  `mkdir -p`, `--driver-config-json` bind mount, tolerate-absent teardown.

---

## 3. Recommended Design

### 3.1 Command surface

Verb-first dispatch (Finding 7). `rebuild` is the default when no verb is given. `--cooldown-days`
and `--audit` retained as aliases. Keep `set -euo pipefail`, fail-closed preflight, and the
bind-source path-safety guard (`rebuild.sh:481-484`).

### 3.2 `policy.yaml` — add the one passthrough entry

Append the `network_policies.anthropic_api` block from Finding 1 to the existing `policy.yaml`
(static sections unchanged). No `protocol` (mandatory); `tls: skip` optional. `binaries:` scoped to
`/usr/bin/claude` + `/usr/local/bin/claude`.

### 3.3 Rebuild flow (new step order)

```
preflight (podman, openshell, python3, jq)        # unchanged tools
ensure_podman_ready                                # portable (Finding 8)
build-and-lock.sh  -> image                        # unchanged
tag :latest                                        # unchanged
teardown (sandbox delete + old images)             # unchanged, idempotent
sandbox create --policy policy.yaml + bind mount   # unchanged mechanics; policy now carries the allow
NET-04: assert effective policy = anthropic-only passthrough, claude-scoped, no statsig/sentry  (FATAL)
NET-05: in-sandbox curl: anthropic REACHABLE; statsig/sentry/google BLOCKED                     (FATAL)
final summary banner (no model line, no round-trip line)
```

There is **no Step 0** anymore (no provider/inference setup). The login is a **separate operator
step** (`./rebuild.sh login` or the validation checklist), because OAuth is interactive.

### 3.4 Login verb

```bash
login() {
    ensure_podman_ready
    log_info "Launching Claude OAuth login inside ${SANDBOX_NAME}."
    log_info "A login URL will appear — open it in a browser OUTSIDE the sandbox, then paste the code back."
    openshell sandbox connect "${SANDBOX_NAME}"   # operator runs `claude` (no --bare) inside, completes OAuth
}
```

(Or drop straight into `claude` via `openshell sandbox exec --tty -- claude` — but `connect` is the
documented interactive entry and leaves the operator in the sandbox shell, which is friendlier for
the paste-the-code step. Decide during implementation; both are valid.)

### 3.5 Fail-closed guarantees (restated)

- Full clean rebuild every run (D-01); tolerate-absent teardown (D-02).
- NET-04 and NET-05 are **fatal** gates — a rebuild that cannot prove "anthropic-only, claude-scoped,
  nothing else" aborts non-zero.
- No non-fatal inference round-trip anymore (removed with the gateway path).

---

## 4. File-by-file changes

### `rebuild.sh`
- Header/usage (1-28): rewrite to the verb surface; drop the inference-provider/model framing.
- **Delete** `ensure_inference_provider` (64-133) and `check_inference_provider` (152-179).
- **Add** `ensure_podman_ready()` (Finding 8) — machine-detect + `systemctl --user start
  podman.socket` + `podman info` gate.
- **Rewrite NET-04** `assert_no_anthropic_egress` → `assert_anthropic_only_egress` (Finding 5): jq
  asserts `api.anthropic.com:443` present, no `protocol`, `binaries[] ~ */claude`; asserts
  `statsig.anthropic.com`/`sentry.io` ABSENT; fatal on any miss.
- **Rewrite NET-05** `run_egress_smoke_test` (Finding 5): anthropic reachable (any HTTP status =
  pass); statsig, sentry, google.com blocked (curl connect failure = pass); fatal otherwise.
- **Delete** `run_inference_round_trip` (247-273), `ROUND_TRIP_STATUS`, Step 7, and the round-trip
  summary line.
- **Delete** `--model`/`--set-model`/`MODEL`/`SET_MODEL_MODE`, the model-id allowlist (354-362), and
  the `--set-model` fast-switch (385-393).
- Arg parser (299-351): verb dispatch (`rebuild`/`status`/`connect`/`login`/`down`/`audit`) +
  `--cooldown-days`/`--audit` aliases.
- New verb handlers: `status`, `connect`, `login`, `down` (idempotent `sandbox delete`).
- Final summary banner: drop "Round-trip" and model lines; add the egress-allowlist confirmation
  lines.

### `policy.yaml`
- Replace the `:14-16` "no network section" comment with the rationale for the single passthrough
  entry; add the `network_policies.anthropic_api` block (Finding 1 / §3.2). Static sections unchanged.

### `Dockerfile`
- Remove `ENV ANTHROPIC_BASE_URL=https://inference.local` (`:106-107`). Keep `CMD` (do NOT add
  `--bare`). Add a comment that Claude Code now uses its default `api.anthropic.com` and authenticates
  via in-sandbox subscription OAuth.

### `README.md`
- Rewrite "Rebuilding the sandbox" / Options to the verb surface; remove `--model`/`--set-model`.
- Replace the entire "Inference provider setup" section (103-146) and the Step-0 description (36-42)
  with: **no host-side setup; first run does an in-sandbox subscription OAuth login** (URL → browser
  outside → paste code; token stored at `~/.claude/.credentials.json` inside the sandbox). Note
  on-the-fly model selection via `/model` is now available.
- Update the egress-audit section (75-99) and the validation checklist (150-188): connect, run
  `claude` (NOT `--bare`) for the OAuth flow, confirm ≥2 round-trips that go DIRECT to
  `api.anthropic.com` (allowed by the scoped passthrough), and that statsig/sentry/google are blocked.

### `CLAUDE.md` (core-value rewrite — pending operator confirmation)
- Rewrite the **Core Value** paragraph and Constraints "Network" line: from "zero direct egress,
  inference via gateway only" to "single binary-scoped TLS-opaque egress allow to
  `api.anthropic.com:443` for Claude Code subscription OAuth; all other egress blocked."
- Remove/replace the entire "Gateway Inference Brokering (`inference.local`)", "Zero-Egress Policy",
  and `inference set`/provider-create guidance — those describe the abandoned model.
- Update "What NOT to Use": the `ANTHROPIC_BASE_URL=https://inference.local` and
  `--add-endpoint api.anthropic.com:443` rows are now inverted (we DO add exactly that endpoint, as a
  passthrough, scoped to claude). Keep the cooldown/pinning sections (still accurate).

---

## 5. Verification plan

**Claude-checkable (static, no live host):**
- `bash -n rebuild.sh` parses; `shellcheck` clean.
- `policy.yaml` has `network_policies.anthropic_api` with `host: api.anthropic.com`, `port: 443`,
  **no `protocol:`** key under that endpoint, and `binaries:` containing `*/claude`. No
  `statsig.anthropic.com`, no `sentry.io`, no `protocol: rest` Anthropic endpoint.
- No `inference.local`, `ANTHROPIC_BASE_URL`, `--model`, `--set-model`, `ensure_inference_provider`,
  `check_inference_provider`, `--from-existing`, or keychain strings remain in
  `rebuild.sh`/`README.md`/`Dockerfile`.
- Dockerfile no longer sets `ANTHROPIC_BASE_URL`; CMD has no `--bare`.
- Verb dispatch covers `rebuild/status/connect/login/down/audit`.

**Operator-run on the live Fedora/Linux host:**
- `systemctl --user start podman.socket && podman info` succeeds; `./rebuild.sh status` clean.
- `command -v claude` / `readlink -f $(command -v claude)` inside the image confirms the binary path
  matches a `binaries:` entry (Finding 2 open question).
- Full `./rebuild.sh`: NET-04 PASS (anthropic-only passthrough, claude-scoped); NET-05 PASS
  (`api.anthropic.com` reachable; `statsig.anthropic.com`, `sentry.io`, `www.google.com` blocked —
  expect the `google → 403`-class block).
- `./rebuild.sh login` → inside sandbox run `claude`, complete browser-outside OAuth, paste code;
  confirm `~/.claude/.credentials.json` exists **inside** the sandbox.
- ≥2 interactive round-trips succeed going DIRECT to `api.anthropic.com`; `/model` switches between
  Opus/Sonnet/Haiku mid-session.
- Confirm Claude Code is not degraded with statsig/sentry blocked (open question §6).
- `./rebuild.sh down` deletes idempotently; re-run is a no-op.
- Regression on macOS: `podman machine` path still taken; everything still works.

---

## 6. Open questions / risks

1. **Subscription OAuth token inside an autonomous `--dangerously-skip-permissions` sandbox (TOP
   RISK).** The whole point of the abandoned model was that no real credential lived in the sandbox.
   B-hardened puts a live **subscription OAuth token** at `~/.claude/.credentials.json` *inside* a
   sandbox where Claude runs with elevated autonomous permissions. Mitigations in this design:
   (a) egress is restricted to `api.anthropic.com:443` only, so the token cannot be POSTed anywhere
   else; (b) the egress is binary-scoped to `claude`, so a non-claude process can't even open the
   Anthropic socket. Residual risk: a compromised/confused Claude could still use *its own* allowed
   channel, and the token file is readable within the sandbox. Operator must accept this trade
   (it is the explicit decision). Consider documenting token-rotation / `down` between sessions.
2. **statsig / sentry blocked — does Claude Code degrade?** Dropping `statsig.anthropic.com`
   (feature-flag/telemetry) and `sentry.io` (error reporting) is intentional. Claude Code should
   function (core API is `api.anthropic.com`), but there is a chance of noisy retries, slower
   startup, or a feature gated behind statsig. The stock `claude-code` provider profile bundles all
   three (`providers/claude-code.yaml:18-34`), implying upstream expects them reachable. **Operator
   must verify Claude Code is not degraded**; if it is, the minimal concession is to add
   `statsig.anthropic.com:443` (still passthrough, still claude-scoped) — but NOT `sentry.io`.
3. **Claude binary path uncertainty.** npm-global bin location on Fedora RPM nodejs (`/usr/bin` vs
   `/usr/local/bin`). Listing both covers the common cases; if neither matches (custom prefix), NET
   gates will fail closed and the operator widens the `binaries` glob. Must confirm in the image.
4. **Passthrough + SNI/host matching.** The proxy matches the endpoint by destination host. For an
   opaque TLS stream the host is taken from the CONNECT/SNI. `api.anthropic.com` is an exact declared
   hostname (`opa.rs:559-566` "exact_declared_endpoint_host"), so SSRF/private-IP handling is fine
   and no `allowed_ips` is needed. Low risk, but confirm a real connect succeeds in NET-05.
5. **No `stop` verb.** OpenShell has no pause/stop-without-delete; `down` = delete; `connect`
   re-attaches to the kept-alive sandbox. The in-sandbox OAuth token is destroyed on `down` (a
   feature for risk #1, but means re-login after each `down`).
6. **`tls: skip` interaction.** If the optional `tls: skip` ever interferes with the connection (it
   disables auto-detection), fall back to no-`protocol`-alone, which is the documented passthrough
   and sufficient to keep the stream opaque. Verify in NET-05 either way.
7. **`systemctl --user` session assumption** (headless/CI Fedora may need `loginctl enable-linger`);
   the `podman info` gate catches failure with a hint.
