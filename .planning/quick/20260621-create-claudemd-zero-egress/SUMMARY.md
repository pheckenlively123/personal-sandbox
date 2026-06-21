---
slug: create-claudemd-zero-egress
date: 2026-06-21
status: complete
---

# Summary: Create CLAUDE.md for zero-egress container

## What was done

Created `/claudeshared/CLAUDE.md` (was absent). The file instructs Claude that it runs in a zero-egress container and defines a web-request batching protocol:

- When outbound network access is needed, generate a dated bash script (`web-requests-YYYYMMDD.sh`) that batches all required `curl`/download commands.
- Stop and hand off the script to the human for inspection and execution outside the sandbox.
- Covers HTTP fetches, package installs, git remote operations, and DNS-dependent code.

## Outcome

`/claudeshared/CLAUDE.md` written and ready. Future Claude sessions starting from `/claudeshared` will pick this up automatically.
