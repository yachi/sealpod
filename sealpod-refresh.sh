#!/bin/bash
set -euo pipefail

# =============================================================================
# sealpod-refresh.sh — Single-shot OAuth token refresh
#
# Reads .credentials.json, refreshes the access token via the refresh_token
# grant, and writes updated credentials atomically. Exits 0 on success, 1 on
# failure. Shared by entrypoint.sh (pre-flight) and sealpod-token-loop.sh
# (background refresh).
#
# Claude Code caches tokens with 30s TTL and re-reads from disk (#24317),
# but does NOT auto-refresh expired tokens mid-session (#28827, #12447).
# =============================================================================

CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
TOKEN_URL="https://platform.claude.com/v1/oauth/token"
UA="axios/1.9.0"

CRED_FILE="${CLAUDE_CONFIG_DIR:?}/.credentials.json"
LOG_PREFIX="${1:-[refresh]}"

if [ ! -f "$CRED_FILE" ]; then
  echo "${LOG_PREFIX} No credentials file — skipping." >&2
  exit 1
fi

# Extract refresh token via Node.js (no jq dependency for JSON read+write)
REFRESH_TOKEN=$(node -e "
  const c = JSON.parse(require('fs').readFileSync(process.env.CRED_FILE, 'utf8'));
  console.log(c.claudeAiOauth?.refreshToken || '');
" 2>/dev/null) || true

if [ -z "$REFRESH_TOKEN" ]; then
  echo "${LOG_PREFIX} No refresh token — skipping." >&2
  exit 1
fi

# Refresh via curl, token passed via stdin to avoid /proc/pid/cmdline leak
REQUEST_BODY=$(printf '{"grant_type":"refresh_token","refresh_token":"%s","client_id":"%s"}' \
  "$REFRESH_TOKEN" "$CLIENT_ID")

HTTP_RESPONSE=$(printf '%s' "$REQUEST_BODY" | curl -s --connect-timeout 10 --max-time 30 \
  -w "\n%{http_code}" \
  -X POST "$TOKEN_URL" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $UA" \
  --data-binary @- \
) || { echo "${LOG_PREFIX} Network error." >&2; exit 1; }

HTTP_CODE=$(printf '%s' "$HTTP_RESPONSE" | tail -1)
BODY=$(printf '%s' "$HTTP_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
  echo "${LOG_PREFIX} Token refresh failed (HTTP ${HTTP_CODE}): ${BODY}" >&2
  exit 1
fi

# Atomic write with updated token — backup previous refresh token in case
# the new one is invalid (server-side rotation can issue bad tokens).
node -e "
  const fs = require('fs');
  const credFile = process.env.CRED_FILE;
  const cred = JSON.parse(fs.readFileSync(credFile, 'utf8'));
  const tok = JSON.parse(process.argv[1]);
  const oauth = cred.claudeAiOauth;
  oauth.accessToken = tok.access_token;
  if (tok.refresh_token) {
    oauth._previousRefreshToken = oauth.refreshToken;
    oauth.refreshToken = tok.refresh_token;
  }
  oauth.expiresAt = Date.now() + (tok.expires_in || 28800) * 1000;
  if (tok.scope) oauth.scopes = tok.scope.split(' ').filter(Boolean);
  const tmp = credFile + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(cred), { mode: 0o600 });
  fs.renameSync(tmp, credFile);
  console.error(process.argv[2] + ' Token refreshed (expires in ' + (tok.expires_in || 28800) + 's).');
" "$BODY" "$LOG_PREFIX"
