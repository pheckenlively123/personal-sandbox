# Integration Guidelines

Repo-specific playbook for crossing the seams between the five external systems the rebuild pipeline orchestrates: **podman** (image build + container lifecycle), the **OpenShell CLI** (sandbox create/exec/policy/logs), the **npm registry**, the **Go module proxy**, and the **claude binary** (OAuth). Every rule below is enforced somewhere in `rebuild.sh`, `scripts/build-and-lock.sh`, `scripts/resolve-versions.sh`, `scripts/audit-plugins.sh`, or `policy.yaml` — follow them when adding or modifying any integration.

These rules exist because each tool's stdout is **untrusted input** (registry-controlled, CLI-formatted, or network-dependent) and each invocation is a fail-fast gate in a security-hardened pipeline. The default posture is **fail-closed**.

---

## 1. Never trust raw stdout — parse + validate before feeding downstream

External-tool output is data, never code, and never assumed well-formed. Validate the **shape** of every value before it crosses into the next tool.

- **Never `eval` registry output.** `build-and-lock.sh` parses `resolve-versions.sh`'s `KEY=VALUE` lines through an explicit `while IFS='=' read -r key val` allowlist loop (CR-02): each key is matched against a known set, each value is regex-checked (`COOLDOWN_DATE` → `^[0-9]{4}-[0-9]{2}-[0-9]{2}$`; versions → `^v?[0-9][0-9A-Za-z._-]*$`), and assigned via `printf -v` — never `eval`. Unknown keys are a fatal error.
- **Validate before you build.** Version pins only reach `podman build --build-arg` *after* the parse/validate loop. `BUILD_DATE` is independently allowlist-checked (`^[0-9]{4}-[0-9]{2}-[0-9]{2}$`) before it flows into a `--build-arg` (T-02-01).
- **Validate before JSON interpolation.** In `rebuild.sh` Step 4, `CLAUDESHARED_ABS` is regex-checked (`^/[^\"\'\\]+`) to reject quotes/backslashes before being interpolated into the `--driver-config-json` string for `sandbox create`.
- **Check emptiness explicitly.** Every `curl … | jq -r '… // empty'` is followed by a `[[ -z … ]]` guard that fails the build (e.g. publish-timestamp fetches in `build-and-lock.sh` Step 4). A missing field is an error, not a default.
- **`resolve-versions.sh` discipline:** all diagnostics go to **stderr**; stdout carries only the `KEY=VALUE` lines so the caller's parser stays clean.

**Rule:** if a value came from a registry, a `curl`, or a CLI, regex- or `jq`-validate its shape and assert non-empty before the next command consumes it.

## 2. jq-structural-validate live JSON — but guard the fetch first

When asserting against live OpenShell JSON (`policy get`, `logs`), the fetch can fail or return non-JSON; that must surface as its own error, never as a downstream misfire.

Two-step guard pattern (from `assert_claude_egress_allowlist`, NET-04):

```bash
if ! policy_json=$(openshell policy get "${name}" --full -o json 2>&1); then
    log_error "NET-04: policy get failed — cannot assert"; exit 1; fi
if ! echo "${policy_json}" | jq empty >/dev/null 2>&1; then
    log_error "NET-04: output is not valid JSON"; exit 1; fi
# only now run structural jq -e assertions
```

- Capture `2>&1` so the error text is in the variable for logging; check the command's exit status *and* `jq empty` before any structural query.
- Without the guard, a failed fetch yields an empty string and every `jq -e 'select(.host==$h)'` returns false — silently reported as **"host NOT found"** (a false NET-04 violation). The guard makes the real cause (sandbox down / endpoint errored) visible.
- Structural assertions use `jq -e … >/dev/null` and branch on its exit code. Assert both **presence** (required hosts on :443) and **absence** (`statsig`, `sentry` must not match) — and **negative cross-scoping** (a Go binary must *not* appear under the `api.anthropic.com` policy, and `*/claude` must *not* appear under `proxy.golang.org`). Absence/isolation checks are as load-bearing as presence checks.
- Apply the same fetch-guard to `openshell logs` (`check_telemetry_suppression`): a failed log fetch is itself a violation — never let it collapse to an empty string and report a false "0 attempts" PASS.

## 3. OpenShell `exec`: `--tty` vs `--no-tty`, always `--workdir`

