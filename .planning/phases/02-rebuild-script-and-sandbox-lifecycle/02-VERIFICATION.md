---
phase: 02-rebuild-script-and-sandbox-lifecycle
verified: 2026-06-15T23:30:00Z
status: passed
score: 6/6 must-haves verified
overrides_applied: 0
---

# Phase 02: Rebuild Script and Sandbox Lifecycle — Verification Report

**Phase Goal:** A single `rebuild.sh` script runs end-to-end: computes the rolling cooldown, resolves versions, builds the image with podman, tears down any existing sandbox, and creates a new sandbox with the `~/claudeshared` bind mount configured and correct UID alignment.
**Verified:** 2026-06-15T23:30:00Z
**Status:** passed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths (ROADMAP Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Running `./rebuild.sh` twice in a row completes without error on the second run (idempotent teardown-and-recreate, no "sandbox already exists" failure) | VERIFIED | Idempotent teardown implemented: `sandbox not found` tolerated; image teardown with `KEEP_DATE`/`KEEP_LATEST` guards; human-verified live (both runs exit 0, second run tore down and recreated Ready sandbox) |
| 2 | The image produced is tagged with the build date and carries the cooldown date as an image label, visible via `podman inspect` | VERIFIED | `ARG BUILD_DATE` + 5 LABEL-via-ARG lines in Dockerfile (including `cooldown.date` and `build.date`); `--build-arg BUILD_DATE=` in `build-and-lock.sh`; human-verified via `podman inspect` showing both labels on date-tagged image |
| 3 | `rebuild.sh` output shows timestamped log lines for each major phase | VERIFIED | `log_step 1..4` banners covering resolve+build, tag, teardown, create; `ts()` generates ISO-8601 UTC timestamps; D-06 confirmed: dnf/npm/go granularity comes from podman build's own STEP N/M output; human-verified timestamped banners observed in live run |
| 4 | A file created inside the sandbox at `~/claudeshared/canary.txt` appears on the host at the correct path and is owned by the macOS host user (UID alignment) | VERIFIED | `/claudeshared` in `policy.yaml` read_write; `--driver-config-json` bind mount with absolute `$HOME/claudeshared` source; `sandbox` user in Dockerfile (uid/gid 1000) for OpenShell supervisor; virtiofs automatic UID mapping (D-09); human-verified: `openshell sandbox exec ... echo > /claudeshared/canary.txt` produced `~/claudeshared/canary.txt` owned by `patrickheckenlively` |
| 5 | The rebuild script hands the podman-built image reference to `openshell sandbox create --from <image-ref>` (not `--from .`) and the sandbox enters the Ready state | VERIFIED | `--from "localhost/claude-sandbox:${BUILD_DATE}"` in rebuild.sh; no `--from .` present (static check confirmed); Ready check via `openshell sandbox list --names`; human-verified: sandbox phase `Ready` from `localhost/claude-sandbox:<date>` |

**BLD-05 addl. truth (from plan 02-02 must_haves):**

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 6 | `./rebuild.sh --audit` surfaces openshell logs for the sandbox without running the build/teardown/create flow | VERIFIED | `AUDIT_MODE` flag; `audit_sandbox` function calls `openshell logs "${name}" --source all`; audit block fires before preflight/build/teardown/create; human-verified: `--audit` printed logs with zero Step banners and no rebuild |

**Score: 6/6 truths verified**

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `rebuild.sh` | Top-level idempotent orchestrator (min 80 lines) | VERIFIED | 218 lines; executable; `set -euo pipefail`; all phases implemented; no `eval`, no `--from .`, no `--no-keep` |
| `scripts/build-and-lock.sh` | Extended with `--build-date` flag and fifth `--build-arg` | VERIFIED | `--build-date VALUE` and `--build-date=VALUE` forms with empty-arg guard; YYYY-MM-DD allowlist validation; `--build-arg "BUILD_DATE=${BUILD_DATE}"` in podman build invocation |
| `Dockerfile` | `ARG BUILD_DATE` + five LABEL lines; `sandbox` user; `iproute` | VERIFIED | All present; LABELs at lines 14-18, before first RUN at line 24; `COOLDOWN_DATE` remains first ARG; `sandbox` user/group (uid/gid 1000); `iproute` installed |
| `policy.yaml` | Full default policy + `/claudeshared` in read_write, no network section | VERIFIED | `version: 1`; `/claudeshared` in read_write; full default baseline (read_only/read_write paths, `landlock.compatibility: best_effort`, `process.run_as_user/group: sandbox`); no network_policies section |
| `README.md` | "Rebuilding the sandbox" + "Post-session egress audit" sections with `--audit` and Phase 3 scope note | VERIFIED | Both sections present; `--audit` documented; Phase 3 scope note explicit ("Zero-egress enforcement... is delivered in Phase 3"); `--cooldown-days` option documented; bind mount explained |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `scripts/build-and-lock.sh` | `Dockerfile` | `--build-arg BUILD_DATE=<date>` | WIRED | `--build-arg "BUILD_DATE=${BUILD_DATE}"` on podman build; Dockerfile `LABEL build.date="${BUILD_DATE}"` consumes it |
| `Dockerfile LABEL build.date` | `podman inspect .Labels` | podman build ARG→LABEL interpolation | WIRED | 5 LABEL-via-ARG lines positioned after ARG block and before first RUN; human-verified round-trip via `podman inspect` |
| `rebuild.sh` | `scripts/build-and-lock.sh` | subprocess call with `--tag claude-sandbox:<date> --build-date <date>` | WIRED | `bash "${PROJECT_ROOT}/scripts/build-and-lock.sh" --cooldown-days ... --tag ... --build-date ...` at Step 1 |
| `rebuild.sh` | `openshell sandbox create --from` | `localhost/claude-sandbox:<date>` | WIRED | `--from "localhost/claude-sandbox:${BUILD_DATE}"`; no `--from .` fallback |
| `rebuild.sh --driver-config-json` | `policy.yaml` read_write `/claudeshared` | bind mount source + `--policy` | WIRED | `--policy "${PROJECT_ROOT}/policy.yaml"` + `--driver-config-json` with `source="${CLAUDESHARED_ABS}"`, `target="/claudeshared"`, `read_only:false`; policy.yaml adds `/claudeshared` to read_write |
| `rebuild.sh --audit` | `openshell logs` | `audit_sandbox` function | WIRED | `audit_sandbox "${SANDBOX_NAME}"` → `openshell logs "${name}" ${since_arg} --source all` fires before preflight and exits 0 |

---

### Data-Flow Trace (Level 4)

Not applicable — this phase produces shell scripts and configuration files, not components that render dynamic data. All data flows are subprocess invocations and file writes, verified via static analysis and live human-verify above.

---

### Behavioral Spot-Checks

Step 7b: SKIPPED per operator instruction — `./rebuild.sh` triggers multi-minute podman builds and OpenShell sandbox creates. Static checks performed instead; live execution verified by operator during human-verify gate.

Static equivalents performed:

| Behavior | Check | Result | Status |
|----------|-------|--------|--------|
| `bash -n rebuild.sh` clean | syntax check | no errors | PASS |
| `bash -n scripts/build-and-lock.sh` clean | syntax check | no errors | PASS |
| `--build-date not-a-date` rejected before build | allowlist regex `^[0-9]{4}-[0-9]{2}-[0-9]{2}$` in build-and-lock.sh | present at line 71-74 | PASS |
| `--from .` absent from rebuild.sh | negative grep | not found | PASS |
| `--no-keep` absent from rebuild.sh | negative grep | not found | PASS |
| `eval` absent from rebuild.sh | negative grep | not found | PASS |
| 4 log_step banners (Steps 1-4) | grep log_step | Steps 1,2,3,4 found | PASS |
| audit exits before preflight | char position comparison | audit at 3399, preflight at 3810 | PASS |

---

### Probe Execution

No probe scripts exist for this phase (infra/lifecycle phase with no automated test suite per project constraints).

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| BLD-01 | 02-02-PLAN.md | Single script rebuilds sandbox on demand | SATISFIED | `rebuild.sh` is the sole entry point; delegates to `build-and-lock.sh` |
| BLD-02 | 02-02-PLAN.md | Rebuild is idempotent — tears down existing sandbox/image and recreates cleanly | SATISFIED | `sandbox not found` tolerate-absent; `KEEP_DATE`/`KEEP_LATEST` guards; `rmi --force --ignore`; human-verified twice |
| BLD-03 | 02-01-PLAN.md | Image tagged with build date; cooldown date as image label | SATISFIED | 5 LABEL-via-ARG in Dockerfile; human-verified `podman inspect` round-trip |
| BLD-04 | 02-02-PLAN.md | Rebuild script emits timestamped log lines per phase | SATISFIED | `log_step 1..4` with ISO-8601 `ts()` timestamps; D-06: dnf/npm/go output from podman build itself |
| BLD-05 | 02-02-PLAN.md | Rebuild script surfaces documented `openshell logs` egress-audit step | SATISFIED | `--audit` subcommand + README "Post-session egress audit" section with Phase 3 scope note |
| BLD-06 | 02-02-PLAN.md | Image built with podman; `openshell sandbox create --from <image-ref>` | SATISFIED | `podman build` in `build-and-lock.sh`; `--from "localhost/claude-sandbox:${BUILD_DATE}"` in rebuild.sh; human-verified Ready state |
| RUN-03 | 02-02-PLAN.md | `~/claudeshared` bind-mounted read-write | SATISFIED | `--driver-config-json` with type:bind, source:$HOME/claudeshared, target:/claudeshared, read_only:false; `/claudeshared` in policy.yaml read_write |
| RUN-04 | 02-02-PLAN.md | Bind mount UID alignment — files editable from host | SATISFIED | virtiofs automatic UID mapping on macOS (D-09); `sandbox` user in Dockerfile for supervisor; human-verified canary.txt owned by `patrickheckenlively` |

**Note:** REQUIREMENTS.md traceability table still shows BLD-01,02,04,05,06,RUN-03,RUN-04 as "Pending" — this is a tracking artifact. The file was last updated 2026-06-13 (before Phase 2 execution). ROADMAP.md shows both plans with [x] checkmarks. The code implements all requirements. The stale status field in REQUIREMENTS.md is a documentation gap only, not a functional gap.

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `rebuild.sh` | 45-51 | `audit_sandbox` builds `since_arg` as string then expands unquoted | Warning (CR-01 from code review) | No current impact — `since` is always empty (no CLI flag plumbs it through); the only caller passes 1 arg. Latent injection risk if `--since` is ever exposed. Dead code path is harmless today. |
| `scripts/build-and-lock.sh` | 212 | `BUILD_DATE` re-computed by `python3` after being validated and passed in | Info (IN-02 from code review) | Versions.lock `build_date` can disagree with the image tag if a build straddles UTC midnight. Non-blocking; the externally-visible label (`build.date` in the image) uses the value from `rebuild.sh`. |
| `rebuild.sh` | 186 | `CLAUDESHARED_ABS` regex unanchored (no `$` end anchor) | Warning (WR-03 from code review) | Practical risk is negligible for this project — `$HOME` on macOS never contains JSON-hostile characters. The missing end anchor is a defense-in-depth gap; not a current exploitable path. |

No `TBD`, `FIXME`, or `XXX` debt markers found in any phase artifact.

---

### Human Verification Required

None — all success criteria were human-verified live by the operator during the blocking checkpoint gates (Tasks 3 and 4 in Plans 02-01 and 02-02 respectively). Findings documented in 02-01-SUMMARY.md and 02-02-SUMMARY.md.

Key human-verify evidence on record:
1. **SC #2 (BLD-03):** `podman inspect localhost/claude-sandbox:<date>` showed `cooldown.date` and `build.date` labels — operator approved at Task 3 gate in Plan 02-01.
2. **SC #1 (BLD-02 idempotency):** `./rebuild.sh` ran twice, both exits 0; second run tore down existing Ready sandbox and recreated — operator approved at Task 4 gate in Plan 02-02.
3. **SC #3 (BLD-04 banners):** ISO-8601 Step banners present in live run output.
4. **SC #4 (RUN-03/RUN-04):** `openshell sandbox exec ... echo > /claudeshared/canary.txt` produced `~/claudeshared/canary.txt` owned by `patrickheckenlively`.
5. **SC #5 (BLD-06):** Sandbox phase `Ready` from `localhost/claude-sandbox:<date>`.
6. **BLD-05 audit:** `./rebuild.sh --audit` surfaced logs with zero Step banners and no rebuild.

Four post-checkpoint fixes were required and applied before final approval (image-teardown ordering, sandbox user, iproute, full default policy reproduction) — all four are now in the committed codebase with commits 75a410e, 55e1d39, da7fef2, e991688.

---

### Gaps Summary

No gaps. All 6 must-have truths are VERIFIED, all artifacts exist and are substantive, all key links are wired, and all 8 Phase 2 requirements (BLD-01..06, RUN-03, RUN-04) are satisfied by the code in the repository.

The code review (02-REVIEW.md) found 1 Critical + 6 Warnings + 4 Info items. These are advisory improvements — none block the phase goal. CR-01 (unquoted `since_arg` in dead code path) is the most significant; it is a latent injection seam but has no current exploitable path since the `--since` argument is never surfaced. These findings are follow-up work, not phase blockers.

---

_Verified: 2026-06-15T23:30:00Z_
_Verifier: Claude (gsd-verifier)_
