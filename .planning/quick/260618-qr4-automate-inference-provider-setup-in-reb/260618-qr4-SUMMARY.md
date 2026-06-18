---
phase: quick-260618-qr4
plan: "01"
subsystem: rebuild-orchestration
tags: [inference, provider, gateway, model-switch, zero-egress]
dependency_graph:
  requires: [NET-03, D-04, D-07]
  provides: [automated-inference-setup, model-flag, set-model-flag]
  affects: [rebuild.sh, README.md]
tech_stack:
  added: []
  patterns: [create-or-update idempotency, allowlist validation, fail-closed errors, fast-exit mode]
key_files:
  created: []
  modified:
    - rebuild.sh
    - README.md
decisions:
  - "Model-id validation runs against ^claude-[A-Za-z0-9._-]+$ before MODEL reaches any openshell command (injection guard mirroring T-02-01 BUILD_DATE pattern)"
  - "ensure_inference_provider tolerates AlreadyExists on provider create so --set-model can re-run safely"
  - "openshell provider refresh has no refresh-now verb; use provider update --from-existing to re-sync OAuth token"
  - "--set-model runs ensure+check then exits 0, skipping all image build/teardown/create/NET gates"
metrics:
  duration: "~10 min"
  completed: "2026-06-18"
  tasks: 2
  files: 2
---

# Quick Task 260618-qr4: Automate Inference Provider Setup in rebuild.sh — Summary

**One-liner:** ensure_inference_provider idempotently creates-or-updates the claude-code OAuth provider and sets the gateway model at Step 0; --set-model fast-switches without a full rebuild.

---

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Add --model/--set-model flags, model-id validation, ensure_inference_provider, mode wiring | 50677f2 | rebuild.sh |
| 2 | Update README.md to document automated provider setup, --model, and --set-model | 4b4337d | README.md |

---

## What Was Built

### rebuild.sh changes

**New function `ensure_inference_provider`** (defined above `check_inference_provider`):
- Step 1: Podman autostart — checks `podman machine inspect --format '{{.State}}'` for "running"; starts machine and re-verifies if not running; exits 1 on failure.
- Step 2: Provider create-or-update — `openshell provider get claude-code` to detect presence; absent → `openshell provider create --name claude-code --type claude-code --from-existing` (tolerates AlreadyExists); present → `openshell provider update claude-code --from-existing` (re-syncs OAuth token); actionable error if --from-existing fails (host Claude login missing).
- Step 3: `openshell inference set --provider claude-code --model "${MODEL}"`.

**New defaults:**
- `MODEL="claude-opus-4-8"`
- `SET_MODEL_MODE=false`

**New arg cases** (two-form: space and =):
- `--model` / `--model=*`: sets MODEL
- `--set-model` / `--set-model=*`: sets MODEL and SET_MODEL_MODE=true

**Model-id allowlist validation** after arg loop:
- Pattern: `^claude-[A-Za-z0-9._-]+$`
- Mirrors scripts/build-and-lock.sh:69-73 BUILD_DATE pattern
- Applies to both --model and --set-model (both write MODEL)
- log_error + exit 1 on mismatch

**Mode wiring:**
- Full rebuild: `ensure_inference_provider` → `check_inference_provider` → Step 1+
- `--set-model`: `ensure_inference_provider` → `check_inference_provider` → log "start a new Claude session" → exit 0

### README.md changes

- Options block: added `--model <id>` to rebuild usage line; added `--set-model <id>` fast-switch line with description; documented single-model gateway behavior and "new session to switch" note.
- Step 0 in "What the rebuild does": rewritten from assert to ensure (create-or-update, idempotent, podman autostart, only host Claude login needed).
- "One-time inference provider setup" section: retitled to "Inference provider setup (automated by rebuild.sh)"; operator action reduced to host Claude login; raw commands preserved as "what rebuild.sh runs under the hood"; "System inference: Not configured is expected" note preserved.

---

## Deviations from Plan

None — plan executed exactly as written.

---

## Validation Status

**Automated checks passed:**
- `bash -n rebuild.sh` — syntax OK
- `grep ensure_inference_provider rebuild.sh` — function defined and called
- `grep 'claude-opus-4-8' rebuild.sh` — default model present
- `grep SET_MODEL_MODE rebuild.sh` — flag present
- `grep 'inference set --provider claude-code --model' rebuild.sh` — command present
- `grep '\^claude-\[A-Za-z0-9' rebuild.sh` — allowlist regex present
- `grep -- '--set-model' README.md` — documented
- `grep 'claude-opus-4-8' README.md` — default model documented

**Operator-run validation required (live host):**
- `./rebuild.sh` — full rebuild with ensure_inference_provider at Step 0
- `./rebuild.sh --set-model claude-sonnet-4-5` — fast-switch mode exits 0 with "start a new Claude session" message
- `./rebuild.sh --model invalid-id!` — exits 1 with allowlist error
- The live openshell/podman provider/inference flow requires host Claude login + podman machine + gateway — cannot be exercised by Claude.

---

## Self-Check

- rebuild.sh modified: `git log --oneline | grep 50677f2` — FOUND
- README.md modified: `git log --oneline | grep 4b4337d` — FOUND
- `bash -n rebuild.sh` — PASSED

## Self-Check: PASSED
