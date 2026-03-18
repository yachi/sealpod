#!/bin/bash
set -euo pipefail

# =============================================================================
# sealpod-auth.sh — OAuth PKCE authentication for headless Docker containers
#
# Performs the full OAuth 2.0 Authorization Code + PKCE flow without a browser:
#   1. Generates PKCE verifier/challenge + state
#   2. Prints authorization URL for the user to open in any browser
#   3. User authorizes and copies the code from the callback page
#   4. Exchanges code for tokens at console.anthropic.com
#   5. Writes ~/.claude/.credentials.json
#
# This gives the container its OWN independent OAuth session — no shared
# refresh token with the host's Claude Code instance.
#
# During normal operation, `claude remote-control` auto-refreshes tokens
# before each API call. Re-running this script is only needed after the
# container has been stopped long enough for the refresh token to expire.
# Always stop the container before re-authenticating to avoid credential
# file conflicts from concurrent token refresh.
#
# Dependencies: openssl, curl, jq (all included in the container image)
# =============================================================================

CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
AUTH_URL="https://claude.ai/oauth/authorize"
TOKEN_URL="https://console.anthropic.com/v1/oauth/token"
REDIRECT_URI="https://console.anthropic.com/oauth/code/callback"
SCOPES="org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

CRED_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CRED_FILE="${CRED_DIR}/.credentials.json"

# --- TTY check ---

if [ ! -t 0 ]; then
  echo "ERROR: sealpod-auth requires an interactive terminal." >&2
  echo "Run with: docker compose run --rm sealpod sealpod-auth" >&2
  exit 1
fi

# --- Cleanup trap ---

TMPFILE=""
trap 'rm -f "$TMPFILE" 2>/dev/null' EXIT

# --- Helpers (no python3 — only openssl, jq, curl) ---

generate_random() {
  openssl rand -base64 32 | tr '+/' '-_' | tr -d '='
}

s256_challenge() {
  printf '%s' "$1" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '='
}

url_encode() {
  local string="$1" i c
  local encoded=""
  for (( i=0; i<${#string}; i++ )); do
    c="${string:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) encoded+="$c" ;;
      ' ') encoded+='+' ;;
      *) encoded+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$encoded"
}

epoch_ms() {
  if date +%s%N >/dev/null 2>&1; then
    printf '%s' "$(( $(date +%s%N) / 1000000 ))"
  else
    printf '%s' "$(( $(date +%s) * 1000 ))"
  fi
}

# --- Generate PKCE parameters ---

CODE_VERIFIER=$(generate_random)
CODE_CHALLENGE=$(s256_challenge "$CODE_VERIFIER")
STATE=$(generate_random)

# --- Build authorization URL ---

ENCODED_SCOPES=$(url_encode "$SCOPES")
ENCODED_REDIRECT=$(url_encode "$REDIRECT_URI")

AUTHORIZE_URL="${AUTH_URL}?code=true&client_id=${CLIENT_ID}&response_type=code&redirect_uri=${ENCODED_REDIRECT}&scope=${ENCODED_SCOPES}&code_challenge=${CODE_CHALLENGE}&code_challenge_method=S256&state=${STATE}"

# --- Prompt user ---

echo ""
echo "=== Sealpod Authentication ==="
echo ""
echo "Open this URL in your browser:"
echo ""
echo "  ${AUTHORIZE_URL}"
echo ""
echo "After authorizing, you'll be redirected to a page showing an authorization code."
echo "Copy the full code (or the URL) and paste it below."
echo ""
read -r -p "Authorization code: " AUTH_CODE

if [ -z "${AUTH_CODE}" ]; then
  echo "ERROR: No authorization code provided." >&2
  exit 1
fi

# Strip whitespace
AUTH_CODE=$(printf '%s' "$AUTH_CODE" | tr -d '[:space:]')

# Handle full URL paste — extract code= parameter
if [[ "$AUTH_CODE" == http* ]]; then
  EXTRACTED=$(printf '%s' "$AUTH_CODE" | sed -n 's/.*[?&]code=\([^&#]*\).*/\1/p')
  if [ -z "$EXTRACTED" ]; then
    echo "ERROR: Could not extract authorization code from URL." >&2
    echo "Please paste only the code value, not the full URL." >&2
    exit 1
  fi
  AUTH_CODE="$EXTRACTED"
fi

# Strip #state suffix if present (callback page shows code#state)
PASTED_STATE="${AUTH_CODE#*#}"
AUTH_CODE="${AUTH_CODE%%#*}"

# Validate state if present in paste
if [ "$PASTED_STATE" != "$AUTH_CODE" ] && [ "$PASTED_STATE" != "$STATE" ]; then
  echo "ERROR: State parameter mismatch — possible CSRF. Please re-run sealpod-auth." >&2
  exit 1
fi

# --- Exchange code for tokens ---

echo ""
echo "Exchanging code for tokens..."

REQUEST_BODY=$(jq -n \
  --arg grant_type "authorization_code" \
  --arg code "$AUTH_CODE" \
  --arg redirect_uri "$REDIRECT_URI" \
  --arg client_id "$CLIENT_ID" \
  --arg code_verifier "$CODE_VERIFIER" \
  --arg state "$STATE" \
  '{grant_type: $grant_type, code: $code, redirect_uri: $redirect_uri, client_id: $client_id, code_verifier: $code_verifier, state: $state}')

HTTP_RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -w "\n%{http_code}" \
  -X POST "${TOKEN_URL}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY")

