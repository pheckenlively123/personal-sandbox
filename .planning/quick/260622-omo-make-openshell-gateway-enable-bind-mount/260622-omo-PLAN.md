---
phase: quick-260622-omo
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - scripts/preflight-gateway-bind-mount.sh
  - rebuild.sh
  - README.md
  - CLAUDE.md
  - AGENTS.md
autonomous: true
requirements: [RUN-05]
must_haves:
  truths:
    - "On a host whose gateway.toml lacks enable_bind_mounts=true under [openshell.drivers.podman], ./rebuild.sh exits 1 BEFORE Step 4 (Create sandbox) with a clear remediation message instead of failing inside podman"
    - "On a host whose gateway.toml HAS enable_bind_mounts=true under [openshell.drivers.podman], the preflight passes and the rebuild proceeds to Step 4 unchanged"
    - "The preflight reads the gateway config only — it never writes, creates, or modifies gateway.toml and never restarts the gateway"
    - "An absent gateway.toml and a present-but-missing-table/key are both handled fail-closed with the full remediation block to stderr"
  artifacts:
    - path: "scripts/preflight-gateway-bind-mount.sh"
      provides: "RUN-05 fail-closed preflight: section-aware TOML check for enable_bind_mounts=true under [openshell.drivers.podman]"
    - path: "rebuild.sh"
      provides: "Invocation of the RUN-05 preflight in the rebuild path, immediately before Step 4 (Create sandbox)"
  key_links:
    - from: "rebuild.sh"
      to: "scripts/preflight-gateway-bind-mount.sh"
      via: "bash \"${PROJECT_ROOT}/scripts/preflight-gateway-bind-mount.sh\" before log_step 4"
      pattern: "preflight-gateway-bind-mount\\.sh"
---

<objective>
Add a fail-closed RUN-05 preflight to the rebuild path: verify the host's
`~/.config/openshell/gateway.toml` enables `enable_bind_mounts = true` under the
`[openshell.drivers.podman]` table BEFORE `openshell sandbox create` runs, so a fresh
host (e.g. Fedora) gets a clear remediation message instead of a cryptic mid-build podman
bind-mount error.

Purpose: The repo currently assumes `enable_bind_mounts = true` is "already set on this host"
(CLAUDE.md line 252). On any other host the assumption is false and `./rebuild.sh` fails deep
in Step 4 with an opaque podman error. This makes the precondition explicit and self-documenting.

Output: A new delegated `scripts/preflight-gateway-bind-mount.sh`, its invocation in
`rebuild.sh` just before Step 4, and doc updates removing the "already set" assumption.

Operator decisions (locked — do NOT revisit):
- Verify + fail closed ONLY. READ the config; never write/create/modify it; never restart the gateway.
- On failure: `exit 1` with remediation to stderr (what to add to gateway.toml + how to restart the
  gateway: Linux `systemctl --user restart openshell`; macOS `brew services restart openshell`).
- Placement: run the check BEFORE the create-sandbox step (Step 4 in rebuild.sh).
</objective>

<execution_context>
@$HOME/.claude/gsd-core/workflows/execute-plan.md
</execution_context>

<context>
@.planning/STATE.md
@./AGENTS.md
@./docs/error-handling-guidelines.md
@./rebuild.sh
</context>

<tasks>

<task type="auto">
  <name>Task 1: Create scripts/preflight-gateway-bind-mount.sh (RUN-05 fail-closed preflight)</name>
  <files>scripts/preflight-gateway-bind-mount.sh</files>
  <action>
Create a new delegated script implementing the RUN-05 bind-mount preflight (per locked decision 1:
verify + fail closed only — never write/create/modify gateway.toml, never restart the gateway).

