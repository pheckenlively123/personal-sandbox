---
task_id: 260619-fbi
title: Add claude.ai + platform.claude.com to egress allowlist; redesign NET-05 deny posture
date: 2026-06-19
commits:
  - hash: f94946c
    message: "feat: policy.yaml + Dockerfile + rebuild.sh — 3-host allowlist, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC, NET-04/NET-05 redesign"
  - hash: a6c8e83
    message: "docs: README.md + CLAUDE.md — update allowlist descriptions from api.anthropic.com-only to 3-host Claude egress"
files_changed:
  - policy.yaml
  - Dockerfile
  - rebuild.sh
  - README.md
  - CLAUDE.md
---

# Quick Task 260619-fbi: Add Claude Auth Hosts to Egress Allowlist

## One-liner

Added `claude.ai:443` and `platform.claude.com:443` to the TLS-passthrough egress allowlist alongside `api.anthropic.com:443`; added `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` to suppress telemetry; redesigned NET-05 to assert deny posture only (curl is not the claude binary).

## What Was Done

### policy.yaml

- Renamed policy key `anthropic_api` → `claude_egress` and policy name `anthropic-api` → `claude-egress` for accuracy.
- Added two new endpoint entries under `claude_egress`: `platform.claude.com:443` and `claude.ai:443`, both with no `protocol` field (opaque TLS passthrough, same shape as `api.anthropic.com`).
- Both new entries share the same `binaries:` scope (`/usr/bin/claude`, `/usr/local/bin/claude`) as the existing entry (they are all under the same policy key).
- Updated comments to name all three hosts with their roles: inference, Console auth, claude.ai auth.

### Dockerfile

- Added `ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` near the GOPATH/PATH ENV block.
- Comment explains this disables auto-updater, telemetry (statsig), Sentry error-reporting, and feedback — keeping those hosts never contacted even though they are absent from the allowlist.

### rebuild.sh

- Renamed `assert_anthropic_only_egress()` → `assert_claude_egress_allowlist()` and updated its single call site.
- Extended NET-04: loops over all three required hosts, checks each is present at :443 with no `protocol` field; binary-scope check still uses `api.anthropic.com` as the representative policy entry (all three hosts are in the same policy block).
- Redesigned NET-05: removed the "api.anthropic.com must be REACHABLE via curl" assertion (was always failing under binary-scoping — curl is not the claude binary so it cannot reach any allowlisted host). NET-05 now asserts deny posture only: `statsig.anthropic.com`, `sentry.io`, and `www.google.com` must all be blocked. Added log note that claude-host reachability is validated by `./rebuild.sh login`.
- Updated header comment, step labels, and final summary log lines to reflect three-host allowlist and redesigned NET-05.

### README.md + CLAUDE.md

- Updated Architecture B section header and description to list all three hosts (table with host/port/purpose).
- Added explanation of `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` and its effect on statsig/sentry/downloads hosts.
- Clarified NET-05 asserts deny posture; `./rebuild.sh login` validates reachability.
- Updated Constraints Network line, Core Value paragraph, Network Policy section, What NOT to Use row, rebuild step 6/7 descriptions, audit log guidance, and validation checklist.

## Why

`./rebuild.sh login` (live test) proved Claude's subscription OAuth flow contacts `platform.claude.com` and `claude.ai`, not only `api.anthropic.com`. Login was blocked because those hosts were absent from the network allowlist. Additionally, the NET-05 "api.anthropic.com must be REACHABLE via curl" assertion was always failing under binary-scoping because curl is not the claude binary and cannot reach any allowlisted host.

## Deviations

None — executed exactly as specified in the task brief.

## Post-Change Verification

- `bash -n rebuild.sh` passes (syntax OK).
- Policy key rename is consistent throughout (policy.yaml, rebuild.sh comments, README.md, CLAUDE.md).
- NET-04 still requires statsig.anthropic.com and sentry.io ABSENT.
- NET-05 still fatal if any non-allowlisted target is reachable.
- Live functional verification (`./rebuild.sh login` success) requires operator to run — flagged as operator-run per task brief.

## Self-Check

- [x] policy.yaml present and updated: `/Users/patrickheckenlively/git/personal-sandbox/policy.yaml`
- [x] Dockerfile present and updated: `/Users/patrickheckenlively/git/personal-sandbox/Dockerfile`
- [x] rebuild.sh present and updated: `/Users/patrickheckenlively/git/personal-sandbox/rebuild.sh`
- [x] README.md present and updated: `/Users/patrickheckenlively/git/personal-sandbox/README.md`
- [x] CLAUDE.md present and updated: `/Users/patrickheckenlively/git/personal-sandbox/CLAUDE.md`
- [x] Code commit f94946c exists
- [x] Docs commit a6c8e83 exists
- [x] bash -n rebuild.sh passes
