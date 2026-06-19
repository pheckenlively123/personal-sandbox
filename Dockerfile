FROM fedora:44

# Build ARGs — COOLDOWN_DATE must come FIRST (before any RUN dnf) to act as cache-bust anchor.
# When COOLDOWN_DATE changes, the build cache is invalidated for all subsequent layers (D-07, Pitfall 4).
# All version strings come from ARGs only — no hardcoded versions in this file (Pitfall 1).
ARG COOLDOWN_DATE
ARG GOVULNCHECK_VERSION
ARG GSD_CORE_VERSION
ARG CLAUDE_CODE_VERSION
ARG BUILD_DATE

# Provenance labels (D-04): declared via ARG so values travel with the image regardless
# of build entry point. LABELs do not trigger layer execution and do not invalidate the
# COOLDOWN_DATE cache-bust anchor above.
LABEL cooldown.date="${COOLDOWN_DATE}"
LABEL build.date="${BUILD_DATE}"
LABEL govulncheck.version="${GOVULNCHECK_VERSION}"
LABEL gsd.core.version="${GSD_CORE_VERSION}"
LABEL claude.code.version="${CLAUDE_CODE_VERSION}"

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

# Step 4: gsd-core via npm — explicit version pin + --before date (PIN-04, D-02).
# --before="${COOLDOWN_DATE}T23:59:59Z" pins the full transitive tree to versions published
# on or before the cooldown date (widely supported by old and new npm alike).
# GSD_CORE_VERSION is the pre-resolved top-level pin (from resolve-versions.sh).
# Script policy: --ignore-scripts — gsd-core has no install/preinstall/postinstall scripts;
# setup is done by the explicit gsd-core --claude --global call below.
# Source policy: --allow-git/remote/directory=none — registry-only; defaults are permissive (all).
RUN npm install -g @opengsd/gsd-core@${GSD_CORE_VERSION} \
        --before="${COOLDOWN_DATE}T23:59:59Z" \
        --ignore-scripts \
        --allow-git=none --allow-remote=none --allow-directory=none && \
    gsd-core --claude --global

# Step 5: Claude Code CLI via npm — explicit version pin + --before date (PIN-05).
# --before="${COOLDOWN_DATE}T23:59:59Z" pins the full transitive tree to versions published
# on or before the cooldown date (widely supported by old and new npm alike).
# CLAUDE_CODE_VERSION is the pre-resolved top-level pin (from resolve-versions.sh).
# Script policy: --allow-scripts @anthropic-ai/claude-code — claude-code requires its first-party
# postinstall (node install.cjs, confirmed on 2.1.169); this permits only its own script and
# blocks all transitive-dep scripts.
# Source policy: --allow-git/remote/directory=none — registry-only (same rationale as Step 4).
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
        --before="${COOLDOWN_DATE}T23:59:59Z" \
        --allow-scripts @anthropic-ai/claude-code \
        --allow-git=none --allow-remote=none --allow-directory=none

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

# Step 7b: Install iproute (provides /usr/sbin/ip), required by the OpenShell sandbox
# supervisor to create the network namespace for its proxy/isolation mode. Without it the
# container exits 1 with "trusted ip helper not found; checked /usr/sbin/ip ...". Late layer
# (after the heavy installs) so it only rebuilds a thin trailing layer.
RUN dnf install -y iproute && dnf clean all

# Step 8: Create the 'sandbox' user and group required by the OpenShell sandbox supervisor.
# The supervisor (/opt/openshell/bin/openshell-sandbox) de-escalates into a user named 'sandbox';
# if the user or group is absent the container exits immediately with
# "sandbox user 'sandbox' not found in image". UID/GID 1000 is sufficient — the supervisor
# only checks the name, and virtiofs maps container UIDs to the host user on macOS regardless
# of the UID value (D-09). --no-log-init avoids a sparse /var/log/lastlog. No trailing
# USER instruction: the supervisor runs as root and drops privileges itself.
RUN groupadd -g 1000 sandbox \
    && useradd -m -u 1000 -g sandbox -s /bin/bash --no-log-init sandbox

# Runtime entry point: Claude Code with dangerously-skip-permissions and plugin dir.
# Architecture B: ANTHROPIC_BASE_URL is NOT set — Claude Code uses its built-in default
# (api.anthropic.com) and authenticates via in-sandbox subscription OAuth login.
# The operator runs `./rebuild.sh login` to complete the OAuth flow after sandbox creation.
# Do NOT add --bare: that flag skips OAuth and requires ANTHROPIC_API_KEY, which we do not use.
CMD ["claude", "--dangerously-skip-permissions", "--plugin-dir", "/opt/claude-engineering-toolkit"]
