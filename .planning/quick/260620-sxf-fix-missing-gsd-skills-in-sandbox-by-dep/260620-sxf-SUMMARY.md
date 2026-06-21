---
quick_id: 260620-sxf
slug: fix-missing-gsd-skills-in-sandbox-by-dep
date: 2026-06-20
status: complete
commit: a6e724e
---

# Quick Task 260620-sxf — Summary

## What changed

`Dockerfile`:
- **Step 3c (new):** `sandbox` user/group creation moved here (was the last build
  step) so the user exists before the GSD integration is deployed.
- **Step 4:** now only `npm install -g @opengsd/gsd-core` (system-wide bins, as root).
- **Step 4b (new):** `su sandbox -s /bin/bash -c "HOME=/home/sandbox PATH=$PATH gsd-core --claude --global"`
  — deploys GSD's commands/agents/skills into `/home/sandbox/.claude`, owned by `sandbox`
  (the runtime user / OAuth-credentials home).
- **Step 4c (new):** fail-closed build guard — aborts the build if the integration is
  not present in `/home/sandbox/.claude` owned by `sandbox` (260620-sxf regression tripwire).
- **Step 8:** old user-creation block replaced with a pointer note (creation moved to 3c).

## Why

The GSD skills were missing under `./rebuild.sh claude` because `gsd-core --claude
--global` ran as root → integration landed in `/root/.claude`, but the runtime
`sandbox` user reads `/home/sandbox/.claude`. Engineering-toolkit plugins were
unaffected (loaded via absolute `--plugin-dir`), which localized the symptom to GSD.

## Commit

- `a6e724e` — fix(quick-260620-sxf): deploy GSD integration into the sandbox user home

## Verification status

Not yet rebuilt. The fix is verified at build time by the Step 4c guard (fails the
build if the integration is absent). **Operator action required** to confirm end-to-end:

```bash
./rebuild.sh                 # rebuild image (Step 4c guards the fix)
./rebuild.sh login           # OAuth, if not already authenticated
./rebuild.sh claude          # confirm GSD commands/skills now load
# optional spot check:
openshell sandbox exec --name <sandbox> --no-tty -- ls -la /home/sandbox/.claude
```

## Notes / follow-ups

- `policy.yaml` already grants `/home/sandbox` write access (STATE 851eae4), so no
  policy change was needed.
- If a future gsd-core changes its `~/.claude` layout (neither `agents/` nor
  `commands/`), the Step 4c guard will fail the build — update the guard in lockstep.
