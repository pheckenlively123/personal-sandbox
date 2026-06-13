# Feature Research

**Domain:** Network-isolated AI coding agent container sandbox (single-developer tool)
**Researched:** 2026-06-13
**Confidence:** MEDIUM (architecture and feature categories are well-understood; OpenShell-specific `policy prove` command is LOW confidence — not confirmed in public docs)

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features the operator assumes exist. Missing these = the tool is useless or actively unsafe.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Dockerfile + rebuild script** | Without a scriptable build, the sandbox is not reproducible — every rebuild is manual and diverges | LOW | Single `rebuild.sh`; parameterizes cooldown date and sandbox name |
| **Teardown-and-recreate on rebuild** | A rebuild that leaves a stale sandbox running defeats the purpose — the script must stop/remove old and create new | LOW | `openshell sandbox stop`, remove image, re-create; must be idempotent (no-op if not running) |
| **Image tagging with build date** | Without a tag, it's impossible to tell which image is running; rollback is also impossible | LOW | Tag format: `claude-sandbox:<YYYY-MM-DD>` or `<YYYY-MM-DD>-<cooldown-date>`; latest alias optional |
| **Zero-egress runtime policy** | The core safety guarantee — the sandbox must have no direct internet egress while running | MEDIUM | OpenShell default-deny; empty/no policy = zero egress; inference brokered through gateway |
| **Inference gateway routing** | Without this, Claude has no model to call — zero-egress without gateway means the tool is inert | MEDIUM | Set `ANTHROPIC_BASE_URL` to the OpenShell gateway inference endpoint |
| **`~/claudeshared` bind mount (read-write)** | Without the mount, no repo is visible to Claude — the sandbox is a dead end for development | LOW | `-v ~/claudeshared:/home/user/claudeshared:rw` or OpenShell equivalent; UID alignment required |
| **`--dangerously-skip-permissions` launch flag** | Without this, Claude prompts for every file/shell action — the autonomous workflow breaks | LOW | Set at container entrypoint or launch script; must be present on every `claude` invocation |
| **Go toolchain installed** | The stated use case includes Go development; without it the sandbox is incomplete for the workload | LOW | Via RPM (`golang`) — already determined as install method in PROJECT.md |
| **golangci-lint installed** | Developer workflow feature; expected in any Go dev container | LOW | Via RPM (`golangci-lint`) |
| **govulncheck installed** | Supply-chain auditing of Go deps; standard Go security hygiene | LOW | Via `go install golang.org/x/vuln/cmd/govulncheck@<pinned-version>` |
| **Rolling cooldown window (default 4 days)** | Without a cooldown, the sandbox may pull freshly-published (potentially compromised) packages; a fixed date defeats rolling rebuilds | MEDIUM | Build date − N days (default 4); `COOLDOWN_DAYS` env var; applies to npm and `go install` installs |
| **claude-engineering-toolkit cloned at HEAD** | Claude launched with `--plugin-dir` requires the toolkit to be present; missing = plugin system broken | LOW | `git clone` at build time; no cooldown (operator-maintained fork) |

### Differentiators (Nice Safety/Ergonomics Wins)

