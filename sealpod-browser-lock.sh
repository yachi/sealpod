#!/bin/bash
set -euo pipefail

# =============================================================================
# sealpod-browser-lock.sh — Single concurrent browser instance enforcement
#
# Wraps playwright-cli with an exclusive flock to prevent multiple browser
# sessions per container. If another session holds the lock, waits up to
# SEALPOD_BROWSER_LOCK_TIMEOUT seconds (default 30) before failing.
#
# Installed as /usr/local/bin/playwright-cli, replacing the npm symlink
# (real binary moved to playwright-cli-unwrapped).
# =============================================================================

LOCK_FILE="/tmp/sealpod-browser.lock"
LOCK_TIMEOUT="${SEALPOD_BROWSER_LOCK_TIMEOUT:-30}"

exec 9>"$LOCK_FILE"

if ! flock --timeout "$LOCK_TIMEOUT" 9; then
  echo "[sealpod] ERROR: Browser lock timeout (${LOCK_TIMEOUT}s) — another browser session is active." >&2
  echo "[sealpod] Only one concurrent browser instance is allowed per container." >&2
  exit 1
fi

exec playwright-cli-unwrapped "$@"
