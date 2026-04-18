#!/bin/bash
set -euo pipefail

# =============================================================================
# sealpod-browser-lock.sh — Browser security wrapper
#
# 1. Single concurrent instance: exclusive flock on /tmp/sealpod-browser.lock.
# 2. Domain allowlist: PLAYWRIGHT_ALLOWED_DOMAINS restricts navigation targets.
# 3. Content sanitization: truncate output files to SEALPOD_BROWSER_MAX_OUTPUT
#    bytes (default 50KB). Accessibility tree snapshots already exclude hidden
#    elements, <script>, <meta>, and HTML comments by nature.
#
# Installed as /usr/local/bin/playwright-cli, replacing the npm symlink
# (real binary moved to playwright-cli-unwrapped).
# =============================================================================

MAX_OUTPUT="${SEALPOD_BROWSER_MAX_OUTPUT:-51200}"  # 50KB default
OUTPUT_DIR="${PLAYWRIGHT_CLI_OUTPUT_DIR:-.playwright-cli}"

# --- Domain allowlist (defense-in-depth, bypassable — not primary control) ---
# PLAYWRIGHT_ALLOWED_DOMAINS: comma-separated list of allowed domains.
# When set, only goto/open to these domains (or subdomains) are permitted.
# When unset, all domains are allowed (firewall is the primary control).
if [ -n "${PLAYWRIGHT_ALLOWED_DOMAINS:-}" ]; then
  URL=""
  case "${1:-}" in
    goto)  URL="${2:-}" ;;
    open)  URL="${2:-}" ;;
  esac

  if [ -n "$URL" ]; then
    # Extract hostname from URL (strip scheme, port, path)
    HOST=$(printf '%s' "$URL" | sed -E 's|^https?://||; s|[:/].*||')

    ALLOWED=false
    IFS=',' read -ra DOMAINS <<< "$PLAYWRIGHT_ALLOWED_DOMAINS"
    for domain in "${DOMAINS[@]}"; do
      domain=$(printf '%s' "$domain" | xargs)  # trim whitespace
      # Match exact domain or subdomain (e.g., "example.com" matches "sub.example.com")
      if [ "$HOST" = "$domain" ] || [[ "$HOST" == *."$domain" ]]; then
        ALLOWED=true
        break
      fi
    done

    if [ "$ALLOWED" = false ]; then
      echo "[sealpod] ERROR: Domain '$HOST' not in PLAYWRIGHT_ALLOWED_DOMAINS." >&2
      echo "[sealpod] Allowed: $PLAYWRIGHT_ALLOWED_DOMAINS" >&2
      exit 1
    fi
  fi
fi

# --- Single concurrent instance ---
LOCK_FILE="/tmp/sealpod-browser.lock"
LOCK_TIMEOUT="${SEALPOD_BROWSER_LOCK_TIMEOUT:-30}"

exec 9>"$LOCK_FILE"

if ! flock --timeout "$LOCK_TIMEOUT" 9; then
  echo "[sealpod] ERROR: Browser lock timeout (${LOCK_TIMEOUT}s) — another browser session is active." >&2
  echo "[sealpod] Only one concurrent browser instance is allowed per container." >&2
  exit 1
fi

# --- Record pre-existing output files (to identify new ones after command) ---
declare -A EXISTING_FILES
if [ -d "$OUTPUT_DIR" ]; then
  while IFS= read -r -d '' f; do
    EXISTING_FILES["$f"]=1
  done < <(find "$OUTPUT_DIR" -type f -print0 2>/dev/null)
fi

# --- Run playwright-cli (no exec — need post-processing) ---
EXIT_CODE=0
playwright-cli-unwrapped "$@" || EXIT_CODE=$?

# --- Content sanitization: truncate new output files exceeding size cap ---
if [ -d "$OUTPUT_DIR" ]; then
  while IFS= read -r -d '' f; do
    [ -z "${EXISTING_FILES[$f]+x}" ] || continue  # skip pre-existing files
    SIZE=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt "$MAX_OUTPUT" ]; then
      TRUNCATED_NOTICE=$'\n\n[sealpod] OUTPUT TRUNCATED: original size '"$SIZE"' bytes, limit '"$MAX_OUTPUT"' bytes.'
      head -c "$MAX_OUTPUT" "$f" > "${f}.tmp"
      printf '%s\n' "$TRUNCATED_NOTICE" >> "${f}.tmp"
      mv "${f}.tmp" "$f"
      echo "[sealpod] Truncated output: $f ($SIZE → $MAX_OUTPUT bytes)" >&2
    fi
  done < <(find "$OUTPUT_DIR" -type f -print0 2>/dev/null)
fi

exit "$EXIT_CODE"
