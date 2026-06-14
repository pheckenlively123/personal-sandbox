FROM fedora:44

# Build ARGs — COOLDOWN_DATE must come FIRST (before any RUN dnf) to act as cache-bust anchor.
# When COOLDOWN_DATE changes, the build cache is invalidated for all subsequent layers (D-07, Pitfall 4).
# All version strings come from ARGs only — no hardcoded versions in this file (Pitfall 1).
ARG COOLDOWN_DATE
ARG GOVULNCHECK_VERSION
ARG GSD_CORE_VERSION
ARG CLAUDE_CODE_VERSION

# Step 1: System packages — cache-busted by COOLDOWN_DATE ARG above.
# golang and golangci-lint installed via RPM per CLAUDE.md (IMG-03, IMG-04).
# nodejs, npm, git, ca-certificates required before npm installs (Pitfall 6).
# jq required by the in-image npm-ls snapshot validation step (`jq empty`, WR-01).
RUN dnf update -y && \
    dnf install -y \
        golang \
        golangci-lint \
        nodejs \
        npm \
        git \
        jq \
        ca-certificates \
    && dnf clean all

# Step 2: Node/npm version assertion for diagnostics (Open Question 3).
RUN node --version && npm --version

# Step 3: govulncheck via go install, pinned to ARG version (PIN-03, IMG-04).
# GOPATH/bin must be on PATH for the binary to be found at runtime.
ENV GOPATH=/root/go
ENV PATH="${PATH}:/root/go/bin"
RUN go install golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}

# Step 4: gsd-core via npm — top-level pin + transitive cooldown via --before (PIN-04, D-02).
# --before must use end-of-day UTC (T23:59:59Z) to include versions published on the cutoff day
# (Pitfall 2: inclusive end-of-day cutoff). COOLDOWN_DATE is YYYY-MM-DD; append T23:59:59Z here.
# gsd-core --claude --global runs bin/install.js which writes Claude hooks to /root/.claude/ (Pitfall 5).
RUN npm install -g @opengsd/gsd-core@${GSD_CORE_VERSION} --before="${COOLDOWN_DATE}T23:59:59Z" && \
    gsd-core --claude --global

# Step 5: Claude Code CLI via npm — top-level pin + transitive cooldown via --before (PIN-05).
# Same end-of-day cutoff to include versions published on the cutoff day itself.
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} --before="${COOLDOWN_DATE}T23:59:59Z"

# Step 6: Clone claude-engineering-toolkit — latest HEAD, no cooldown (IMG-05).
# Operator-maintained fork is trusted (T-01-05 accept). Must clone at build time;
# running sandbox has zero egress so git clone cannot run at sandbox start.
RUN git clone https://github.com/pheckenlWork/claude-engineering-toolkit.git \
    /opt/claude-engineering-toolkit

# Step 7: Generate in-image version snapshots (PIN-06).
# Extracted host-side via `podman create` + `podman cp` by build-and-lock.sh.
# --depth=Infinity captures transitive deps (Pitfall 3).
# Do NOT add PIN-07 gate here — that is a host-side post-build step (D-03, D-04).
#
# WR-01 fix: npm ls exits non-zero whenever the global tree has extraneous, missing,
# invalid, or unmet-peer deps — even when it still emits valid JSON. Guard with || true
# so JSON is always captured. Then validate with `jq empty` before continuing (fail
# closed on malformed JSON). govulncheck snapshot is written after successful validation.
RUN { npm ls -g --json --depth=Infinity > /versions-npm.json || true; } && \
    jq empty /versions-npm.json && \
    govulncheck --version > /versions-govulncheck.txt

# Runtime entry point: Claude Code with dangerously-skip-permissions and plugin dir.
# ANTHROPIC_BASE_URL has no trailing /v1 (CLAUDE.md "What NOT to Use").
ENV ANTHROPIC_BASE_URL=https://inference.local
CMD ["claude", "--dangerously-skip-permissions", "--plugin-dir", "/opt/claude-engineering-toolkit"]
