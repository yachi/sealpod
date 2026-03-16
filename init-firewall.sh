#!/bin/bash
set -euo pipefail

# =============================================================================
# Sealpod — Outbound Firewall
#
# SECURITY POLICY (explicit, not hidden):
#   - All outbound HTTPS (port 443) is OPEN to any destination.
#     This is required for WebFetch and Claude Code tools that access
#     arbitrary websites. Domain-level restriction is NOT enforced.
#   - All other outbound ports are BLOCKED (default DROP).
#   - DNS is restricted to Docker's internal resolver (127.0.0.11)
#     to prevent DNS tunneling exfiltration.
#   - IPv4 and IPv6 are both locked down.
#
# WHAT THIS FIREWALL PREVENTS:
#   - Non-HTTPS exfiltration (SSH tunnels, raw TCP, custom ports)
#   - DNS tunneling to external resolvers
#   - IPv6 bypass of IPv4 iptables rules
#
# WHAT THIS FIREWALL DOES NOT PREVENT:
#   - Data exfiltration via HTTPS to arbitrary domains (port 443 is open)
#   - Covert channels via api.anthropic.com (always reachable)
#   - These are accepted trade-offs for WebFetch functionality.
# =============================================================================

echo "[firewall] Configuring outbound firewall..."

DOCKER_DNS="127.0.0.11"

# --- Step 1: Save Docker DNS NAT rules via iptables-save ---
SAVED_NAT_RULES=""
if iptables -t nat -S 2>/dev/null | grep -q "${DOCKER_DNS}"; then
  SAVED_NAT_RULES=$(iptables-save -t nat 2>/dev/null || true)
fi

# --- Step 2: Flush existing rules ---
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# --- Step 3: Restore Docker DNS NAT rules via iptables-restore ---
if [ -n "${SAVED_NAT_RULES}" ]; then
  echo "${SAVED_NAT_RULES}" | iptables-restore -T nat 2>/dev/null || true
  echo "[firewall]   Restored Docker DNS NAT rules"
fi

# --- Step 4: Allow loopback ---
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# --- Step 5: Allow DNS to Docker internal resolver ONLY (blocks DNS tunneling) ---
iptables -A OUTPUT -p udp -d "${DOCKER_DNS}" --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp -d "${DOCKER_DNS}" --dport 53 -j ACCEPT
iptables -A INPUT -p udp -s "${DOCKER_DNS}" --sport 53 -j ACCEPT
iptables -A INPUT -p tcp -s "${DOCKER_DNS}" --sport 53 -j ACCEPT

# --- Step 6: Set default policies to DROP ---
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# --- Step 7: Allow established/related connections ---
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# --- Step 8: Allow ALL outbound HTTPS (port 443) ---
# This is an explicit design decision: WebFetch and Claude Code tools need
# to reach arbitrary domains. See header comment for security trade-offs.
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT

# --- Step 9: Log and reject all other outbound ---
# REJECT (not DROP) provides immediate feedback to the process.
iptables -A OUTPUT -j LOG --log-prefix "[firewall-blocked] " --log-level 4 2>/dev/null || true
iptables -A OUTPUT -j REJECT --reject-with icmp-net-prohibited

# --- Step 10: IPv6 defense-in-depth (supplement sysctl disable) ---
if command -v ip6tables >/dev/null 2>&1; then
  if ip6tables -P INPUT DROP 2>/dev/null && \
     ip6tables -P OUTPUT DROP 2>/dev/null && \
     ip6tables -P FORWARD DROP 2>/dev/null; then
    echo "[firewall]   IPv6: DROP policies set"
  else
    echo "[firewall]   WARNING: ip6tables policy set FAILED (sysctl disable still active)" >&2
  fi
else
  echo "[firewall]   WARNING: ip6tables not available (relying on sysctl IPv6 disable)" >&2
fi

# --- Step 11: Verify ---
echo "[firewall] Verifying firewall rules..."

# Should FAIL: non-HTTPS port (port 80)
if curl -sf --connect-timeout 3 http://example.com >/dev/null 2>&1; then
  echo "[firewall] ERROR: HTTP port 80 is reachable!" >&2
  exit 1
fi
echo "[firewall]   PASS: HTTP (port 80) blocked"

# Should SUCCEED: HTTPS (port 443)
if curl -sf --connect-timeout 5 -o /dev/null -w "%{http_code}" https://example.com 2>/dev/null | grep -qE '^[2-4]'; then
  echo "[firewall]   PASS: HTTPS (port 443) open"
else
  echo "[firewall]   WARNING: HTTPS connectivity uncertain"
fi

echo "[firewall] Policy: HTTPS (443) open | all other ports blocked | DNS restricted to ${DOCKER_DNS} | IPv6 dropped"
echo "[firewall] Done."