`openshell sandbox connect` has no working-dir flag and drops you at `/`, which is outside the Landlock allowlist (can't even `ls`). **Always use `sandbox exec … --workdir`**, never `connect`.

- **Interactive (human at a terminal):** `--tty`, `--workdir /claudeshared`. Used by the `connect`, `login`, and `claude` verbs to land in the read-write bind mount where repos are cloned.
- **Programmatic / headless (captured or asserted output):** `--no-tty`, plus `--timeout`, `--workdir`. Used by NET-05 (`curl` smoke test) and `audit-plugins.sh`. `--no-tty` keeps stdout free of terminal control bytes so it can be `grep`/`jq`-parsed.
- Always pass `--name "${SANDBOX_NAME}"` and put the in-sandbox command after `--`.
- The `claude` verb wraps the interactive exec in `set +e` / `set -e` and **preserves claude's real exit code** (`/exit`→0, Ctrl-C→130). Only codes other than 0/130 emit the failure hint. Do not force `exit 1` on an interactive session.

## 4. Bounded headless invocations + exit-code classification

Any unattended invocation of the `claude` binary (or other potentially-hanging tool) **must** be time-bounded and its exit code classified — never assume `rc==0` means success.

From `run_plugin_audit` (`audit-plugins.sh`), `openshell sandbox exec --no-tty --timeout 120 --workdir /claudeshared -- claude …`:

- **`exit 124` = timeout = HANG = always FAIL** (D-07), no exception, even for a plugin expected to fail.
- **`MUST_SUCCEED`:** `rc==0` → PASS; any non-zero → FAIL.
- **`MUST_FAIL_CLEAN`:** `rc==0` **and** output matches a network/MCP-error regex → PASS. `rc==0` **without** an error pattern → **MISMATCH → FAIL** (D-10: exit 0 alone is never a pass; no WARN escape). Non-zero → FAIL.
- Accumulate failures in a `VIOLATIONS` counter and `exit 1` if `>0`. Each handler `return 0` so one failure doesn't abort the run under `set -e` — the gate is the counter, not the first error.
- **Never `eval` or execute plugin output** (T-04-07). Classify it by exit code and `grep` pattern only.

## 5. Ordered fail-fast pipeline + subprocess delegation (thin wrappers)

`rebuild.sh rebuild` is an ordered, fail-fast pipeline (`set -euo pipefail`): preflight → build-and-lock → tag → teardown → create → NET-04 → NET-05. Any step's non-zero exit aborts the run.

- **Delegate, don't re-implement (D-05).** `rebuild.sh` never re-derives version pins or rebuilds the audit logic inline: it `bash`-invokes `scripts/build-and-lock.sh` (which itself delegates to `resolve-versions.sh` and `verify-pins.sh`) and `scripts/audit-plugins.sh`. The `audit-plugins` and `claude`/`connect`/`login` verbs are thin wrappers over one exec or one script call. Add new resolution/audit logic to the dedicated script and wrap it — don't fatten the dispatcher.
- **Post-build gate.** `build-and-lock.sh` calls `verify-pins.sh` as its final step; a build that can't prove its pins held does not "succeed."
- **Verb-first dispatch.** First positional arg is the verb (`rebuild|status|connect|login|claude|down|audit|audit-plugins`); flags follow. Unknown verbs/args fail with usage. `preflight_tools` (checks `podman openshell python3 jq` on PATH) runs for `status` and `rebuild`; `ensure_podman_ready` runs for `login`, `claude`, and `rebuild`. Other verbs (`connect`, `down`, `audit`, `audit-plugins`) skip both.
- **Idempotent, tolerate-absent teardown (D-01/D-02).** `sandbox delete` and `rmi` treat "not found" as success (normalize wrapped CLI error text before matching "not found"); any *other* error is fatal. Image cleanup targets only `localhost/claude-sandbox:*` and preserves the just-built tag — never `rmi -a` or untargeted prune.
- **`audit` ≠ `audit-plugins`.** `audit` is log-surfacing only and never asserts policy (D-07); `audit-plugins` is the strict hard-failing gate. Keep them separate.

## 6. policy.yaml binary paths must match installed paths exactly

The egress allowlists are **binary-scoped**: only the listed executable paths may open connections. These paths are matched against the *actual files the Dockerfile installs* — a mismatch silently denies all egress for that tool (the rebuild then fails NET-04 or the audit fails with HANG/UNEXPECTED).

| Tool | Installed by (Dockerfile) | Path in `policy.yaml` |
|------|---------------------------|------------------------|
| `claude` | npm global (RPM nodejs prefix) | `/usr/bin/claude` **and** `/usr/local/bin/claude` |
| `go` | RPM `golang` | `/usr/bin/go` |
| `golangci-lint` | RPM `golangci-lint` | `/usr/bin/golangci-lint` |
| `govulncheck` | `go install` → `cp` to `/usr/local/bin` | `/usr/local/bin/govulncheck` |

- List **both** candidate paths for `claude` (npm prefix differs across setups). If you change an install method or prefix in the Dockerfile, update the matching `binaries:` path in `policy.yaml` in the same change.
- `--policy` **overrides** the built-in default entirely (no merge). `policy.yaml` must therefore reproduce the full filesystem/landlock/process baseline *and* the allowlists. Dropping the baseline strips the grants the supervisor needs and the sandbox fails provisioning ("Permission denied / os error 13"). Required `read_write`: `/claudeshared` (bind mount) and `/home/sandbox` (or OAuth token never persists).
- **Keep the two egress scopes isolated.** `claude_egress` (api.anthropic.com, platform.claude.com, claude.ai) is scoped to `*/claude` only; `go_egress` (proxy.golang.org, sum.golang.org, vuln.go.dev) to the Go binaries only. Never add a Go binary to the Claude policy or vice-versa — NET-04 actively asserts the absence of cross-scoping to protect the OAuth token.

## 7. TLS passthrough & telemetry hygiene

- **Omit `protocol` on every endpoint** → opaque TCP/TLS passthrough; the proxy never decrypts the stream (and never sees the OAuth token). `protocol: rest` would terminate TLS — explicitly forbidden. NET-04 fails the build if any required endpoint carries a `protocol` field.
- **`statsig.anthropic.com` and `sentry.io` must stay absent** from the policy; `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (Dockerfile ENV) suppresses contact. NET-04 asserts their absence; `audit-plugins.sh` asserts **zero** `claude.exe` denial entries to them in `openshell logs --source sandbox --since <window>` (a denial means traffic was attempted → telemetry not suppressed → FAIL). Denials to `mcp-proxy.anthropic.com` / `datadoghq.com` / `downloads.claude.ai` are *expected* and logged as informational — the policy working correctly.
- Reachability of the Claude hosts is **never** asserted with `curl` (binary-scoping blocks `curl` from every host). NET-05 asserts the **deny posture only**; functional reachability is proven by `./rebuild.sh login` (the actual `claude` binary).
