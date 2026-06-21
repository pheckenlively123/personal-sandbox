# Security Guidelines

Repo-specific security playbook for AI agents changing this code. This is a network-isolated OpenShell sandbox that runs Claude Code with `--dangerously-skip-permissions`; the subscription OAuth token lives inside the sandbox at `~/.claude/.credentials.json`. Every rule below exists to keep that token isolated and egress minimal. When in doubt, fail closed.

## Editing `policy.yaml`

The `--policy` flag **overrides** the built-in default entirely (no merge). Keep the full filesystem/landlock/process baseline intact — dropping it breaks sandbox provisioning (`Permission denied (os error 13)`).

1. **Never add a `protocol` field to any egress endpoint.** Omitting `protocol` = opaque TCP/TLS passthrough; the proxy never decrypts the stream. `protocol: rest` terminates TLS and exposes the OAuth token. There is no valid reason to add it.
2. **Never widen an allowlist.** The only egress hosts are: `api.anthropic.com`, `platform.claude.com`, `claude.ai` (`claude_egress`) and `proxy.golang.org`, `sum.golang.org`, `vuln.go.dev` (`go_egress`). Adding any host expands the exfiltration surface.
3. **Never cross-scope the two allowlists.** `claude_egress.binaries` = `/usr/bin/claude`, `/usr/local/bin/claude` only. `go_egress.binaries` = `/usr/bin/go`, `/usr/bin/golangci-lint`, `/usr/local/bin/govulncheck` only. A Go binary in the Claude policy (or vice versa) gives the wrong process a path to the OAuth-token hosts. This is the core isolation invariant.
4. **Never add `statsig.anthropic.com` or `sentry.io`.** They are intentionally absent; `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (Dockerfile ENV) suppresses the code paths that contact them. If Claude Code is genuinely degraded, the documented minimal follow-up is `statsig.anthropic.com:443` — and only after updating the NET-04 assertions to match.
5. **`read_only` vs `read_write` in `filesystem_policy`:** grant `read_write` only to paths that must persist agent writes — `/sandbox`, `/tmp`, `/dev/null`, `/claudeshared` (host bind mount), `/home/sandbox` (where the credentials file persists). Everything else (`/usr`, `/etc`, `/opt`, ...) stays `read_only`. The toolkit at `/opt` is read-only by design (T-04-02) — never make it writable.

## NET-04 / NET-05 assertion discipline

Every claim made by `policy.yaml` must be **asserted at rebuild time and fail closed**. If you change the policy, change the assertions in the same commit.

- `assert_claude_egress_allowlist()` (NET-04, `rebuild.sh`) is the source of truth. It must continue to assert, for every host: present at `:443`, **no `protocol` field**, correct binary scope; `statsig`/`sentry` **absent**; and the negative cross-scoping checks (no Go binary in the Claude policy, no `*/claude` in `go_egress`). Adding a host/policy without adding its NET-04 assertion means the isolation claim is *assumed, not enforced* — a stray binary would still PASS.
- The policy fetch is **guarded**: a failed or non-JSON `openshell policy get` aborts (exit 1) rather than feeding garbage to `jq`. Preserve this — never let an empty/failed fetch read as "host not found" or "telemetry absent."
- NET-05 (`run_egress_smoke_test()`) asserts **deny posture only**: `statsig`, `sentry`, `google` must fail to connect. `curl` is not the `claude` binary, so binary-scoping blocks it from every host — do not "fix" NET-05 to expect curl reachability of Anthropic hosts. Auth-host reachability is validated functionally by `./rebuild.sh login`.
- `check_telemetry_suppression()` (D-11, `scripts/audit-plugins.sh`) asserts **zero** `claude.exe` denials to statsig/sentry. A failed log fetch is itself a violation (it must not silently count as 0). Keep that fail-closed.
- Any new assertion: a non-zero/violation path must `exit 1` (or increment `VIOLATIONS` in the audit harness). No WARN escape hatch — a `MUST_FAIL_CLEAN` plugin exiting 0 without a network/MCP error is a hard FAIL, not a warning.

## Shell-injection avoidance

These scripts process registry output, CLI output, and plugin output. Treat all of it as untrusted.

1. **Never `eval`.** To assign a dynamically-named variable, use `printf -v` (see `build-and-lock.sh` CR-02):
   ```bash
   printf -v "${key}" '%s' "${val}"   # not: eval "${key}=${val}"
   ```
2. **Never `eval` external or plugin output.** `audit-plugins.sh` captures plugin output to a variable and **greps** it (T-04-07) — it never executes it:
   ```bash
   output=$(openshell sandbox exec ... -- claude ... -p "${prompt}" 2>&1) || rc=$?
   echo "${output}" | grep -qiE "40[13]|connection refused|..."   # inspect, never run
   ```
3. **Quote every expansion** — `"${var}"`, `"${array[@]}"`, `"$@"`. Unquoted `$since_arg`-style word-splitting is only acceptable with an explicit `# shellcheck disable=SC2086` and a clear reason (see `audit_sandbox`).
4. **Use argv form with `--`** for `openshell sandbox exec` so flags and the command are unambiguous and no shell re-parses the payload:
   ```bash
   openshell sandbox exec --name "${SANDBOX_NAME}" --no-tty -- curl -sS ... "${target}"
   ```