Preamble (per docs/error-handling-guidelines.md §1, scripts/*.sh form): `#!/usr/bin/env bash`,
`set -euo pipefail`, `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`,
`PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"`. Copy-paste the standard `ts`/`log_info`/`log_error`
helpers from rebuild.sh (the repo deliberately duplicates these to keep scripts self-contained — see
guidelines §2); all diagnostics go to stderr.

Resolve the config path honoring XDG: `CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"`,
`GATEWAY_TOML="${CONFIG_HOME}/openshell/gateway.toml"`. Never hard-code `/Users/...` (per implementation
notes — this Mac checkout must work on Linux). Allow an optional first positional arg to override the
path for testability, defaulting to the computed `GATEWAY_TOML`.

Define a single `remediation()` helper that emits the full remediation block to stderr (used by every
failure path so the message is consistent): instruct the operator to ensure gateway.toml contains
exactly:
  [openshell.drivers.podman]
  enable_bind_mounts = true
and then restart the gateway — Linux: `systemctl --user restart openshell`; macOS:
`brew services restart openshell`. State that rebuild.sh does NOT modify host config by design (decision 1).

File-absent case (fresh host): if `[[ ! -f "${GATEWAY_TOML}" ]]`, log_error that the file is absent at
its path, call remediation(), exit 1 (fail-closed per decision 2 and guidelines §4 "missing inputs are fatal").

Section-aware TOML parse (per implementation notes — a naive `grep enable_bind_mounts` is insufficient:
it could match a value under a different table or a commented line). Implement a careful awk parse
(bash-only codebase — prefer awk over introducing python here even though resolve-versions.sh uses
python3; awk is sufficient and dependency-free). The awk program must:
  - Track the current table by matching lines of the form `[section.name]` (a `[` ... `]` header,
    trimming surrounding whitespace) and recording whether the current section equals
    `openshell.drivers.podman`.
  - STRIP inline and full-line comments: ignore everything from an unquoted `#` to end of line, and
    skip blank/comment-only lines (do not let a commented `# enable_bind_mounts = true` count).
  - Within the `[openshell.drivers.podman]` table only, match a key/value line whose key (trimmed) is
    exactly `enable_bind_mounts` and whose value (trimmed, after `=`) is exactly `true`.
  - Print a sentinel token (e.g. `FOUND`) to stdout only on a genuine match; print nothing otherwise.
Capture the awk result without aborting under set -e using the if-capture form from guidelines §3a
(`if ! result=$(awk ... "${GATEWAY_TOML}"); then ...; fi`) — an awk failure is itself fatal (fail-closed),
not a silent pass.

Decision: branch the diagnostics for clarity (cheap, per implementation notes) — if the file exists but
the `[openshell.drivers.podman]` table is absent, say so; if the table exists but the key is missing/not
`true`, say so; otherwise PASS. At minimum every non-PASS path must call remediation() and exit 1. On
success, `log_info` a RUN-05 PASS line naming the resolved gateway.toml path and exit 0.

Anchor the guard to the RUN-05 ID in a header comment (new ID in the RUN requirement cluster alongside
RUN-03/RUN-04 bind-mount requirements). Make the file executable.

Do NOT place fenced code blocks for the implementation in this action — the directives above name the
exact behavior, helpers, path resolution, and parse rules; implement them in the script.
  </action>
  <verify>
    <automated>cd /Users/patrickheckenlively/git/personal-sandbox && bash -n scripts/preflight-gateway-bind-mount.sh && tmp=$(mktemp -d) && printf '[openshell.drivers.podman]\nenable_bind_mounts = true\n' > "$tmp/good.toml" && bash scripts/preflight-gateway-bind-mount.sh "$tmp/good.toml"; pass=$?; printf '[openshell.drivers.podman]\n# enable_bind_mounts = true\n' > "$tmp/commented.toml" && (bash scripts/preflight-gateway-bind-mount.sh "$tmp/commented.toml"; [ $? -eq 1 ]) && c1=ok; printf '[openshell.gateway]\nenable_bind_mounts = true\n' > "$tmp/wrongtable.toml" && (bash scripts/preflight-gateway-bind-mount.sh "$tmp/wrongtable.toml"; [ $? -eq 1 ]) && c2=ok; (bash scripts/preflight-gateway-bind-mount.sh "$tmp/missing.toml"; [ $? -eq 1 ]) && c3=ok; rm -rf "$tmp"; [ "$pass" -eq 0 ] && [ "$c1" = ok ] && [ "$c2" = ok ] && [ "$c3" = ok ] && echo ALL_GUARDS_OK</automated>
  </verify>
  <done>
`bash -n` parses clean. A good gateway.toml exits 0; a commented-out key, a key under the wrong table
(`[openshell.gateway]`), and an absent file each exit 1 with the remediation block on stderr. The script
never writes/creates/modifies any file. Verify command prints ALL_GUARDS_OK.
  </done>
</task>

<task type="auto">
  <name>Task 2: Wire the RUN-05 preflight into rebuild.sh before Step 4 (Create sandbox)</name>
  <files>rebuild.sh</files>
  <action>
Invoke the new preflight from the rebuild path immediately BEFORE Step 4 (per locked decision 3 — catch
the problem early with a good message instead of letting podman fail cryptically). In rebuild.sh the
create-sandbox logic lives inline (not in a separate script): Step 4 begins at the
`log_step 4 "Create sandbox"` line. Insert the preflight call after Step 3 (image teardown) completes and
before the `log_step 4 "Create sandbox"` banner.

Keep rebuild.sh a thin dispatcher (D-05 — do not fatten it): the call delegates to the script. Add it as
its own banner so the log reads cleanly, e.g. emit `log_step 3.5 "RUN-05 — Preflight: gateway bind-mount enabled"`
(or reuse the existing log_step numbering convention; a fractional/sub-step banner is acceptable since
this sits between existing Steps 3 and 4), then call
`bash "${PROJECT_ROOT}/scripts/preflight-gateway-bind-mount.sh"`. The script exits 1 on failure under
set -e, which aborts rebuild.sh before any `openshell sandbox create` — no extra branching needed (a
non-zero from the delegated script propagates and aborts; this is the desired fail-closed behavior).

Update the "Steps (rebuild verb)" header comment block near the top of rebuild.sh (currently lines ~28-37)
to document the new preflight between the teardown and create steps, and add a `RUN-05` mention so the
step list stays in sync with the code (AGENTS.md convention: requirement IDs are load-bearing; keep the
guard anchored to its ID).
  </action>
  <verify>
    <automated>cd /Users/patrickheckenlively/git/personal-sandbox && bash -n rebuild.sh && grep -q 'preflight-gateway-bind-mount\.sh' rebuild.sh && awk '/preflight-gateway-bind-mount\.sh/{p=NR} /log_step 4 "Create sandbox"/{c=NR} END{exit !(p>0 && c>0 && p<c)}' rebuild.sh && echo WIRED_BEFORE_STEP4</automated>
  </verify>
  <done>
`bash -n rebuild.sh` parses clean. The preflight script is invoked in rebuild.sh, and the invocation line
appears BEFORE the `log_step 4 "Create sandbox"` line (verified by awk line-order check). The header
comment step list mentions the bind-mount preflight / RUN-05. Verify command prints WIRED_BEFORE_STEP4.
  </done>
</task>

<task type="auto">
  <name>Task 3: Update docs — remove the "already set on this host" assumption (README, CLAUDE.md, AGENTS.md)</name>
  <files>README.md, CLAUDE.md, AGENTS.md</files>
  <action>
Bring the docs in sync with the new RUN-05 preflight (per implementation notes — the change warrants a
README operator note and fixing the "already set" assumption in CLAUDE.md).

README.md: In the "What the rebuild does" numbered list (currently steps 1-7 starting ~line 141), add the
gateway bind-mount preflight as a step between the existing teardown (step 4) and create (step 5). Renumber
following steps as needed, OR insert it as a sub-bullet under the create step if renumbering is noisy —
pick the cleaner edit. State plainly: the preflight reads `~/.config/openshell/gateway.toml` and aborts
(fail-closed) unless `enable_bind_mounts = true` is set under `[openshell.drivers.podman]`; it does NOT
modify host config; on failure it prints exactly what to add and how to restart the gateway (Linux:
`systemctl --user restart openshell`; macOS: `brew services restart openshell`). Also add a one-line note to
the "Operator validation checklist" / setup area (heading near line 275) that a fresh host must enable
bind mounts in gateway.toml (the preflight enforces this).

CLAUDE.md: Fix the stale "already set" assumption. Line 252 (`| OpenShell CLI | 0.0.62 | Podman driver
(configured) | enable_bind_mounts = true already set |`) overstates the precondition for non-this-host
checkouts — update its note to reflect that `enable_bind_mounts = true` under `[openshell.drivers.podman]`
is a REQUIRED host precondition that rebuild.sh now verifies fail-closed (RUN-05) before sandbox create
(does not auto-configure). Adjust the surrounding wording only as needed; do not rewrite unrelated rows.

AGENTS.md: In the "Repo structure" tree, add the new `scripts/preflight-gateway-bind-mount.sh` line with a
short comment (e.g. "RUN-05 fail-closed gateway bind-mount preflight"). Optionally add a one-line pointer in
"Common pitfalls / anti-patterns" if it fits naturally; otherwise the repo-structure entry alone is sufficient.

Keep edits minimal and accurate — do not duplicate the five-guideline content; reference IDs (RUN-05) where
a guard is described, per AGENTS.md conventions.
  </action>
  <verify>
    <automated>cd /Users/patrickheckenlively/git/personal-sandbox && grep -q 'enable_bind_mounts' README.md && grep -q 'preflight-gateway-bind-mount\.sh' AGENTS.md && grep -q 'RUN-05' CLAUDE.md && ! grep -q 'already set' CLAUDE.md && echo DOCS_SYNCED</automated>
  </verify>
  <done>
README.md documents the gateway bind-mount preflight (reads gateway.toml, fail-closed, no host
modification, with the restart commands) in the rebuild-steps and setup/checklist area. CLAUDE.md no longer
claims `enable_bind_mounts = true` is "already set" and references RUN-05 as a verified precondition.
AGENTS.md repo-structure tree lists `scripts/preflight-gateway-bind-mount.sh`. Verify command prints DOCS_SYNCED.
  </done>
</task>

</tasks>

<verification>
- `bash -n` parses both `scripts/preflight-gateway-bind-mount.sh` and `rebuild.sh` clean.
- The preflight exits 0 on a valid gateway.toml and exits 1 (with remediation to stderr) on:
  commented-out key, key under the wrong table, and absent file.
- The preflight is invoked in rebuild.sh BEFORE the `log_step 4 "Create sandbox"` line.
- The preflight never writes, creates, or modifies gateway.toml and never restarts any daemon
  (read-only by construction — the script contains no write/restart of the config).
- Docs (README, CLAUDE.md, AGENTS.md) reflect RUN-05 and drop the "already set" assumption.
</verification>

<success_criteria>
- On a host missing `enable_bind_mounts = true` under `[openshell.drivers.podman]`, `./rebuild.sh`
  fails closed with a clear remediation message BEFORE `openshell sandbox create` runs (no cryptic
  mid-build podman error).
- On a correctly-configured host the preflight passes silently-enough (one PASS log line) and the
  rebuild proceeds to Step 4 unchanged.
- The change is host-portable (XDG/`$HOME`-based path; awk parse with no GNU/BSD-only idioms) and
  follows repo conventions (delegated `scripts/*.sh`, thin dispatcher, fail-closed, RUN-05 anchored).
</success_criteria>

<output>
Create `.planning/quick/260622-omo-make-openshell-gateway-enable-bind-mount/260622-omo-SUMMARY.md` when done
</output>