HTTP_CODE=$(printf '%s' "$HTTP_RESPONSE" | tail -1)
BODY=$(printf '%s' "$HTTP_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "000" ]; then
  echo "ERROR: Could not reach Anthropic servers. Check your internet connection." >&2
  exit 1
fi

if [ "$HTTP_CODE" = "400" ]; then
  ERROR_TYPE=$(printf '%s' "$BODY" | jq -r '.error // ""' 2>/dev/null)
  if [ "$ERROR_TYPE" = "invalid_grant" ]; then
    echo "ERROR: The authorization code has expired or was already used." >&2
    echo "Re-run: docker compose run --rm sealpod sealpod-auth" >&2
    exit 1
  fi
fi

if [ "$HTTP_CODE" != "200" ]; then
  echo "ERROR: Token exchange failed (HTTP ${HTTP_CODE}):" >&2
  echo "$BODY" >&2
  exit 1
fi

# --- Parse response ---

ACCESS_TOKEN=$(printf '%s' "$BODY" | jq -r '.access_token')
REFRESH_TOKEN=$(printf '%s' "$BODY" | jq -r '.refresh_token // ""')
EXPIRES_IN=$(printf '%s' "$BODY" | jq -r '.expires_in // 3600')
SCOPE_STR=$(printf '%s' "$BODY" | jq -r '.scope // ""')

if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
  echo "ERROR: No access token in response." >&2
  echo "$BODY" >&2
  exit 1
fi

# Compute expiresAt (epoch ms)
NOW_MS=$(epoch_ms)
EXPIRES_AT=$(( NOW_MS + EXPIRES_IN * 1000 ))

# Build scopes as JSON array
SCOPES_JSON=$(printf '%s' "$SCOPE_STR" | jq -R 'split(" ") | map(select(. != ""))')

# --- Fetch subscription type (best-effort) ---

echo "Fetching account profile..."

SUB_TYPE="null"
PROFILE_RESP=$(curl -s --connect-timeout 10 --max-time 15 -w "\n%{http_code}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "anthropic-beta: oauth-2025-04-20" \
  "https://api.anthropic.com/api/oauth/profile" 2>/dev/null) || true

PROFILE_HTTP=$(printf '%s' "$PROFILE_RESP" | tail -1)
if [ "$PROFILE_HTTP" = "200" ]; then
  PROFILE_BODY=$(printf '%s' "$PROFILE_RESP" | sed '$d')
  SUB_TYPE=$(printf '%s' "$PROFILE_BODY" | jq '.subscriptionType // .subscription_type // null') || SUB_TYPE="null"
fi

# --- Write credentials ---

mkdir -p "$CRED_DIR"
chmod 700 "$CRED_DIR"

CRED_JSON=$(jq -n \
  --arg at "$ACCESS_TOKEN" \
  --arg rt "$REFRESH_TOKEN" \
  --argjson ea "$EXPIRES_AT" \
  --argjson sc "$SCOPES_JSON" \
  --argjson st "$SUB_TYPE" \
  '{claudeAiOauth: {accessToken: $at, refreshToken: $rt, expiresAt: $ea, scopes: $sc, subscriptionType: $st}}')

# Atomic write
TMPFILE=$(mktemp "${CRED_DIR}/.credentials.XXXXXX")
printf '%s' "$CRED_JSON" > "$TMPFILE"
chmod 600 "$TMPFILE"
mv "$TMPFILE" "$CRED_FILE"

echo ""
echo "Authentication successful!"
echo "  Token expires in: ${EXPIRES_IN}s"
echo "  Scopes: ${SCOPE_STR}"
echo "  Credentials written to: ${CRED_FILE}"
echo ""
