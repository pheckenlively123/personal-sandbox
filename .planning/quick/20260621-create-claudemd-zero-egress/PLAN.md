---
slug: create-claudemd-zero-egress
date: 2026-06-21
status: in-progress
---

# Create CLAUDE.md for zero-egress container

Create /claudeshared/CLAUDE.md (only if absent) instructing Claude it runs in a zero-egress container. When web access is needed, generate a batched bash script the human can inspect and execute outside the sandbox.

## Tasks

- [ ] Confirm CLAUDE.md absent from /claudeshared
- [ ] Write CLAUDE.md with zero-egress instructions and web-request batching protocol
- [ ] Write SUMMARY.md
