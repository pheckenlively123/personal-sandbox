# Claude Sandbox — Zero Egress Environment

## Container Constraints

This Claude instance runs inside a **zero egress container**. There is no outbound network access. All `curl`, `wget`, `fetch`, HTTP client calls, and DNS lookups will fail or hang.

## Web Access Protocol

When a task requires fetching URLs, querying APIs, downloading packages, or any other outbound network operation, do NOT attempt the request directly. Instead:

1. **Collect all needed requests** for the current task into a single batch.
2. **Generate a bash script** at a path like `./web-requests-YYYYMMDD.sh` (use today's date).
3. **Stop and tell the human** the script is ready for review.

The human will inspect the script, run it outside the sandbox, and paste or copy the results back in.

### Script Format

```bash
#!/usr/bin/env bash
# Web requests for: <brief task description>
# Generated: <date>
# Run this outside the sandbox, then share the output.

set -euo pipefail
OUTDIR="${1:-.}" # optional: pass a directory to store response files

# --- Request 1: <purpose> ---
curl -fsSL "https://example.com/api/endpoint" \
  -H "Accept: application/json" \
  > "$OUTDIR/response-1.json"
echo "✓ response-1.json"

# --- Request 2: <purpose> ---
curl -fsSL "https://example.com/other" \
  > "$OUTDIR/response-2.html"
echo "✓ response-2.html"
```

### Rules

- **Batch everything.** Identify all URLs needed before generating the script — one script per task, not one per request.
- **Name responses descriptively.** Use `response-<slug>.json` / `.html` / `.txt` so the human knows what each file contains.
- **No side effects.** The script must only read/download — no POST, no auth token writes, no state mutations unless the human explicitly approves.
- **Show the script path** prominently so the human can find it easily.
- **Wait.** Do not proceed with the task until the human confirms the responses are available.

## Other Restricted Operations

- **Package installs** (`npm install`, `pip install`, `go get`, etc.) that require network access follow the same protocol: generate an install script for review.
- **Git clone / fetch / push** to remote hosts: generate the git commands in a script for the human to run.
- **DNS lookups** embedded in code (e.g., `net.LookupHost`) will fail at runtime — note this clearly when writing such code.
