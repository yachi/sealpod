#!/bin/sh
# Sealpod — Health Check
# Only checks auth status — no fallback.
# Auth failure = unhealthy → triggers restart via restart policy.
#
# LIMITATION: `claude auth status` checks only whether a credentials file
# exists with an accessToken field. It does NOT check token expiry or
# validity. An expired token still returns exit 0 ("healthy").
# This means the healthcheck cannot detect a failed token refresh.

exec gosu node claude auth status >/dev/null 2>&1
