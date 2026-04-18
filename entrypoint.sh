#!/bin/bash
set -euo pipefail

# =============================================================================
# Sealpod — Container Entrypoint
# Runs as root. Phase 1: firewall (as root). Phase 2: trust (as node via gosu). Phase 3: exec with cap drop.
# Firewall applies in ALL modes including passthrough.
# =============================================================================

echo "[entrypoint] Starting Sealpod container..."

# --- Fix tmpfs and volume ownership (Docker creates them as root) ---
# Credential volume needs recursive chown (host-user-owned files inside bind mount).
# Tmpfs dirs are empty at start — only need top-level ownership fix.
chown -R node:node /home/node/.claude 2>/dev/null || true
chown node:node /home/node/.cache /home/node/.npm /home/node/.config \
  /home/node/.local 2>/dev/null || true
chown -R node:node /workspace/.playwright-browsers 2>/dev/null || true

# --- Phase 1: Firewall Setup (runs as root — requires NET_ADMIN) ---
# Firewall applies in ALL modes including passthrough.
# Initialized FIRST so Phase 0 node process has no unrestricted network access.
echo "[entrypoint] Initializing outbound firewall..."
if /usr/local/bin/init-firewall.sh; then
  echo "[entrypoint] Firewall initialized successfully."
else
  echo "[entrypoint] ERROR: Firewall initialization failed. Exiting." >&2
  exit 1
fi

# --- Phase 0: Accept workspace trust + configure mktemp session hooks ---
echo "[entrypoint] Setting workspace trust and session hooks..."
gosu node node -e '
const fs = require("fs");
const configDir = process.env.CLAUDE_CONFIG_DIR;
const claudeJson = configDir + "/.claude.json";
const settingsJson = configDir + "/settings.json";

