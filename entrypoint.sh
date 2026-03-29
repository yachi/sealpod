#!/bin/bash
set -euo pipefail

# =============================================================================
# Sealpod — Container Entrypoint
# Runs as root. Phase 1: firewall (as root). Phase 2: trust (as node via gosu). Phase 3: exec with cap drop.
# Firewall applies in ALL modes including passthrough.
# =============================================================================

echo "[entrypoint] Starting Sealpod container..."

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

  fs.writeFileSync(settingsJson, JSON.stringify(settings, null, 2));
  console.log("[entrypoint] Workspace trust + mktemp hooks + plugin marketplace configured.");
} catch(e) {
  console.error("[entrypoint] WARNING: Setup error:", e.message);
}
'

# --- Install microsoft/playwright-cli skill (not a marketplace — standalone skill repo) ---
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

# --- Passthrough mode: only 'claude' and 'sealpod-auth' commands allowed ---
# Firewall is already active at this point.
# Only 'claude' commands are permitted to prevent arbitrary shell access.
if [ "$#" -gt 0 ]; then
  if [ "$1" = "claude" ]; then
    echo "[entrypoint] Passthrough: $*"
    exec capsh \
      --drop=cap_net_admin,cap_net_raw,cap_setpcap,cap_setuid,cap_setgid,cap_kill \
      --user=node \
      -- -c 'exec "$@"' -- "$@"
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

# --- Phase 2: Build remote-control command ---
set -- claude remote-control

if [ -n "${RC_NAME:-}" ]; then
  set -- "$@" --name "${RC_NAME}"
fi

# Default to worktree (each session gets isolated mktemp dir via hooks)
SPAWN_MODE="${RC_SPAWN:-worktree}"
set -- "$@" --spawn "${SPAWN_MODE}"

if [ -n "${RC_CAPACITY:-}" ] && [ "${RC_CAPACITY}" != "32" ]; then
  set -- "$@" --capacity "${RC_CAPACITY}"
fi

if [ "${RC_VERBOSE:-false}" = "true" ]; then
  set -- "$@" --verbose
fi

echo "[entrypoint] Executing as node: $*"

# Drop ALL added capabilities and switch to node user via capsh.
exec capsh \
  --drop=cap_net_admin,cap_net_raw,cap_setpcap,cap_setuid,cap_setgid,cap_kill \
  --user=node \
  -- -c 'exec "$@"' -- "$@"