5. **Validate anything that flows into JSON before interpolating it.** `CLAUDESHARED_ABS` is checked to be an absolute path free of `"`, `'`, `\` before it is spliced into the `--driver-config-json` string (T-02-04). Do not build JSON from unvalidated CLI/registry output — prefer `jq -n --arg` (as `versions.lock` is assembled) over string concatenation.
6. **Keep `set -euo pipefail`** at the top of every script. Guard intentional non-zero commands with `|| true` and `${x:-default}` so `set -e`/`set -u` cannot abort on an expected empty/non-match (see the `grep -c ... || true; x=${x:-0}` telemetry-count pattern).

## Input-validation allowlist conventions

Validate by **allowlist regex, reject everything else** — never blocklist. Patterns in use:

- `BUILD_DATE` and `COOLDOWN_DATE`: `^[0-9]{4}-[0-9]{2}-[0-9]{2}$` (date only; flows into `--build-arg`, T-02-01).
- `GOVULNCHECK_VERSION`: `^v?[0-9][0-9A-Za-z._-]*$` (allows the `v` prefix).
- `GSD_CORE_VERSION`, `CLAUDE_CODE_VERSION`: `^[0-9][0-9A-Za-z._-]*$` (no `v` prefix).
- `CLAUDESHARED_ABS`: `^/[^\"\'\\]+` (absolute, no JSON-breaking chars).

Rules when adding inputs:
- Resolver `KEY=VALUE` output is parsed through a `case` allowlist; **unrecognised keys abort** (`exit 1`). Add a new key only with its own validation arm.
- Validate **before** any use (logging, interpolation, build-arg) so `set -u` can't abort with an unbound-variable error ahead of the friendly message (IN-01).
- Argument parsers fail closed: unknown args/verbs exit 1 with usage; a flag that needs a value checks `${2-}` is non-empty first.

## OAuth-token isolation model (the thing all of the above protects)

- The subscription token persists at `~/.claude/.credentials.json` inside the sandbox — this is the accepted trade-off. It only stays safe because: egress is the 3 Claude hosts (passthrough, never decrypted) scoped to the `claude` binary; the Go toolchain has its **own** 3-host allowlist and cannot reach the Claude hosts; and no other process can use either egress hole.
- Do not introduce an `ANTHROPIC_API_KEY`, an `inference.local` gateway, or a host-side `openshell provider create` — Architecture B has none of these. Auth is the in-sandbox OAuth flow only (`./rebuild.sh login`).
- The sandbox is ephemeral: `./rebuild.sh down` deletes it (and the token) between sessions. Don't add persistence that would outlive a teardown.
- Use `claude --dangerously-skip-permissions` (autonomous), never `--allow-dangerously-skip-permissions` (interactive prompts — wrong mode for this design).

## Pre-merge checklist for any change here

- [ ] No `protocol` field added to any egress endpoint.
- [ ] No new egress host; no allowlist cross-scoping; `statsig`/`sentry` still absent.
- [ ] `read_write` grants unchanged (or justified); `/opt` and `/usr`/`/etc` still `read_only`.
- [ ] Every new policy claim has a matching fail-closed NET-04/audit assertion in the same commit.
- [ ] No `eval`; `printf -v` for dynamic assignment; external/plugin output is grepped, never run.
- [ ] All expansions quoted; `exec` uses argv `-- ...`; JSON inputs validated before interpolation.
- [ ] New inputs validated by allowlist regex, before first use, with unknown values rejected.
- [ ] `set -euo pipefail` intact; intentional non-zero paths guarded.
