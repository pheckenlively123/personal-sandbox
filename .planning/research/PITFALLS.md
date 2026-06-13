# Pitfalls Research

**Domain:** Network-isolated Claude Code sandbox (NVIDIA OpenShell / Fedora 44 / supply-chain cooldown)
**Researched:** 2026-06-13
**Confidence:** HIGH — core claims verified against OpenShell issues, npm docs, Go module proxy docs, Claude Code issue tracker, and official Fedora package data

---

## Critical Pitfalls

### Pitfall 1: Zero-Egress Denial Logging Is Silent by Default

**What goes wrong:**
The OpenShell egress proxy logs CONNECT and FORWARD deny decisions at `info` level, but the sandbox defaults to `WARN` log level. This means every outbound connection Claude Code makes that is correctly blocked by policy produces zero visible output. Operators see `403 Forbidden` from Claude Code internals and cannot distinguish "policy is working correctly" from "policy is misconfigured and blocking something it should allow."

**Why it happens:**
OpenShell's default logging level is WARN; the proxy's deny log statements use `info!()`. This mismatch is a known bug (NVIDIA/OpenShell issue #704, open as of this research). The result: a misconfigured policy that blocks the inference gateway looks identical to a correctly configured policy that blocks api.anthropic.com.

**How to avoid:**
- Set the OpenShell sandbox log level to `info` or `debug` during initial build and policy validation phases.
- After confirming the policy works, drop back to WARN for normal operation.
- During policy setup, run a test Claude Code session and actively check for deny entries in the logs before declaring the policy correct.
- Provide a diagnostic script that temporarily elevates log level and runs a connectivity probe.

**Warning signs:**
- Claude Code starts but immediately errors on first API call with a connection or 403 error.
- No log output correlating to connection denials despite the sandbox having a non-empty policy.
- `curl https://api.anthropic.com` from inside the sandbox either hangs or returns 403 with no proxy log entry.

**Phase to address:** Sandbox baseline / network policy setup phase (first phase of build work)

---

### Pitfall 2: Allowlisting api.anthropic.com Defeats the Zero-Egress Design

**What goes wrong:**
If the OpenShell policy is set to allowlist `api.anthropic.com` directly (rather than using inference routing through `inference.local`), the sandbox has direct internet egress to Anthropic's servers. This means Claude Code running with `--dangerously-skip-permissions` could potentially exfiltrate data read from `~/claudeshared` by embedding it in API payloads. The entire zero-egress guarantee is voided.

**Why it happens:**
This is the obvious "make Claude Code work" path. Without understanding OpenShell's inference routing, the natural fix for "Claude Code can't reach the model" is to allowlist the Anthropic API endpoint. The PROJECT.md explicitly identifies this as out of scope, but the temptation is real when debugging connectivity failures.

**How to avoid:**
- The policy must contain zero entries pointing to `api.anthropic.com`, `claude.ai`, or any Anthropic-controlled host.
- Inference must route through `inference.local` (the OpenShell gateway's loopback inference endpoint) using `ANTHROPIC_BASE_URL=http://inference.local`.
- Add a policy verification step in the rebuild script that asserts no Anthropic endpoints are in the allowlist.
- Document the inference.local endpoint in the Dockerfile entrypoint or launch script so there is no ambiguity.

**Warning signs:**
- The rebuild script or policy update command contains `api.anthropic.com`.
- Claude Code works but the OpenShell inference provider shows as "Not configured."
- A network audit from inside the sandbox shows successful DNS resolution of `api.anthropic.com`.

**Phase to address:** Sandbox baseline / network policy setup phase

---

### Pitfall 3: OpenShell Inference Gateway Misconfigured — Claude Hangs or 404s

**What goes wrong:**
If the OpenShell gateway provider or model is not configured before the sandbox starts, requests to `inference.local` return 404. Claude Code will either error immediately or — in the more dangerous case — hang silently for up to 290 seconds per API call before timing out (documented in NVIDIA/OpenShell issue #759, root cause unknown as of this research).

**Why it happens:**
The gateway must have `openshell provider create` and `openshell inference set` run before sandbox creation. These are host-side commands, not Dockerfile instructions. It is easy to build and launch the sandbox container before completing gateway setup. The 290-second hang occurs specifically in interactive long-running sessions; the `--print` (non-interactive) mode does not trigger it, making it hard to catch in smoke tests that only test non-interactive calls.

**How to avoid:**
- The rebuild script must include a preflight check: `openshell inference get` must show a configured provider and model before `openshell sandbox create` is called.
- Fail fast and loudly if the inference provider is missing.
- Test interactive multi-turn sessions (not just `--print` one-shots) as part of validation.
- Document the required host-side setup sequence (provider create, inference set) separately from the Dockerfile.

**Warning signs:**
- `openshell inference get` shows "Not configured."
- First interactive Claude Code message succeeds but subsequent messages hang for ~290 seconds.
- `POST inference.local/v1/chat/completions` returns 404 from inside the sandbox.

**Phase to address:** Sandbox baseline / network policy setup phase

---

### Pitfall 4: Claude Code Runtime Network Calls Are Not All Optional

**What goes wrong:**
Claude Code makes several categories of outbound network calls at runtime beyond inference:
1. **Auto-update check**: fetches available version information on startup.
2. **Telemetry** (two tiers: essential crash reports and non-essential analytics).
3. **MCP server calls**: if any MCP server configured in Claude's settings makes outbound HTTP calls (e.g., the claude-engineering-toolkit plugins), those calls go through the sandbox's network policy and will be blocked unless allowlisted.

With zero egress, Claude Code will silently fail on auto-updates (acceptable) and telemetry (acceptable), but will produce confusing errors or silently degrade if an MCP server plugin tries to fetch from an external API.

**Why it happens:**
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` disables auto-updates and non-essential telemetry but also bundles `DISABLE_AUTOUPDATER` (verified: Anthropic support confirmed, per Claude Code issue #53899). This convenience flag does not cover MCP servers — those are separate processes that make their own network calls.

The claude-engineering-toolkit is cloned at HEAD and trusted, but if any of its plugins or agents make external HTTP calls (web search, documentation lookup, etc.), those will be blocked by the zero-egress policy. This can manifest as silent tool failures rather than obvious errors.

**How to avoid:**
- Set `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` in the sandbox entrypoint to suppress auto-update and telemetry noise.
- Audit every plugin in the claude-engineering-toolkit fork before launch: check whether any agent or skill makes outbound HTTP calls.
- For any plugin that needs network access, decide at build time: either allowlist the specific endpoint in the policy (with explicit justification), or disable/replace that plugin.
- Test MCP tool calls inside the sandbox and verify each tool either succeeds or fails cleanly (not hangs).

**Warning signs:**
- Claude Code tool calls time out rather than immediately failing.
- Claude reports a tool as "unavailable" without a clear error.
- Log shows `403 host_not_allowed` from MCP server processes.

**Phase to address:** Claude Code and MCP configuration phase

---

### Pitfall 5: npm --before Does Not Apply to `npm update`, Only `npm install`

**What goes wrong:**
`npm install --before <date>` filters dependency resolution to only versions published before that date, applying to both direct and transitive dependencies during a fresh install. However, `npm update` does NOT support `--before`. If the rebuild script uses `npm update` (or `npm install` is run against a pre-existing `node_modules` directory without clearing it), the cooldown filter does not apply and fresh (potentially post-cooldown) package versions can be pulled.

Additionally, if a `package-lock.json` exists with versions published after the `--before` date, npm will fail with `ETARGET` rather than silently downgrading — this is the correct behavior but will break the build until the lockfile is deleted and regenerated.

**Why it happens:**
Developers are accustomed to `npm install` being idempotent against a lockfile. The `--before` workflow requires: (1) delete the lockfile, (2) run `npm install --before <cooldown-date>`, (3) capture the new lockfile. If step 1 is skipped, the lockfile's pinned versions may include post-cooldown packages, and the `--before` flag errors rather than resolving the conflict.

npm >= 11.10.0 introduced `--min-release-age=<days>` as a relative alternative to `--before`. As of Node v26 / npm 11 on this host, `--min-release-age` is available and is the preferred idiom for rolling cooldowns (avoids computing an absolute date).

**How to avoid:**
- In the Dockerfile, never copy in a `package-lock.json` from the host — always regenerate it inside the build.
- Use `npm install --before <cooldown-date>` (or `--min-release-age=4` with npm 11.10+) without a pre-existing lockfile.
- After install, copy the generated lockfile out of the container as a build artifact for reproducibility audits.
- Do NOT use `npm update` in any cooldown-aware install step.

**Warning signs:**
- Build exits with `npm ERR! code ETARGET` — indicates lockfile has post-cooldown versions.
- Lockfile `package-lock.json` contains a `resolved` timestamp newer than the cooldown date.
- `node_modules` directory exists before the `npm install` step runs.

**Phase to address:** Supply-chain pinning / Dockerfile authoring phase

---

### Pitfall 6: `go install ...@latest` Has No Date-Based Pinning Mechanism

**What goes wrong:**
Go's module system has no equivalent of npm's `--before` or `--min-release-age`. `go install golang.org/x/vuln/cmd/govulncheck@latest` always resolves to the latest version at the time of the command — it ignores any "as of date" concept. The index.golang.org `since` parameter is a feed-forward filter for listing new modules, not a way to query "latest version as of date X."

This means the PROJECT.md requirement to "pin govulncheck to the latest version as of the cooldown date" cannot be implemented with a simple `@latest` call. Without an explicit version pin or a query to index.golang.org, `@latest` resolves whatever is newest at build time — defeating the cooldown intent.

**Why it happens:**
The Go module proxy protocol does not expose a "list versions published before date X" endpoint in a way that `go install` natively understands. Developers assume that because npm supports `--before`, Go has an equivalent, but it does not.

**How to avoid:**
- Implement cooldown pinning for govulncheck by querying index.golang.org before the Docker build:
  ```bash
  # On the host, before building:
  COOLDOWN_DATE="2026-06-09T00:00:00Z"
  # Fetch the module version list and filter by published timestamp
  VERSION=$(curl -s "https://index.golang.org/index?since=1970-01-01T00:00:00Z&limit=2000" \
    | grep '"golang.org/x/vuln"' | awk -F'"' '{print $6, $4}' \
    | awk -v d="$COOLDOWN_DATE" '$1 <= d {print $2}' | tail -1)
  go install golang.org/x/vuln/cmd/govulncheck@$VERSION
  ```
  Alternatively, use `pkg.go.dev` or the proxy's `/@v/list` endpoint to determine the latest tag before the cooldown date, then pass that explicit version tag as a build ARG.
- Store the resolved version in a manifest file (e.g., `.planning/versions.lock`) that the Dockerfile reads as an ARG — this makes the version explicit and auditable.
- Never use `@latest` in the Dockerfile directly for cooldown-controlled tools.

**Warning signs:**
- Dockerfile contains `go install golang.org/x/vuln/cmd/govulncheck@latest` without a preceding version resolution step.
- `govulncheck --version` inside the sandbox shows a release date after the cooldown date.
- Rebuilds on different days install different versions despite no explicit version change.

**Phase to address:** Supply-chain pinning / Dockerfile authoring phase

---

### Pitfall 7: Docker Layer Cache Causes `dnf update -y` to Reuse Stale Package Metadata

**What goes wrong:**
Docker's build cache caches RUN layers. If `RUN dnf update -y` is cached, the rebuild does not actually run a fresh `dnf update` — it reuses the cached layer from the previous build. This means the "rebuild applies rolling cooldown" guarantee is false: packages installed via RPM can be stuck at whatever was current during the first build.

**Why it happens:**
Docker (and Podman build) cache layers by instruction hash. `RUN dnf update -y` always hashes to the same string, so unless a preceding layer has changed, it is served from cache. The rebuild script's goal of "re-applies the rolling cooldown each run" is defeated silently.

**How to avoid:**
- Pass a build ARG that changes every rebuild and appears before the `dnf update` layer:
  ```dockerfile
  ARG COOLDOWN_DATE
  RUN echo "Cooldown: ${COOLDOWN_DATE}" && dnf update -y && dnf clean all
  ```
  Then pass `--build-arg COOLDOWN_DATE=2026-06-09` in the rebuild script. Changing this value busts the cache for all subsequent layers.
- Alternatively, always pass `--no-cache` to `docker build` / `podman build` in the rebuild script, but this rebuilds everything from scratch each time, which is slower.
- The rebuild script must set `COOLDOWN_DATE` to the computed rolling window date (`build_date - 4 days`), not a hardcoded value.

**Warning signs:**
- Docker build output shows `CACHED` for the `dnf update` step on rebuilds.
- RPM package versions inside the sandbox match an old build date, not the current cooldown date.
- `rpm -q golang` inside the sandbox shows the same version across multiple rebuilds over weeks.

**Phase to address:** Rebuild script / Dockerfile authoring phase

---

### Pitfall 8: Build-Phase Network vs. Runtime Zero-Egress Confusion

**What goes wrong:**
The Dockerfile requires network access at build time (dnf, go install, npm install, git clone) but the running sandbox must have zero egress. If any runtime startup script, Claude Code hook, or MCP server plugin attempts to fetch something that was only available at build time, it will silently fail or hang inside the zero-egress sandbox.

Common specific failure modes:
- A Claude Code hook script does `npm install` or `go get` at session start to "stay fresh."
- An MCP plugin auto-downloads its own binary or model on first run.
- Claude Code's auto-updater attempts to fetch a new release (this specific case is handled by `DISABLE_NONESSENTIAL_TRAFFIC`, but custom tools may have their own update logic).

**Why it happens:**
Build-time and runtime are conflated, especially when copying in tooling that "installs itself" on first invocation. The claude-engineering-toolkit (cloned at HEAD) may include agents or skills with self-provisioning behavior.

**How to avoid:**
- Audit the claude-engineering-toolkit's entrypoints, hooks, and agent manifests for any network calls that happen at agent load time or first tool invocation.
- Do all installs and binary downloads in the Dockerfile RUN steps, not in entrypoint scripts.
- Run the sandbox once with a temporarily elevated log level and tcpdump/network tracing to confirm zero outbound connections after startup.
- If any plugin must self-update, gate it with an environment variable that defaults to off (`DISABLE_PLUGIN_UPDATES=1`).

**Warning signs:**
- First tool call in a Claude session hangs for 30+ seconds.
- OpenShell proxy logs show blocked connections to npm registry, GitHub, or Go module proxy from inside the running sandbox.
- A tool reports "binary not found" despite the tool being listed in the toolkit.

**Phase to address:** Claude Code and MCP configuration phase

---

### Pitfall 9: ~/claudeshared UID Mismatch Causes Read-Write Mount Failures

**What goes wrong:**
On macOS (Darwin) with rootless Podman or Docker (Rancher Desktop), the sandbox container runs with a remapped UID. Files in `~/claudeshared` on the host are owned by the host user (e.g., UID 501 on macOS). Inside the container, the process may run as root (UID 0) or a different UID depending on the Dockerfile's USER instruction. The UID 0 in a rootless container maps to the host user's UID in the host namespace, but any other container UID maps into the host's subordinate UID range — making those UIDs unable to write host-owned files.

The symptom is: Claude Code can read `~/claudeshared` but cannot write new files or modify existing ones, despite the mount being declared read-write.

**Why it happens:**
macOS uses virtualization layers (Rancher Desktop, Lima) for Podman/Docker. The UID mapping through multiple layers (macOS → VM → container) is nontrivial. OpenShell sandboxes built from a Fedora base image that switches to a non-root user (e.g., `USER 1000`) will have UID 1000 in the container, which maps to a subordinate UID on the host, not the actual macOS user UID 501.

**How to avoid:**
- Keep the sandbox process as the container's root user (UID 0) for the `~/claudeshared` mount. In rootless Podman, container UID 0 maps to the actual host user, preserving read-write access to host-owned files.
- Alternatively, use `--userns=keep-id` (Podman) to map the host UID directly into the container so file ownership is preserved.
- Verify the fix before shipping: create a file inside the sandbox in `~/claudeshared`, then confirm it is visible and owned correctly on the host.
- OpenShell's `sandbox create` may handle this through its own mount flags; check whether OpenShell respects `--userns=keep-id` or an equivalent option.

**Warning signs:**
- `ls -la ~/claudeshared` from inside the sandbox shows files owned by a numeric UID that does not match the container user.
- `touch ~/claudeshared/test.txt` from inside the sandbox fails with `Permission denied`.
- New files created inside the sandbox appear on the host owned by an unexpected UID (e.g., 100501 or similar subordinate mapping).

**Phase to address:** Mount and permissions configuration phase

---

### Pitfall 10: Lockfile Drift — Rebuild Silently Pulls Different Versions Than the Pinned Build

**What goes wrong:**
The rolling cooldown intent is: each rebuild pins to "latest as of 4 days before build date." Without capturing and checking in lockfiles as artifacts, successive rebuilds will produce different resolved dependency sets even for the same cooldown window (because `npm install --before` re-resolves from the registry each time, and new patch/minor versions may have been published within the still-eligible window since the last build).

This means the build is reproducible in spirit (same cooldown discipline) but not byte-for-byte reproducible (different patch versions across rebuilds on the same cooldown date).

**Why it happens:**
`--before` is a ceiling filter, not an exact-version pin. Within the eligible date range, npm still picks the newest satisfying version. If a package publishes a new patch between two rebuilds and that patch is still before the cooldown date, the second rebuild picks it up silently.

**How to avoid:**
- After each successful rebuild, extract the generated `package-lock.json` from the container as a build artifact and store it alongside the Dockerfile.
- For reproducible reruns of the same build, use `npm ci` against the captured lockfile rather than `npm install --before` (which re-resolves).
- The lockfile should be committed to source control or stored in the rebuild script's output directory with a timestamp.
- This is "reproducibility of record" — the current build is always cooldown-fresh, but past builds can be reproduced from their captured lockfiles.

**Warning signs:**
- Two rebuilds on the same day produce different `npm list --depth=0` output.
- No `package-lock.json` artifact is stored outside the container after builds.
- The rebuild script has no step to copy out or verify the lockfile.

**Phase to address:** Rebuild script / supply-chain pinning phase

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Use `--no-cache` on every docker build | Guarantees fresh packages; avoids cache stale pitfall | Slow rebuilds (full dnf update, full npm install from scratch every time) | Always acceptable; prefer the COOLDOWN_DATE ARG approach for speed |
| Skip UID mapping fix, run as root in container | Simpler Dockerfile; no mount permission issues | Security posture: container root has broader blast radius if escaping the sandbox | Acceptable for single-developer, non-shared setup |
| Use `@latest` for govulncheck and document "this was latest at build date" without capturing exact version | Simpler Dockerfile | Non-reproducible; audit trail is vague | Never — capture the resolved version in a manifest |
| Leave `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` unset and rely on zero-egress policy to block update calls | One less env var to manage | Auto-update calls will fail noisily, polluting logs with blocked-connection errors | Never — set the env var; it eliminates noise |
| Skip MCP plugin audit, trust toolkit at HEAD | Faster to ship | Any plugin with runtime network calls will silently break inside zero-egress sandbox | Acceptable only if toolkit plugins are known to not make outbound calls |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| OpenShell inference gateway | Pointing `ANTHROPIC_BASE_URL` at `https://api.anthropic.com` (or omitting it) | Set `ANTHROPIC_BASE_URL=http://inference.local` inside the sandbox; the gateway translates this to the real inference provider |
| OpenShell policy | Empty policy = open egress (permissive default) vs. empty policy = deny all | Verify with OpenShell docs/CLI which default applies; do not assume deny-by-default without testing |
| npm cooldown pinning | Running `npm install --before` against an existing lockfile and expecting idempotent results | Delete lockfile first; `npm install --before <date>` re-resolves; `npm ci` uses lockfile verbatim |
| Docker build cache and dnf | `RUN dnf update -y` gets cached; rebuild installs stale packages | Use `ARG COOLDOWN_DATE` before the dnf step to bust the cache on each rebuild |
| claude-engineering-toolkit MCP plugins | Plugins making outbound HTTP calls get blocked silently by zero-egress policy | Audit all plugin network calls; allowlist required endpoints or disable network-dependent tools |
| ~/claudeshared mount on macOS | UID mismatch between macOS host user and container non-root UID | Run container as UID 0 (rootless: maps to host user) or use `--userns=keep-id` |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Allowlisting `api.anthropic.com` in the sandbox egress policy | Claude can exfiltrate data from `~/claudeshared` by embedding it in API payloads | Policy must contain zero Anthropic endpoint entries; inference routes only through `inference.local` |
| Mounting the full `~/` (home directory) instead of only `~/claudeshared` | Exposes SSH keys, `.aws/`, `.npmrc` tokens, all host configs to autonomous Claude | Mount only `~/claudeshared`; verify the mount target in the OpenShell sandbox create command |
| Running `--dangerously-skip-permissions` without confirming zero-egress | Elevated autonomous Claude with internet access can reach external services | Verify zero-egress policy is active and tested before enabling `--dangerously-skip-permissions` |
| Leaving telemetry enabled in a zero-egress sandbox | Telemetry calls are blocked and produce noise; worst case, telemetry retries cause latency | Set `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` in the sandbox entrypoint |
| Using the claude-engineering-toolkit from the public upstream instead of the operator's fork | Public upstream may change in ways that introduce network calls or security issues | Always clone from `https://github.com/pheckenlWork/claude-engineering-toolkit.git` as specified in PROJECT.md |

---

## "Looks Done But Isn't" Checklist

- [ ] **Zero-egress policy**: Test by running `curl https://api.anthropic.com` from inside the running sandbox — it must fail with a proxy error, not succeed. A sandbox that "builds fine" has not had its egress policy tested until a live egress attempt is blocked.
- [ ] **Inference routing**: Test by running an actual Claude Code session inside the sandbox with a simple prompt. A sandbox where `openshell sandbox create` succeeded has not validated inference until a real model round-trip completes via `inference.local`.
- [ ] **Supply-chain cooldown for govulncheck**: Verify `govulncheck --version` shows a release date on or before the cooldown date (2026-06-09 for a 2026-06-13 build). `@latest` in the Dockerfile does not guarantee this.
- [ ] **npm cooldown**: Verify by inspecting `package-lock.json`'s `resolved` timestamps — no entry should have a registry timestamp after the cooldown date.
- [ ] **~/claudeshared read-write**: Create a file inside the sandbox at `~/claudeshared/canary.txt` and confirm it appears on the host. Do not assume the mount is writable based on the mount flags alone.
- [ ] **dnf update is not cached**: Confirm `rpm -q golang` shows the expected version, and that the build log does not show `CACHED` for the dnf step on a fresh rebuild with a new cooldown date.
- [ ] **MCP plugins functional**: Invoke each claude-engineering-toolkit tool once inside the sandbox and confirm it either succeeds or fails with a clear, expected error (not a network timeout).

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Egress policy silently denying inference traffic | LOW | Elevate log level to INFO; check proxy logs; confirm `openshell inference get` shows configured provider; re-run `openshell inference set` |
| api.anthropic.com was accidentally allowlisted | LOW | Remove the endpoint from the policy; rebuild; re-verify egress blocks |
| Inference gateway not configured (Claude hangs 290s) | LOW | Stop sandbox; run `openshell provider create` and `openshell inference set` on host; recreate sandbox |
| npm lockfile has post-cooldown versions (ETARGET error) | LOW | Delete `package-lock.json`; re-run `npm install --before <date>` |
| govulncheck installed at `@latest` without date pin | MEDIUM | Query index.golang.org for the correct version tag; rebuild with explicit `@v<tag>` |
| dnf update cached, stale packages in image | LOW | Rebuild with `--no-cache` or with a new `COOLDOWN_DATE` ARG value |
| ~/claudeshared read-write failing due to UID mismatch | MEDIUM | Adjust OpenShell sandbox create flags for UID mapping; may require Dockerfile USER change |
| MCP plugin making network calls that are blocked | MEDIUM | Audit plugin source; disable or stub the network-dependent code; or explicitly allowlist the endpoint in policy with documented justification |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Silent egress denial logs | Sandbox baseline / network policy | Run `curl api.anthropic.com` from inside sandbox; check proxy logs at INFO level |
| Allowlisting api.anthropic.com | Sandbox baseline / network policy | Policy audit script asserts no Anthropic endpoints present |
| Inference gateway misconfigured | Sandbox baseline / network policy | `openshell inference get` preflight in rebuild script; interactive Claude session test |
| Claude Code runtime network calls (telemetry, auto-update, MCP) | Claude Code config phase | Set `DISABLE_NONESSENTIAL_TRAFFIC`; audit MCP plugin network calls; run in sandbox with INFO logs |
| npm --before not used for update / lockfile present | Supply-chain pinning / Dockerfile | Dockerfile deletes lockfile before install; lockfile artifact captured after build |
| go install @latest ignoring cooldown | Supply-chain pinning / Dockerfile | Version manifest file; Dockerfile uses explicit version ARG; verify govulncheck --version date |
| Docker cache serving stale dnf update | Rebuild script / Dockerfile | Dockerfile uses ARG COOLDOWN_DATE before dnf step; build log shows no CACHED for dnf |
| Build-phase vs. runtime network confusion | Claude Code config phase | Network trace inside running sandbox; no outbound connections after startup |
| ~/claudeshared UID mismatch | Mount / permissions phase | Create file in sandbox, verify ownership on host |
| Lockfile drift across rebuilds | Rebuild script / supply-chain | Store lockfile artifact after each build; compare lockfiles across rebuilds |

---

## Sources

- [NVIDIA/OpenShell issue #704: egress proxy logs denials at info level, sandbox defaults to WARN](https://github.com/NVIDIA/OpenShell/issues/704)
- [NVIDIA/OpenShell issue #759: Claude Code hangs ~290s between API calls in interactive sandbox sessions](https://github.com/NVIDIA/OpenShell/issues/759)
- [NVIDIA/OpenShell issue #242: inference.local returns 404 when gateway provider not configured](https://github.com/NVIDIA/OpenShell/issues/242)
- [NVIDIA/OpenShell: Privacy router ignores sandbox hostAliases — policy misconfiguration is silent](https://github.com/NVIDIA/OpenShell/issues/879)
- [anthropics/claude-code issue #53899: DISABLE_NONESSENTIAL_TRAFFIC bundles DISABLE_AUTOUPDATER](https://github.com/anthropics/claude-code/issues/53899)
- [anthropics/claude-code issue #59894: CCR v2 network sandbox blocks MCP stdio server outbound calls](https://github.com/anthropics/claude-code/issues/59894)
- [npm docs: npm install --before flag behavior and --min-release-age (npm >= 11.10.0)](https://docs.npmjs.com/cli/v11/commands/npm-install/)
- [npm supply chain security: --before applies to install not update; pnpm preferred for supply chain](https://www.thecandidstartup.org/2026/02/23/securing-npm-supply-chain.html)
- [Go module proxy: proxy.golang.org has no date-based version query; index.golang.org since= is feed-forward only](https://proxy.golang.org/)
- [Go Modules Reference: @latest resolution, no date-based pinning in go install](https://go.dev/ref/mod)
- [Fedora 44: golangci-lint 2.11.3-1.fc44 in standard Fedora repos](https://packages.fedoraproject.org/pkgs/golangci-lint/golangci-lint/)
- [Fedora 44: golang package is Go 1.26 (golang1.26 change set)](https://fedoraproject.org/wiki/Changes/golang1.26)
- [Docker build cache: RUN dnf update cached unless preceding ARG changes](https://depot.dev/blog/ultimate-guide-to-docker-build-cache)
- [Podman rootless UID mapping: --userns=keep-id for host UID preservation on mounts](https://www.redhat.com/en/blog/debug-rootless-podman-mounted-volumes)
- [Claude Code ANTHROPIC_BASE_URL: must point at gateway; bare domain without scheme is invalid](https://fazm.ai/blog/route-claude-api-through-custom-endpoint-anthropic-base-url)
- [OpenShell MCP protocol layer: sandbox cannot inspect request bodies, cannot restrict MCP tool-level calls](https://deconvoluteai.com/blog/nvidia-openshell-mcp-protocol-layer)
- [Documented Claude Code blast-radius incidents: rm -rf from root (Oct 2025), ~ directory accident (Nov 2025)](https://dev.to/trekhleb/run-claude-codes-dangerously-skip-permissions-safely-with-docker-514d)

---
*Pitfalls research for: network-isolated Claude Code sandbox (NVIDIA OpenShell / Fedora 44 / supply-chain cooldown)*
*Researched: 2026-06-13*
