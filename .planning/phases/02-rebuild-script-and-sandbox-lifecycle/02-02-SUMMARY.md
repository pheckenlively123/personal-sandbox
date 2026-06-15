---
phase: 02-rebuild-script-and-sandbox-lifecycle
plan: 02
subsystem: infra
tags: [bash, podman, openshell, sandbox-lifecycle, bind-mount, landlock, idempotency, policy]

# Dependency graph
requires:
  - phase: 02-rebuild-script-and-sandbox-lifecycle
    provides: build-and-lock.sh --build-date flag and date-tagged image with provenance labels (02-01)
provides:
  - rebuild.sh — single idempotent top-level orchestrator (preflight, resolve+build, :latest tag, tolerate-absent teardown, sandbox create with bind mount + policy, --audit)
  - policy.yaml — full OpenShell default policy reproduced + /claudeshared read_write
  - Dockerfile sandbox user/group + iproute (OpenShell supervisor runtime requirements)
  - README "Rebuilding the sandbox" + "Post-session egress audit" sections
  - A Ready claude-sandbox created from the date-pinned podman ref with a host-owned /claudeshared bind mount
affects: [phase-3-network-isolation, rebuild.sh, policy.yaml]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "OpenShell sandbox images MUST contain a 'sandbox' user+group and iproute (the supervisor de-escalates and builds a netns)"
    - "--policy OVERRIDES the built-in default policy (does NOT merge) — a custom policy must reproduce the full default then add paths"
    - "Idempotent orchestrator: tolerate-absent teardown of sandbox + project-scoped images; never rmi -a / untargeted prune"

key-files:
  created:
    - rebuild.sh
    - policy.yaml
  modified:
    - Dockerfile
    - README.md

key-decisions:
  - "policy.yaml reproduces the live built-in default (read_only/read_write baseline + landlock best_effort + process run-as sandbox) and adds /claudeshared, because --policy overrides rather than merges (research D-09/Pattern 7 assumption corrected)"
  - "Image teardown excludes the current build's tags (:<date> and :latest) so the just-built image survives to the create step"
  - "Dockerfile adds a 'sandbox' user/group (uid/gid 1000) and iproute as a late layer — required by the OpenShell supervisor, kept late to preserve build cache"
  - "rebuild.sh stays the single entry point and delegates resolution/build to build-and-lock.sh (D-05); --audit surfaces openshell logs only (D-07, Phase 3 owns egress assertion)"

patterns-established:
  - "Diagnose OpenShell 'ContainerExited code 1' via the underlying podman container's stderr (podman logs <openshell-sandbox-NAME>), not just `openshell logs` which hides the supervisor's fatal line"
  - "OpenShell sandbox image base requirements: sandbox user+group, iproute; provisioning is policy-sensitive (custom --policy must include the full default filesystem grants)"

requirements-completed: [BLD-01, BLD-02, BLD-04, BLD-05, BLD-06, RUN-03, RUN-04]

# Metrics
duration: ~90min (auto tasks + extended live human-verify debugging of OpenShell provisioning)
completed: 2026-06-15
---

# Phase 02 Plan 02: rebuild.sh End-to-End Lifecycle Summary

**rebuild.sh delivers the full idempotent sandbox spine (preflight → resolve+build → :latest → tolerate-absent teardown → create with bind mount + policy → --audit). The blocking human-verify exposed four real defects (all fixed): image-teardown wiped the fresh image; the image lacked the OpenShell-required `sandbox` user and `iproute`; and policy.yaml replaced rather than extended the default policy. After fixes, `./rebuild.sh` runs twice to a Ready sandbox, the /claudeshared canary lands host-owned, and --audit surfaces logs only.**

## Performance

- **Duration:** ~90 min (3 auto tasks fast; the human-verify checkpoint required deep live debugging of OpenShell sandbox provisioning)
- **Completed:** 2026-06-15
- **Tasks:** 4 (3 auto + 1 human-verify checkpoint)
- **Files created:** 2 (rebuild.sh, policy.yaml); **modified:** 2 (Dockerfile, README.md)

## Accomplishments

