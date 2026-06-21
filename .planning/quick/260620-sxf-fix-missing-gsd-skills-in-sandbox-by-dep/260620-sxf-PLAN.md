---
quick_id: 260620-sxf
slug: fix-missing-gsd-skills-in-sandbox-by-dep
date: 2026-06-20
status: complete
---

# Quick Task 260620-sxf: Fix missing GSD skills in the sandbox

## Problem

Running `./rebuild.sh claude` inside the sandbox launches Claude Code without the
GSD commands/agents/skills — they are missing.

## Root cause

In the `Dockerfile`, `gsd-core --claude --global` (which writes the GSD Claude
integration into `$HOME/.claude/`) ran during `podman build` **as root**, so the
files landed in `/root/.claude/`.

At runtime the OpenShell supervisor runs as root and **drops privileges into the
`sandbox` user** (UID 1000, `HOME=/home/sandbox`). `claude` therefore reads
`/home/sandbox/.claude/` — which never received the GSD integration. The
claude-engineering-toolkit plugins still load because they come in via the
absolute `--plugin-dir /opt/claude-engineering-toolkit` (user-independent), which
is why *only* the GSD skills were missing.

`/home/sandbox/.claude` is the correct live config dir: the in-sandbox OAuth login
writes `~/.claude/.credentials.json` there, and `policy.yaml` already grants
`/home/sandbox` write access (STATE row 851eae4). So the fix is to deploy GSD into
that home, not to change which home `claude` uses.

## Approach (operator-selected: "Run as sandbox user")

1. Move the `sandbox` user/group creation **before** the gsd-core install
   (was the final Dockerfile step).
2. Keep `npm install -g @opengsd/gsd-core` as root (system-wide bins — correct).
3. Run the integration step as the runtime user:
   `su sandbox -s /bin/bash -c "HOME=/home/sandbox PATH=$PATH gsd-core --claude --global"`
   → writes into `/home/sandbox/.claude`, owned by `sandbox`.
4. Add a **fail-closed build guard** (Step 4c) asserting the integration landed in
   `/home/sandbox/.claude` and is owned by `sandbox` — so the regression cannot
   silently return.

## Tasks

1. `Dockerfile` — relocate `sandbox` useradd to Step 3c; split Step 4 into
   `4` (npm -g as root) + `4b` (integration as sandbox); add `4c` build guard;
   replace old Step 8 user-creation block with a pointer note.

## Verify

- `docker/podman build` succeeds; Step 4c does not trip.
- After rebuild: `./rebuild.sh claude` shows GSD commands/skills available.
- `openshell sandbox exec --no-tty -- ls /home/sandbox/.claude` lists `agents/`
  (and/or `commands/`), owned by `sandbox`.