try {
  // Set workspace trust
  const d = JSON.parse(fs.readFileSync(claudeJson, "utf8"));
  d.projects = d.projects || {};
  d.projects["/workspace"] = d.projects["/workspace"] || {};
  d.projects["/workspace"].hasTrustDialogAccepted = true;
  fs.writeFileSync(claudeJson, JSON.stringify(d));

  // Configure WorktreeCreate/WorktreeRemove hooks for mktemp session isolation.
  // This enables --spawn worktree WITHOUT a git repo — each session gets its own temp dir.
  let settings = {};
  try { settings = JSON.parse(fs.readFileSync(settingsJson, "utf8")); } catch(e) {}
  settings.hooks = settings.hooks || {};
  settings.hooks.WorktreeCreate = [{
    hooks: [{
      type: "command",
      command: "bash -c \"NAME=$(jq -r .name); DIR=$(mktemp -d /tmp/claude-session-XXXXXX); echo \\\"[hook] Created session: $DIR ($NAME)\\\" >&2; echo \\\"$DIR\\\"\""
    }]
  }];
  settings.hooks.WorktreeRemove = [{
    hooks: [{
      type: "command",
      command: "bash -c \"DIR=$(jq -r .worktree_path); DIR=$(realpath -m \\\"$DIR\\\"); [[ \\\"$DIR\\\" == /tmp/claude-session-* ]] || { echo \\\"[hook] ERROR: invalid path: $DIR\\\" >&2; exit 1; }; echo \\\"[hook] Removing session: $DIR\\\" >&2; rm -rf \\\"$DIR\\\"\""
    }]
  }];
  // Configure plugin marketplace for deep-research skill (merge, preserve user customizations).
  settings.extraKnownMarketplaces = settings.extraKnownMarketplaces || {};
  if (!settings.extraKnownMarketplaces["claude-skills"]) {
    settings.extraKnownMarketplaces["claude-skills"] = {
      source: { source: "github", repo: "yachi/claude-skills" }
    };
  }
  settings.enabledPlugins = settings.enabledPlugins || {};
  if (settings.enabledPlugins["deep-research@claude-skills"] === undefined) {
    settings.enabledPlugins["deep-research@claude-skills"] = true;
  }

  // Configure claude-plugins-official marketplace (Telegram/Discord channel plugins).
  if (!settings.extraKnownMarketplaces["claude-plugins-official"]) {
    settings.extraKnownMarketplaces["claude-plugins-official"] = {
      source: { source: "github", repo: "anthropics/claude-plugins-official" }
    };
  }
  // Enable Telegram plugin when bot token is provided.
  if (process.env.TELEGRAM_BOT_TOKEN) {
    if (settings.enabledPlugins["telegram@claude-plugins-official"] === undefined) {
      settings.enabledPlugins["telegram@claude-plugins-official"] = true;
    }
  }

  // --- Permission guardrails for non-bypass modes ---
  // When SEALPOD_PERMISSION_MODE is not bypassPermissions, inject curated deny/allow rules
  // from permission-guardrails.json. Deny rules block dangerous patterns (inline code exec,
  // privilege escalation, supply chain). Allow rules pre-approve safe container operations.
  // In bypassPermissions mode (default), the permission layer is skipped entirely — OS-level
  // controls (firewall, seccomp, read-only rootfs, cap drops) are the security boundary.
  // Some deny patterns overlap with seccomp/cap drops — kept for defense-in-depth.
  const permMode = (process.env.SEALPOD_PERMISSION_MODE != null && process.env.SEALPOD_PERMISSION_MODE !== "")
    ? process.env.SEALPOD_PERMISSION_MODE
    : "bypassPermissions";
  if (permMode !== "bypassPermissions") {
    try {
      const guardrails = JSON.parse(
        fs.readFileSync("/usr/local/share/sealpod/permission-guardrails.json", "utf8")
      );
      settings.permissions = settings.permissions || {};
      // Merge: base guardrails + any user-added rules (deduplicated)
      const baseDeny = guardrails.deny || [];
      const baseAllow = guardrails.allow || [];
      const userDeny = settings.permissions.deny || [];
      const userAllow = settings.permissions.allow || [];
      settings.permissions.deny = [...new Set([...baseDeny, ...userDeny])];
      settings.permissions.allow = [...new Set([...baseAllow, ...userAllow])];
      console.log("[entrypoint] Permission guardrails injected (mode: " + permMode + ", deny: " + settings.permissions.deny.length + ", allow: " + settings.permissions.allow.length + ").");
    } catch(ge) {
      console.error("[entrypoint] WARNING: Failed to load permission guardrails:", ge.message);
    }
  }

  fs.writeFileSync(settingsJson, JSON.stringify(settings, null, 2));
  console.log("[entrypoint] Workspace trust + mktemp hooks + plugin marketplace configured.");
} catch(e) {
  console.error("[entrypoint] WARNING: Setup error:", e.message);
}
'

# --- Telegram channel setup (when TELEGRAM_BOT_TOKEN is set) ---
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  export TELEGRAM_STATE_DIR="${CLAUDE_CONFIG_DIR}/channels/telegram"
  gosu node mkdir -p "$TELEGRAM_STATE_DIR"

  # Write bot token to channel config (plugin reads from here).
  # gosu preserves env, so exported vars are available to the child shell.
  # File written 0600 to restrict token visibility.
  gosu node sh -c 'printf "TELEGRAM_BOT_TOKEN=%s\n" "$TELEGRAM_BOT_TOKEN" > "$TELEGRAM_STATE_DIR/.env" && chmod 600 "$TELEGRAM_STATE_DIR/.env"'

  # Pre-seed access.json to skip interactive pairing flow (headless container).
  # Validate TELEGRAM_USER_ID is numeric to prevent broken allowlists.
  if [ -n "${TELEGRAM_USER_ID:-}" ] && [ ! -f "$TELEGRAM_STATE_DIR/access.json" ]; then
    if ! echo "${TELEGRAM_USER_ID}" | grep -qE '^[0-9]+$'; then
      echo "[entrypoint] ERROR: TELEGRAM_USER_ID must be numeric (got: ${TELEGRAM_USER_ID})" >&2
      exit 1
    fi
    gosu node node -e '
      const fs = require("fs");
      const dir = process.env.TELEGRAM_STATE_DIR;
      const uid = process.env.TELEGRAM_USER_ID;
      const access = { dmPolicy: "allowlist", allowFrom: [uid], groups: {}, pending: {} };
      const tmp = dir + "/access.json.tmp";
      fs.writeFileSync(tmp, JSON.stringify(access, null, 2), { mode: 0o600 });
      fs.renameSync(tmp, dir + "/access.json");
      console.log("[entrypoint] Telegram access.json pre-seeded for user " + uid);
    '
  elif [ -f "$TELEGRAM_STATE_DIR/access.json" ]; then
    echo "[entrypoint] Telegram access.json already exists (preserving)."
  else
    echo "[entrypoint] WARNING: TELEGRAM_USER_ID not set — interactive pairing required." >&2
  fi
  echo "[entrypoint] Telegram channel configured."