- `rebuild.sh` is the single idempotent orchestrator: preflight (`podman openshell python3 jq`), resolve+build via `build-and-lock.sh --build-date`, `:latest` tag, tolerate-absent teardown (sandbox delete + project-scoped image rmi/prune), and `openshell sandbox create` with the `~/claudeshared` bind mount + `--policy` + `--no-tty -- /bin/true`, plus a Ready check.
- `--audit` subcommand surfaces `openshell logs claude-sandbox --source all` and exits before any build/teardown/create (BLD-05 / D-07).
- ISO-8601 timestamped step banners for the phases rebuild.sh controls (BLD-04 / D-06).
- All ROADMAP Phase 2 success criteria verified **live**: idempotent rerun (#1), timestamped banners (#3), host-owned `/claudeshared/canary.txt` owned by the host user (#4 / RUN-03 / RUN-04), and Ready-from-podman-ref (#5 / BLD-06). Criterion #2 was completed in 02-01.

## Task Commits

1. **Task 1: policy.yaml granting /claudeshared read-write** — `e65d62c` (feat)
2. **Task 2: rebuild.sh orchestrator** — `ac59978` (feat)
3. **Task 3: README rebuild.sh + --audit docs** — `643569f` (docs)
4. **Task 4: Human-verify full rebuild spine** — verified live (operator authorized "Proceed"); state commit `c69d9cd`

**Post-checkpoint fix commits (defects surfaced by the live human-verify):**
- `75a410e` (fix) — exclude current build tags from image teardown so create finds the fresh image
- `55e1d39` (fix) — add required `sandbox` user and group to the image (Dockerfile)
- `da7fef2` (fix) — install `iproute` in the image for the supervisor's netns setup (Dockerfile)
- `e991688` (fix) — policy.yaml must reproduce the full default policy, not just /claudeshared

## Files Created/Modified

- `rebuild.sh` (new, executable) — full lifecycle orchestrator described above; strict mode, no eval, T-02-04 (CLAUDESHARED_ABS metachar validation), T-02-05 (exact "sandbox not found" string match), T-02-06 (project-scoped image teardown only).
- `policy.yaml` (new) — full OpenShell default policy (filesystem read_only/read_write baseline, `landlock.compatibility: best_effort`, `process.run_as_user/group: sandbox`) + `/claudeshared` in read_write. No network section (Phase 3).
- `Dockerfile` (modified) — late layers adding `iproute` and creating the `sandbox` user/group (uid/gid 1000, home /home/sandbox), both required by the OpenShell supervisor.
- `README.md` (modified) — "Rebuilding the sandbox" + "Post-session egress audit" sections (BLD-05).

## Deviations from Plan

The plan's auto tasks executed as written; the **human-verify checkpoint surfaced four real defects** that required fixes beyond the original task list. All trace to OpenShell behaviors the phase research had wrong or had not discovered:

1. **Image teardown wiped the just-built image** (`75a410e`). Step 3 removed every `localhost/claude-sandbox:*` tag — including the `:<date>` image and `:latest` built moments earlier — so `create --from` fell back to a registry pull and failed. Fix: skip the current build's two tags.
2. **Image missing the `sandbox` user/group** (`55e1d39`). The OpenShell supervisor (`/opt/openshell/bin/openshell-sandbox`) de-escalates into a user named `sandbox`; without it the container exits 1. The error was only visible via `podman logs` on the underlying container, not `openshell logs`.
3. **Image missing `iproute`** (`da7fef2`). The supervisor needs `/usr/sbin/ip` to build the network namespace for its proxy/isolation mode; without it: "trusted ip helper not found".
4. **policy.yaml replaced the default policy instead of extending it** (`e991688`). `--policy` OVERRIDES the built-in default (the research/Pattern 7 assumption that it merges with an auto-baseline was wrong). The minimal policy stripped the baseline filesystem grants and `landlock: best_effort`, breaking the supervisor's netns setup ("Permission denied (os error 13)"). Fix: reproduce the full default (captured via `openshell policy get <sb> --full -o json`) and add `/claudeshared`.

## Issues Encountered

Extended live debugging of OpenShell sandbox provisioning. Key technique: `openshell logs` only streams the supervisor's structured app log and hides the fatal line; the real cause each time was in the **underlying podman container's stderr** (`podman logs openshell-sandbox-<name>`). Isolation was done with throwaway probe sandboxes (fresh names, toggling image/policy/bind-mount) against a known-good community image (`docker.io/openshell/sandbox-from`) as a control. The benign `/bin/bash: /home/sandbox/.bash_profile: Permission denied` line appears even on the community reference image and does not affect reaching Ready.

## Human-Verify Gate Record

**Task 4 checkpoint (gate="blocking"):** Operator authorized live verification ("Proceed"). After the four fixes, verified live: `./rebuild.sh` exits 0 twice (RUN 1 fresh, RUN 2 tore down the existing Ready sandbox and recreated — idempotency #1); ISO-8601 Step banners present (#3); `openshell sandbox exec ... echo > /claudeshared/canary.txt` produced `~/claudeshared/canary.txt` owned by `patrickheckenlively` (#4 / RUN-03 / RUN-04); sandbox phase `Ready` from `localhost/claude-sandbox:<date>` (#5 / BLD-06); `./rebuild.sh --audit` surfaced logs with zero Step banners and no rebuild (BLD-05).

## User Setup Required

None for this phase. The `~/claudeshared` directory is created by rebuild.sh. Phase 3 will add the inference provider + zero-egress policy.

## Next Phase Readiness

- Phase 3 (network isolation / zero-egress) can build on a working Ready sandbox. It must add `network_policies` to `policy.yaml` (intentionally omitted here per D-07) and wire the inference provider.
- IMPORTANT for Phase 3: `policy.yaml` now carries the full default filesystem policy because `--policy` overrides; any Phase 3 network section must be added to THIS file, not a separate minimal one.
- The Dockerfile's `sandbox` user (uid/gid 1000) differs from the OpenShell community image's high UID (1000660000); virtiofs maps both to the host user on macOS (D-09), so this is fine for RUN-04, but note it if Phase 3 cares about in-image ownership.

## Threat Flags

Threat model mitigations implemented as planned: T-02-04 (CLAUDESHARED_ABS metacharacter validation before JSON interpolation; $HOME expanded, never `~`), T-02-05 (no eval; exact "sandbox not found" match), T-02-06 (teardown scoped to `localhost/claude-sandbox:*` + dangling-only prune), T-02-07 (policy.yaml adds only /claudeshared read_write and no network section), T-02-09 (always full date-pinned `--from` ref, never `--from .`). No new egress surface; zero-egress assertion remains deferred to Phase 3.

---
*Phase: 02-rebuild-script-and-sandbox-lifecycle*
*Completed: 2026-06-15*
