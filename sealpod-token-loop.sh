#!/bin/bash
# Background OAuth token refresh loop for headless Docker containers.
# Calls sealpod-refresh.sh at 75% of token lifetime. Failures are logged
# and retried — the loop never exits (tini reaps it when claude exits).

trap 'exit 0' TERM INT
export CRED_FILE="${CLAUDE_CONFIG_DIR:?}/.credentials.json"
MIN_SLEEP=300        # 5 minutes minimum between refreshes
MAX_FAILURES=5       # Restore backup refresh token after this many consecutive failures
FAILURES=0

while true; do
  # Calculate sleep: 75% of remaining token lifetime (min 5 min, default 6h)
  SLEEP_SEC=$(node -e "
    try {
      const c = JSON.parse(require('fs').readFileSync(process.env.CRED_FILE, 'utf8'));
      const remaining = Math.max(0, (c.claudeAiOauth?.expiresAt || 0) - Date.now()) / 1000;
      console.log(Math.max(${MIN_SLEEP}, Math.floor(remaining * 0.75)));
    } catch(e) { console.log(21600); }
  " 2>/dev/null || echo 21600)

  echo "[token-loop] Next refresh in ${SLEEP_SEC}s" >&2
  sleep "$SLEEP_SEC" || exit 0  # exit cleanly on signal during sleep

  if /usr/local/bin/sealpod-refresh.sh "[token-loop]"; then
    FAILURES=0
  else
    FAILURES=$((FAILURES + 1))
    echo "[token-loop] Refresh failed (attempt ${FAILURES}/${MAX_FAILURES})" >&2

    # Restore backup refresh token after MAX_FAILURES consecutive failures
    if [ "$FAILURES" -ge "$MAX_FAILURES" ] && [ -f "$CRED_FILE" ]; then
      node -e "
        const fs = require('fs');
        const cred = JSON.parse(fs.readFileSync(process.env.CRED_FILE, 'utf8'));
        const prev = cred.claudeAiOauth?._previousRefreshToken;
        if (prev && prev !== cred.claudeAiOauth?.refreshToken) {
          cred.claudeAiOauth.refreshToken = prev;
          delete cred.claudeAiOauth._previousRefreshToken;
          const tmp = process.env.CRED_FILE + '.tmp';
          fs.writeFileSync(tmp, JSON.stringify(cred), { mode: 0o600 });
          fs.renameSync(tmp, process.env.CRED_FILE);
          console.error('[token-loop] Restored previous refresh token after ' + ${MAX_FAILURES} + ' failures.');
        }
      " 2>&1 || true
      FAILURES=0
    fi
  fi
done
