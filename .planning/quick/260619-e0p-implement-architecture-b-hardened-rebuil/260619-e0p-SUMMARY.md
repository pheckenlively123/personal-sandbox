---
task_id: 260619-e0p
title: Implement Architecture B-hardened redesign
date: 2026-06-19
commits:
  - hash: 8f5fcb4
    message: "feat(260619-e0p): implement Architecture B-hardened redesign (api.anthropic.com-only)"
    files: [rebuild.sh, policy.yaml, Dockerfile]
  - hash: 4f99856
    message: "docs(260619-e0p): rewrite README and CLAUDE.md for Architecture B-hardened"
    files: [README.md, CLAUDE.md]
---

# Quick Task 260619-e0p: Architecture B-hardened Redesign — Summary

## One-liner

Rewrote the sandbox from inference.local zero-egress to api.anthropic.com-only TLS passthrough with in-sandbox subscription OAuth login, binary-scoped policy, and inverted NET gates.

## Files Changed

| File | Change |
|------|--------|
| `rebuild.sh` | Full rewrite — verb-first dispatch, portable ensure_podman_ready, inverted NET-04/NET-05, login verb, removed all inference.local/model machinery |
| `policy.yaml` | Added `network_policies.anthropic_api` block (api.anthropic.com:443 passthrough, no protocol, binaries scoped to /usr/bin/claude + /usr/local/bin/claude) |
| `Dockerfile` | Removed `ENV ANTHROPIC_BASE_URL=https://inference.local`; added comment about Architecture B OAuth login |
| `README.md` | Rewritten for Architecture B: verb surface, OAuth login workflow, inverted validation checklist, widening-allowlist note, all inference.local/keychain references removed |
| `CLAUDE.md` | Core Value + Network constraint rewritten; Gateway Inference Brokering replaced; What NOT to Use table updated |

## Key Changes by File

### rebuild.sh

**Removed:**
- `ensure_inference_provider()` — entire function (openshell provider create/update, inference set, --from-existing)
- `check_inference_provider()` — entire function (gateway unreachable / not-configured gate)
- `--model` / `--set-model` flags, `MODEL` default, `SET_MODEL_MODE`
- Model-id allowlist validation guard
- `--set-model` fast-switch block
- `run_inference_round_trip()` — D-06 inference.local round-trip (entire function)
- `ROUND_TRIP_STATUS` variable
- Step 0 (inference provider), Step 7 (round-trip)
- `AUDIT_MODE=true` flag-first dispatch (replaced by verb-first)

**Added:**
- `ensure_podman_ready()` — portable: detects machine-based (macOS) vs native Linux host; `podman machine list` non-empty → inspect+start; else `systemctl --user start podman.socket`; final gate on `podman info`
- Verb-first dispatch: `rebuild` (default) / `status` / `connect` / `login` / `down` / `audit`; backward-compat `--audit` alias
- `assert_anthropic_only_egress()` — **inverted NET-04**: requires api.anthropic.com:443 present; no `protocol` field; binaries match `*/claude`; statsig.anthropic.com absent; sentry.io absent; fatal on any miss
- `run_egress_smoke_test()` — **inverted NET-05**: api.anthropic.com reachable (any HTTP status = pass); statsig/sentry/google.com blocked (connect failure = pass); fatal on any violation
- `login` verb — `ensure_podman_ready` + guidance message + `openshell sandbox connect`
- `down` verb — `openshell sandbox delete` (idempotent, tolerate not-found)
- `status` verb — read-only podman info + sandbox list + policy keys
- `connect` verb — `openshell sandbox connect`
- `audit` verb — `openshell logs` with optional `--since`

### policy.yaml

Added `network_policies` section at end of file:

```yaml
network_policies:
  anthropic_api:
    name: anthropic-api
    endpoints:
      - host: api.anthropic.com
        port: 443
        # NO protocol field -> opaque TCP/TLS passthrough
    binaries:
      - { path: /usr/bin/claude }
      - { path: /usr/local/bin/claude }
```

Static `filesystem_policy` / `landlock` / `process` sections unchanged.

### Dockerfile

Removed: `ENV ANTHROPIC_BASE_URL=https://inference.local`

`CMD` unchanged (still `claude --dangerously-skip-permissions --plugin-dir ...`; no `--bare` added).

## Verification

- `bash -n rebuild.sh` — PASS (syntax clean)
- Static checks per plan §5:
  - No `inference.local` in rebuild.sh / README.md / Dockerfile — confirmed
  - No `ANTHROPIC_BASE_URL` in Dockerfile — confirmed
  - No `--model`, `--set-model`, `ensure_inference_provider`, `check_inference_provider` in rebuild.sh — confirmed
  - No `--bare` in CMD — confirmed
  - Verb dispatch covers rebuild/status/connect/login/down/audit — confirmed
  - `policy.yaml` has `network_policies.anthropic_api` with `host: api.anthropic.com`, `port: 443`, no `protocol:` field, `binaries:` with `*/claude` — confirmed
  - No `statsig.anthropic.com`, no `sentry.io`, no `protocol: rest` Anthropic endpoint in policy.yaml — confirmed
  - No macOS keychain / `--from-existing` references in rebuild.sh / README.md — confirmed
- Live host tests (operator-run, not automated here):
  - `./rebuild.sh` NET-04 PASS + NET-05 PASS
  - `./rebuild.sh login` → OAuth flow completes
  - `command -v claude` / `readlink -f` confirms binary path matches a `binaries:` entry

## Deviations from Plan

None. Implemented exactly as specified in `rebuild-sh-redesign-PLAN.md`.

Minor implementation note: `login` verb uses `openshell sandbox connect` (documented interactive entry) rather than `openshell sandbox exec --tty -- claude` — matches the plan's §3.4 preferred option and is friendlier for the paste-the-code OAuth step.

## Open Items (operator-run)

1. Confirm `command -v claude` / `readlink -f $(command -v claude)` inside the image resolves to `/usr/bin/claude` or `/usr/local/bin/claude` (binary path in `binaries:` must match).
2. Verify Claude Code is not degraded with `statsig.anthropic.com` blocked (open question §6 of plan). If degraded, add `statsig.anthropic.com:443` as a passthrough entry.
3. `systemctl --user` assumption on headless/CI Fedora may need `loginctl enable-linger $USER`; the `podman info` gate catches failure with a hint.