Features that aren't assumed but meaningfully improve the tool's safety guarantee or operator experience.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Cooldown date recorded in image label** | Makes it auditable which cooldown date was used for a given image, without inspecting build logs | LOW | `LABEL cooldown_date="YYYY-MM-DD"` in Dockerfile or `openshell sandbox create` metadata |
| **Resolved version manifest (lockfile artifact)** | After each build, emit a file listing exact resolved versions of all pinned packages — npm, govulncheck, Claude Code CLI | MEDIUM | Parse `package-lock.json` + record `go install` resolved version; store as `versions.lock` in image or as build artifact |
| **Pin-held verification step** | A post-build smoke test confirms that the installed version of each pinned tool actually satisfies the cooldown constraint (i.e., the pin held) | MEDIUM | Script reads installed version, compares publish date from registry, fails build if any package was published after cooldown date |
| **Network egress smoke test in rebuild script** | After sandbox creation, the script actively verifies zero egress — attempts a known-blocked outbound connection and asserts it fails | LOW | `openshell exec <name> curl -sf https://example.com --max-time 5` should fail/timeout; script asserts non-zero exit |
| **`openshell logs` egress audit after session** | After a Claude session ends, operator can review what connection attempts were denied — proving zero egress was maintained | LOW | `openshell logs <name>` outputs structured deny entries; surface in rebuild script as a post-session check hint |
| **Parameterized cooldown window via script argument** | Operator can override the default 4-day cooldown (e.g. for emergency security patches or testing) | LOW | `./rebuild.sh --cooldown-days 7`; default baked in, override via arg |
| **Structured build log with timestamps** | Rebuild script emits timestamped log lines for each phase (dnf update, npm install, go install, sandbox create) | LOW | `echo "[$(date -u +%FT%TZ)] Phase: ..."` pattern; aids debugging failed rebuilds |
| **UID alignment for `~/claudeshared` mount** | Prevents the common "files owned by root inside container" problem where Claude can't write to mounted dirs | MEDIUM | Container user UID/GID matched to host user; or entrypoint `chown`; Podman `--userns=keep-id` if applicable |
| **`--plugin-dir` pointed at cloned toolkit** | Makes claude-engineering-toolkit agents/skills available to Claude without manual config each session | LOW | Hardcoded path to clone location in entrypoint; rebuild re-clones at HEAD |
| **`policy prove` network verification (if available)** | If the OpenShell CLI exposes a `policy prove` command, using it gives a formal proof that the declared policy matches runtime enforcement — stronger than a curl smoke test | MEDIUM | LOW confidence: not confirmed in public OpenShell docs (as of 2026-06-13); treat as aspirational; fall back to `openshell logs` + curl test |

### Anti-Features (Things to Deliberately NOT Build)

Features that seem like improvements but defeat the core zero-egress goal or add unjustified complexity for a single-developer tool.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| **Broad egress allowlist (including api.anthropic.com directly)** | "Just whitelist Anthropic's endpoint so Claude can call the API directly" | Defeats the zero-egress guarantee; any exfiltration-capable prompt injection can now reach the internet directly; the gateway brokering is precisely what prevents this | Use OpenShell gateway inference brokering; `ANTHROPIC_BASE_URL` points to gateway |
| **Persistent sandbox (never rebuild)** | "Rebuilding is slow — just keep the sandbox running and update packages in-place" | Destroys reproducibility; in-place package updates drift from the Dockerfile; cooldown pinning becomes meaningless; supply-chain state becomes unknown | Script-driven teardown-and-recreate; accept rebuild cost as the price of reproducibility |
| **GPG/Sigstore signature verification for every package** | "Verify signatures for all npm packages and Go modules" | npm package signing coverage is incomplete; Sigstore adoption is partial; adds significant build complexity with uncertain coverage; Go modules already use go.sum (transparency log) | Rely on npm lockfile + cooldown window for npm; rely on go.sum + GONOSUMCHECK controls for Go; add signature checks only when a specific package supports it |
| **Multi-user or shared-host hardening** | "Other developers on the same machine should be able to use this too" | Out of scope per PROJECT.md; adds UID mapping complexity, shared-state race conditions, and policy management overhead | Single-developer tool; document that assumption explicitly |
| **GPU allocation / CUDA passthrough** | "Enable GPU for faster inference or local model serving" | Not required for this workload; adds driver passthrough complexity and potential host attack surface | Out of scope per PROJECT.md; add only if a future workload proves it necessary |
| **In-sandbox secrets management (vault, etc.)** | "Store API keys and tokens securely inside the sandbox" | OpenShell already injects inference credentials via environment variables without touching the filesystem; adding a secrets manager adds surface area and complexity | Use OpenShell gateway credential injection; no additional secrets manager needed |
| **Automatic sandbox rebuild on file change (watch mode)** | "Automatically rebuild when the Dockerfile changes" | A single-developer tool doesn't benefit enough from watch mode to justify the complexity; silent auto-rebuilds could also silently change the supply-chain state | `./rebuild.sh` on demand; the operator controls when to re-pin |

---

## Feature Dependencies

