# =============================================================================
# Sealpod — Docker Image
# Single-stage build: node:20-bookworm-slim + Claude Code CLI
# Outbound-only HTTPS polling — no inbound ports needed
# =============================================================================

ARG NODE_VERSION=20

FROM node:${NODE_VERSION}-bookworm-slim

ARG CLAUDE_CODE_VERSION=2.1.92
ARG PLAYWRIGHT_CLI_VERSION=0.1.1

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

# Install Bun runtime (required by official Telegram/Discord channel plugins)
RUN apt-get update && apt-get install -y --no-install-recommends unzip \
 && curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash \
 && rm -rf /var/lib/apt/lists/* \
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

# Copy Playwright CLI default config (deployed to /workspace by entrypoint if absent)
COPY playwright-cli.config.json /usr/local/share/sealpod/playwright-cli.config.json

# Copy scripts
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
COPY sealpod-auth.sh /usr/local/bin/sealpod-auth.sh

# Set permissions
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/init-firewall.sh \
             /usr/local/bin/healthcheck.sh \
             /usr/local/bin/sealpod-auth.sh

# Environment
ENV CLAUDE_CONFIG_DIR=/home/node/.claude \
    DEVCONTAINER=true \
    NODE_OPTIONS="--max-old-space-size=4096" \
    PLAYWRIGHT_BROWSERS_PATH=/home/node/.playwright-browsers \
    XDG_CACHE_HOME=/home/node/.cache

WORKDIR /workspace

# Health check: verify auth status (no fallback — auth failure = unhealthy)
HEALTHCHECK --interval=60s --timeout=15s --start-period=90s --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]

# NOTE: Entrypoint runs as root for firewall init, then drops to node via capsh --user.
# capsh drops NET_ADMIN/NET_RAW/SETPCAP from bounding set before switching to node.
# no-new-privileges is set in docker-compose.yml (compatible with gosu/capsh).
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