fi

# --- Playwright browser automation (controlled via SEALPOD_BROWSER_ENABLED) ---
if [ "${SEALPOD_BROWSER_ENABLED:-true}" = "true" ]; then
  # Install microsoft/playwright-cli skill (not a marketplace — standalone skill repo)
  PLAYWRIGHT_SKILL_DIR="${CLAUDE_CONFIG_DIR}/skills/playwright-cli"
  if [ ! -d "$PLAYWRIGHT_SKILL_DIR" ]; then
    echo "[entrypoint] Installing playwright-cli skill..."
    if gosu node git clone --depth 1 --filter=blob:none --sparse \
      https://github.com/microsoft/playwright-cli.git /tmp/playwright-cli 2>/dev/null; then
      (cd /tmp/playwright-cli && gosu node git sparse-checkout set skills/playwright-cli 2>/dev/null)
      gosu node mkdir -p "${CLAUDE_CONFIG_DIR}/skills"
      gosu node cp -r /tmp/playwright-cli/skills/playwright-cli "$PLAYWRIGHT_SKILL_DIR"
      rm -rf /tmp/playwright-cli
      echo "[entrypoint] playwright-cli skill installed."
    else
      echo "[entrypoint] WARNING: Failed to clone playwright-cli skill." >&2
    fi
  else
    echo "[entrypoint] playwright-cli skill already installed."
  fi

  # Deploy container-hardened Playwright CLI config to tmpfs overlay.
  # /workspace/.playwright is a container-local tmpfs (docker-compose.yml),
  # isolating the container config from the host's workspace volume.
  PLAYWRIGHT_CONFIG="/workspace/.playwright/cli.config.json"
  gosu node mkdir -p /workspace/.playwright
  gosu node cp /usr/local/share/sealpod/playwright-cli.config.json "$PLAYWRIGHT_CONFIG"
  echo "[entrypoint] Playwright CLI config deployed (file:// blocked, isolated sessions)."
else
  echo "[entrypoint] Browser automation disabled (SEALPOD_BROWSER_ENABLED=false)."
  # Remove skill and config if previously installed (clean toggle-off)
  if [ -d "${CLAUDE_CONFIG_DIR}/skills/playwright-cli" ]; then
    rm -rf "${CLAUDE_CONFIG_DIR}/skills/playwright-cli"
    echo "[entrypoint] Removed playwright-cli skill (browser disabled)."
  fi
  rm -f /workspace/.playwright/cli.config.json 2>/dev/null || true
fi

# --- Passthrough mode: only 'claude' and 'sealpod-auth' commands allowed ---
# Firewall is already active at this point.
# Only 'claude' commands are permitted to prevent arbitrary shell access.
if [ "$#" -gt 0 ]; then
  if [ "$1" = "claude" ]; then
    # Prevent container state mutation (claude update/plugin/mcp) — only pass through
    # commands the container is designed for.
    case "${2:-}" in
      remote-control|auth|--version|-v|--rc|-c|-p|-r|"")
        echo "[entrypoint] Passthrough: $*"
        exec capsh \
          --drop=cap_net_admin,cap_net_raw,cap_setpcap,cap_setuid,cap_setgid,cap_kill \
          --user=node \
          -- -c 'exec "$@"' -- "$@"
        ;;
      *)
        echo "[entrypoint] ERROR: Subcommand '$2' not allowed. Permitted: remote-control, auth, --version, --rc, -c, -p, -r" >&2
        exit 1
        ;;
    esac
  elif [ "$1" = "sealpod-auth" ]; then
    shift
    echo "[entrypoint] Running sealpod-auth..."
    exec capsh \
      --drop=cap_net_admin,cap_net_raw,cap_setpcap,cap_setuid,cap_setgid,cap_kill \
      --user=node \
      -- -c 'exec /usr/local/bin/sealpod-auth.sh "$@"' -- "$@"
  else
    echo "[entrypoint] ERROR: Only 'claude' and 'sealpod-auth' commands allowed." >&2
    exit 1
  fi
