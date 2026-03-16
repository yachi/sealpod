#!/bin/sh
# Sealpod — Health Check
# Only checks auth status — no fallback.
# Auth failure = unhealthy → triggers restart via restart policy.
# This ensures token expiry is detected and acted upon.

exec gosu node claude auth status >/dev/null 2>&1