```
[Rolling cooldown window]
    └──required-by──> [npm install with date pin]
    └──required-by──> [go install with version pin]
    └──required-by──> [Claude Code CLI install with pin]

[npm install with date pin]
    └──produces──> [package-lock.json]
        └──enables──> [Resolved version manifest]
        └──enables──> [Pin-held verification step]

[go install with version pin]
    └──produces──> [go.sum / installed version]
        └──enables──> [Resolved version manifest]
        └──enables──> [Pin-held verification step]

[Dockerfile + rebuild script]
    └──requires──> [Rolling cooldown window]
    └──requires──> [Teardown-and-recreate on rebuild]
    └──produces──> [Image with build-date tag]

[Zero-egress runtime policy]
    └──requires──> [OpenShell sandbox created]
    └──enables──> [Network egress smoke test]
    └──enables──> [openshell logs egress audit]

[Inference gateway routing]
    └──requires──> [Zero-egress runtime policy]  (gateway is the only egress permitted)
    └──required-by──> [--dangerously-skip-permissions launch]  (Claude must be able to call a model)

[~/claudeshared bind mount]
    └──requires──> [UID alignment]  (write access depends on correct ownership)

[claude-engineering-toolkit cloned]
    └──required-by──> [--plugin-dir launch flag]

[--dangerously-skip-permissions launch flag]
    └──requires──> [Zero-egress runtime policy]  (safe only inside an isolated sandbox)
    └──requires──> [Inference gateway routing]   (Claude needs model access to be useful)

[govulncheck installed]
    └──requires──> [Go toolchain installed]
    └──requires──> [go install with version pin]

[Pin-held verification step] ──enhances──> [Rolling cooldown window]
[Cooldown date recorded in image label] ──enhances──> [Image tagging with build date]
[policy prove / network smoke test] ──verifies──> [Zero-egress runtime policy]
```

### Dependency Notes

- **Zero-egress policy requires gateway routing:** You cannot have zero egress and a working Claude without the gateway brokering inference — they must be set up together. The gateway is the only allowed egress.
- **`--dangerously-skip-permissions` requires both isolation layers:** This flag is safe only when both network isolation (zero egress) and workspace isolation (bind mount scoped to `~/claudeshared`) are in place. If either is absent, the elevated permissions create real risk.
- **Pin-held verification depends on version resolution artifacts:** You cannot verify the pin held without first recording what version was resolved. The manifest must be produced before it can be checked.
- **UID alignment is a prerequisite for mount ergonomics:** Without it, Claude writes files owned by root inside the container, which are then read-only or unmodifiable from the host — a common and painful surprise.

---

## MVP Definition

### Launch With (v1)

Minimum viable product — the sandbox must have all of these to be usable and safe.

- [ ] **Dockerfile** — defines the image: Fedora 44 base, dnf update, Go/golangci-lint via RPM, govulncheck via `go install` (pinned), gsd-core + Claude Code CLI via npm (cooldown-pinned), claude-engineering-toolkit cloned
- [ ] **Rebuild script** — idempotent teardown-and-recreate; computes cooldown date as (today − 4 days); accepts `--cooldown-days` override; emits timestamped log lines; tags image with build date
- [ ] **Zero-egress OpenShell policy** — applied at sandbox create time; no egress endpoints other than the inference gateway
- [ ] **Inference gateway routing** — `ANTHROPIC_BASE_URL` set to gateway endpoint in container environment
- [ ] **`~/claudeshared` bind mount** — read-write; UID aligned to host user
- [ ] **Claude launched with `--dangerously-skip-permissions` and `--plugin-dir`** — set in container entrypoint or launch wrapper
- [ ] **Network egress smoke test** — rebuild script asserts `curl https://example.com` fails from inside the new sandbox before handing control to the operator

### Add After Validation (v1.x)

Once v1 is working and the basic workflow is validated:

- [ ] **Resolved version manifest** — after build, emit `versions.lock` capturing exact installed versions of govulncheck, Claude Code CLI, and gsd-core — add when audit trail becomes a felt need
- [ ] **Pin-held verification step** — post-build check that each installed version's publish date is before the cooldown date — add when supply-chain confidence needs to be formally demonstrated
- [ ] **Cooldown date image label** — low effort; add at next rebuild cycle once manifest is in place
- [ ] **`openshell logs` post-session audit hint** — surface as a documented operator step, not automated; add when operator wants session-level egress review

### Future Consideration (v2+)

Defer until a concrete need emerges:

- [ ] **`policy prove` formal verification** — depends on OpenShell exposing this command publicly; currently unconfirmed in docs; revisit when OpenShell docs are updated
- [ ] **Makefile wrapper** — wraps rebuild script with `make sandbox`, `make verify`, `make logs` targets; useful if the operator wants discoverability, but adds no functional value over the shell script for a single developer

---

## Feature Prioritization Matrix