fi

# --- Pre-flight: credentials exist? ---
if [ ! -f "${CLAUDE_CONFIG_DIR}/.credentials.json" ]; then
  echo "" >&2
  echo "================================================================" >&2
  echo "  SEALPOD: No credentials found." >&2
  echo "  Run: docker compose run --rm sealpod sealpod-auth" >&2
  echo "================================================================" >&2
  echo "" >&2
  exit 1
fi

# --- Pre-flight: refresh OAuth token before launching remote-control ---
# Claude Code does not reliably refresh tokens on startup (anthropics/claude-code#34306).
# Server-side invalidation (rotation, concurrent sessions) can revoke tokens before
# the client-side expiresAt. Always refresh to guarantee a fresh token.
echo "[entrypoint] Refreshing OAuth token..."
gosu node /usr/local/bin/sealpod-refresh.sh "[entrypoint]" || echo "[entrypoint] Token refresh skipped — will rely on existing token or background loop." >&2

# --- Phase 2: Build command ---
# Two modes depending on whether Telegram channel is enabled:
#   With TELEGRAM_BOT_TOKEN:    claude --rc --channels ... (interactive + remote-control)
#   Without TELEGRAM_BOT_TOKEN: claude remote-control      (server mode, supports --spawn/--capacity)
#
# Reason: `claude remote-control` (bridgeMain.ts) rejects --channels flag.
# `claude --rc --channels` works because both are Commander.js options on the same program.

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  # Interactive + remote-control + Telegram channel
  set -- claude --rc --channels plugin:telegram@claude-plugins-official

  if [ -n "${RC_NAME:-}" ]; then
    set -- "$@" --name "${RC_NAME}"
  fi

  # Permission mode (default: bypassPermissions — container is the security boundary)
  PERM_MODE="${SEALPOD_PERMISSION_MODE:-bypassPermissions}"
  set -- "$@" --permission-mode "${PERM_MODE}"

  if [ "${RC_VERBOSE:-false}" = "true" ]; then
    set -- "$@" --verbose
  fi

  # Note: --spawn/--capacity not available in --rc mode (1 session per process).
  # For concurrent sessions, run multiple container instances.
else
  # Server mode (original behavior — no Telegram)
  set -- claude remote-control

  if [ -n "${RC_NAME:-}" ]; then
    set -- "$@" --name "${RC_NAME}"
  fi

  SPAWN_MODE="${RC_SPAWN:-worktree}"
  set -- "$@" --spawn "${SPAWN_MODE}"

  if [ -n "${RC_CAPACITY:-}" ] && [ "${RC_CAPACITY}" != "32" ]; then
    set -- "$@" --capacity "${RC_CAPACITY}"
  fi

  if [ "${RC_VERBOSE:-false}" = "true" ]; then
    set -- "$@" --verbose
  fi
fi

echo "[entrypoint] Executing as node: $*"

# Drop ALL added capabilities and switch to node user via capsh.
# Fork background token refresher — Claude Code does not auto-refresh expired
# tokens mid-session (anthropics/claude-code#28827). tini reaps it on exit.
exec capsh \
  --drop=cap_net_admin,cap_net_raw,cap_setpcap,cap_setuid,cap_setgid,cap_kill \
  --user=node \
  -- -c '/usr/local/bin/sealpod-token-loop.sh & exec "$@"' -- "$@"
