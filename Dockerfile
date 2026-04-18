# =============================================================================
# Sealpod — Docker Image
# Single-stage build: node:22-bookworm-slim + Claude Code CLI
# Outbound-only HTTPS polling — no inbound ports needed
# =============================================================================

ARG NODE_VERSION=22

FROM node:${NODE_VERSION}-bookworm-slim

ARG CLAUDE_CODE_VERSION=2.1.92
ARG PLAYWRIGHT_CLI_VERSION=0.1.8
ARG BUN_VERSION=1.3.11

# OCI labels
LABEL org.opencontainers.image.title="sealpod" \
      org.opencontainers.image.description="Security-hardened Docker container for Claude Code Remote Control"

# Install system dependencies + GitHub CLI:
# - iptables: outbound firewall
# - git: --spawn worktree mode
# - gosu/libcap2-bin: privilege drop (gosu for user, capsh for capabilities)
# - curl/ca-certificates: HTTPS
# - jq: JSON parsing for WorktreeCreate/WorktreeRemove hooks
# - gh: GitHub CLI (PR, issue, gist operations)
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    iptables \
    git \
    gosu \
    libcap2-bin \
    curl \
    ca-certificates \
    jq \
    gpg \
    unzip \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI and Playwright CLI globally (pinned versions)
RUN PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} @playwright/cli@${PLAYWRIGHT_CLI_VERSION} \
 && npm cache clean --force

# Install Bun runtime (required by official Telegram/Discord channel plugins, pinned version)
# Download from GitHub releases with SHA256 verification (mitigates Shai-Hulud-style supply chain attacks).
# SHASUMS256.txt is fetched from the same release and used to verify the binary.
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
      amd64) BUN_ARCH="x64" ;; \
      arm64) BUN_ARCH="aarch64" ;; \
      *) echo "Unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && BUN_ZIP="bun-linux-${BUN_ARCH}.zip" \
 && curl -fsSL -o "/tmp/${BUN_ZIP}" \
    "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/${BUN_ZIP}" \
 && curl -fsSL -o /tmp/SHASUMS256.txt \
    "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/SHASUMS256.txt" \
 && cd /tmp && grep "${BUN_ZIP}" SHASUMS256.txt | sha256sum -c - \
 && unzip -oq "/tmp/${BUN_ZIP}" -d /tmp/bun-extract \
 && mv "/tmp/bun-extract/bun-linux-${BUN_ARCH}/bun" /usr/local/bin/bun \
 && chmod +x /usr/local/bin/bun \
 && rm -rf "/tmp/${BUN_ZIP}" /tmp/bun-extract /tmp/SHASUMS256.txt \
 && bun --version

# Install Chromium system dependencies (requires root — cannot be done at runtime).
# Browser binary is NOT baked in — installed on-demand to a separate volume.
# Also install PDF/OCR tools for Claude Code's Read tool and menu scraping.
RUN npx playwright install-deps chromium \
 && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    poppler-utils \
    tesseract-ocr \
    tesseract-ocr-eng \
 && rm -rf /var/lib/apt/lists/*

# Create workspace and config directories
RUN mkdir -p /workspace \
    /home/node/.claude \
    /home/node/.config/gh \
    /home/node/.config \
    /home/node/.local \
    /home/node/.cache \
    /home/node/.npm \
    /tmp/claude-sessions \
 && chown -R node:node /workspace /home/node /tmp/claude-sessions

# Copy default configs (deployed by entrypoint at runtime)
COPY playwright-cli.config.json /usr/local/share/sealpod/playwright-cli.config.json
COPY permission-guardrails.json /usr/local/share/sealpod/permission-guardrails.json

# Copy scripts
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
COPY sealpod-auth.sh /usr/local/bin/sealpod-auth.sh
COPY sealpod-refresh.sh /usr/local/bin/sealpod-refresh.sh
COPY sealpod-token-loop.sh /usr/local/bin/sealpod-token-loop.sh
COPY sealpod-browser-lock.sh /usr/local/bin/sealpod-browser-lock.sh

# Set permissions
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/init-firewall.sh \
             /usr/local/bin/healthcheck.sh \
             /usr/local/bin/sealpod-auth.sh \
             /usr/local/bin/sealpod-refresh.sh \
             /usr/local/bin/sealpod-token-loop.sh \
             /usr/local/bin/sealpod-browser-lock.sh

# Browser concurrency lock: replace playwright-cli with flock wrapper.
# Real binary moved to playwright-cli-unwrapped; wrapper enforces single instance.
RUN REAL_BIN=$(which playwright-cli) \
 && mv "$REAL_BIN" "${REAL_BIN}-unwrapped" \
 && ln -s /usr/local/bin/sealpod-browser-lock.sh "$REAL_BIN"

# Environment
ENV CLAUDE_CONFIG_DIR=/home/node/.claude \
    DEVCONTAINER=true \
    NODE_OPTIONS="--max-old-space-size=4096" \
    PLAYWRIGHT_BROWSERS_PATH=/workspace/.playwright-browsers \
    XDG_CACHE_HOME=/home/node/.cache

WORKDIR /workspace

# Health check: verify auth status (no fallback — auth failure = unhealthy)
HEALTHCHECK --interval=60s --timeout=15s --start-period=90s --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]

# NOTE: Entrypoint runs as root for firewall init, then drops to node via capsh --user.
# capsh drops NET_ADMIN/NET_RAW/SETPCAP from bounding set before switching to node.
# no-new-privileges is set in docker-compose.yml (compatible with gosu/capsh).
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