| Feature | Operator Value | Implementation Cost | Priority |
|---------|----------------|---------------------|----------|
| Dockerfile | HIGH | LOW | P1 |
| Teardown-and-recreate rebuild script | HIGH | LOW | P1 |
| Image tagging with build date | HIGH | LOW | P1 |
| Rolling cooldown window | HIGH | MEDIUM | P1 |
| Zero-egress OpenShell policy | HIGH | MEDIUM | P1 |
| Inference gateway routing | HIGH | MEDIUM | P1 |
| `~/claudeshared` bind mount + UID alignment | HIGH | MEDIUM | P1 |
| `--dangerously-skip-permissions` + `--plugin-dir` launch | HIGH | LOW | P1 |
| Network egress smoke test | HIGH | LOW | P1 |
| Go toolchain + golangci-lint + govulncheck installed | HIGH | LOW | P1 |
| Structured build log with timestamps | MEDIUM | LOW | P2 |
| Parameterized cooldown via script arg | MEDIUM | LOW | P2 |
| Resolved version manifest | MEDIUM | MEDIUM | P2 |
| Pin-held verification step | MEDIUM | MEDIUM | P2 |
| Cooldown date recorded in image label | MEDIUM | LOW | P2 |
| `openshell logs` post-session audit | LOW | LOW | P2 |
| `policy prove` formal verification | MEDIUM | MEDIUM | P3 |
| Makefile wrapper | LOW | LOW | P3 |

**Priority key:**
- P1: Required for the sandbox to be safe and functional — ship in v1
- P2: Meaningfully improves auditability or ergonomics — add after v1 validates
- P3: Nice to have, defer until concrete need

---

## Confidence Notes

- **Table stakes features (P1):** HIGH confidence — all are direct requirements from PROJECT.md with clear implementation paths; no ambiguity.
- **Differentiator features (P2):** MEDIUM confidence — patterns are well-established (image labels, lockfile manifests, smoke tests); some OpenShell-specific behaviors depend on CLI version.
- **`policy prove` command:** LOW confidence — referenced in PROJECT.md context but NOT found in OpenShell public GitHub README or tutorial docs as of 2026-06-13. Treat as aspirational; plan around `openshell logs` + curl-based smoke test as the primary verification path.
- **npm cooldown date pinning:** MEDIUM confidence — `--before` filter in npm registry APIs is documented, but has a known bug (ETARGET on `npm audit signatures`) when pinned versions are newer than min-release-age. Work around: install, then verify published-at date post-install rather than relying on registry-side filtering alone.

## Sources

- [NVIDIA OpenShell GitHub](https://github.com/NVIDIA/OpenShell)
- [OpenShell First Network Policy tutorial](https://mintlify.wiki/NVIDIA/OpenShell/tutorials/first-network-policy)
- [OpenShell agent sandbox overview (vietanh.dev, 2026-03)](https://www.vietanh.dev/blog/2026-03-17-nvidia-openshell-agent-sandboxes)
- [Claude Code --dangerously-skip-permissions guide (TrueFoundry)](https://www.truefoundry.com/blog/claude-code-dangerously-skip-permissions)
- [How Anthropic built Claude Code auto mode](https://www.anthropic.com/engineering/claude-code-auto-mode)
- [AI Agent Sandboxing — why Docker is not enough (SoftwareSeni)](https://www.softwareseni.com/ai-agent-sandboxing-explained-why-docker-is-not-enough-and-what-actually-works/)
- [How to sandbox AI agents in 2026 (Northflank)](https://northflank.com/blog/how-to-sandbox-ai-agents)
- [npm Supply Chain Security 2026 (Mondoo)](https://mondoo.com/blog/npm-supply-chain-security-package-manager-defenses-2026)
- [npm --before cooldown ETARGET bug (npm/cli#9277)](https://github.com/npm/cli/issues/9277)
- [How Go Mitigates Supply Chain Attacks (go.dev blog)](https://go.dev/blog/supply-chain)
- [govulncheck tutorial (go.dev)](https://go.dev/doc/tutorial/govulncheck)
- [Reproducible container builds (Red Hat docs)](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/building_running_and_managing_containers/introduction-to-reproducible-container-builds)
- [Practical Security Guidance for Sandboxing Agentic Workflows (NVIDIA blog)](https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk/)
- [Podman bind mount permissions (lists.podman.io)](https://lists.podman.io/archives/list/podman@lists.podman.io/thread/UFPLNVGEL6BIGYAEXQCYQUNWFCCJOZKC/)

---
*Feature research for: network-isolated Claude Code development sandbox (NVIDIA OpenShell / Fedora 44)*
*Researched: 2026-06-13*
