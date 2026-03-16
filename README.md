# Sealpod

> **Disclaimer:** Sealpod is an independent community project. It is not affiliated with, endorsed by, or sponsored by Anthropic.

Security-hardened Docker setup for running Claude Code's [Remote Control](https://code.claude.com/docs/en/remote-control) feature inside a container. Control Claude Code from claude.ai/code or the Claude mobile app while it runs securely in Docker.

## Architecture

```
┌─────────────────────────────┐     outbound HTTPS      ┌──────────────────────┐
│  Docker Container           │ ──────────────────────→  │  Anthropic API       │
│                             │ ←────────────────────── │  api.anthropic.com   │
│  claude remote-control      │     polling responses    └──────────────────────┘
│  node:20 + tini (PID 1)    │                                    ↕
│  iptables default-deny      │                          ┌──────────────────────┐
│  read-only rootfs           │                          │  claude.ai/code      │
│  cap_drop ALL               │                          │  Claude iOS/Android  │
│  gosu + capsh (priv drop)   │                          └──────────────────────┘
└─────────────────────────────┘

No inbound ports — Remote Control uses outbound HTTPS polling only.
The container registers with Anthropic's API and polls for work.
Users connect via claude.ai/code or the Claude mobile app.
```

## Prerequisites

- **Docker Engine 25.0.3+** (mitigates CVE-2024-21626)
- **Docker Compose v2**
- **Claude Pro, Max, Team, or Enterprise subscription** (API keys are NOT supported for Remote Control)

## Quick Start

```bash
# 1. Configure environment
cp .env.example .env
# Edit .env if needed (defaults work for most setups)

# 2. Build the image
docker compose build

# 3. Authenticate (works on macOS and Linux — same flow)
docker compose run --rm sealpod sealpod-auth

# 4. Start Remote Control
docker compose up -d

# 5. Check logs for session URL
docker compose logs -f
```

After step 4, find the session in [claude.ai/code](https://claude.ai/code) or the Claude app.

## Authentication

Remote Control requires a claude.ai subscription (Pro/Max/Team/Enterprise). API keys are not supported.

### How it works

`sealpod-auth` performs a full OAuth 2.0 Authorization Code + PKCE flow from inside the container:

1. Generates a PKCE code verifier/challenge and state parameter
2. Prints an authorization URL — you open it in any browser
3. After authorizing on claude.ai, you're redirected to a page showing a code
4. You paste the code back into the terminal
5. The script exchanges the code for tokens and writes `.credentials.json`

The container gets its **own independent OAuth session** — it does not share tokens with your host's Claude Code installation. This avoids refresh token race conditions when running Claude Code on both the host and in Docker simultaneously.

**Token lifetime:** 8 hours. The container's Claude Code process handles refresh automatically via the refresh token stored in `.credentials.json`.

### Re-authentication

When the token expires and cannot be refreshed (e.g., after a long downtime), re-run:

```bash
docker compose run --rm sealpod sealpod-auth
```

### Verify Auth Status

```bash
docker compose run --rm sealpod claude auth status
```

> **Note:** Passthrough mode permits `claude` and `sealpod-auth` commands only — arbitrary shell access is blocked by the entrypoint. The iptables firewall is active in all modes.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_CODE_VERSION` | `2.1.76` | Claude Code CLI version (pin for reproducibility) |
| `RC_NAME` | `sealpod` | Session name visible in claude.ai/code |
| `RC_SPAWN` | `worktree` | Spawn mode: `same-dir` or `worktree` (worktree = isolated per-session dirs) |
| `GH_TOKEN` | (empty) | GitHub personal access token for `gh` CLI inside container |
| `RC_CAPACITY` | `32` | Max concurrent sessions |
| `RC_VERBOSE` | `false` | Enable verbose logging |
| `CLAUDE_CONFIG_HOST_PATH` | `~/.claude-docker` | Host path to Claude credentials directory |
| `WORKSPACE_HOST_PATH` | `.` (current dir) | Host path to workspace directory |
| `TZ` | `UTC` | Container timezone |

### Credential Persistence

The directory pointed to by `CLAUDE_CONFIG_HOST_PATH` is mounted into the container at `/home/node/.claude`. The mount MUST be writable — Claude Code refreshes OAuth tokens during normal operation and writes the updated token back to disk.

## Security Model

### What's Hardened

| Control | Implementation |
|---------|---------------|
| Non-root execution | `capsh --user=node` drops from root to `node` after firewall init |
| Capability drop | `cap_drop: ALL`, NET_ADMIN/NET_RAW/SETPCAP added then dropped post-firewall via `capsh --drop` |
| Read-only filesystem | `read_only: true` with tmpfs for writable areas |
| No new privileges | `no-new-privileges:true` (compatible with gosu, blocks setuid escalation) |
| Firewall (HTTPS open) | iptables allows all outbound port 443; blocks non-HTTPS exfiltration (SSH, raw TCP, custom ports) |
| Blocked connection logging | iptables LOG rule records rejected packets |
| DNS tunneling prevention | DNS restricted to Docker internal resolver (127.0.0.11) |
| IPv6 disabled | `net.ipv6.conf.all.disable_ipv6: 1` (sysctl) + ip6tables DROP policies (defense-in-depth) |
| Passthrough mode restriction | Only `claude` and `sealpod-auth` commands are allowed via passthrough |
| PID 1 handling | `tini` via `init: true` (signal forwarding, zombie reaping) |
| Fork bomb defense | `pids_limit: 512` |
| Resource limits | `mem_limit: 2g`, `cpus: 2.0`, swap disabled |
| Noexec on tmpfs | `/tmp`, `.cache`, `.npm` mounted with `noexec` |
| Logging | Local driver with rotation (50MB x 5 files) |

### Firewall Policy

All outbound HTTPS (port 443) is **open to any destination** — the firewall is NOT domain-restricted.

**What the firewall prevents:**
- Non-HTTPS exfiltration: SSH, raw TCP, and traffic on custom ports are blocked
- DNS tunneling: DNS is restricted to the Docker internal resolver (127.0.0.11); external DNS is blocked
- IPv6 bypass: ip6tables DROP policies + `net.ipv6.conf.all.disable_ipv6: 1` sysctl (defense-in-depth)
- Blocked connections are logged via iptables LOG rule

**What the firewall does NOT prevent:**
- Data exfiltration via HTTPS to arbitrary domains (port 443 is open; WebFetch can reach any host)
- Covert channels tunneled through `api.anthropic.com` or other permitted HTTPS endpoints

### `--dangerously-skip-permissions`

`claude remote-control` runs with this flag implicitly. In a containerized environment:
- The **container** is the security boundary (firewall, read-only FS, capability drop)
- Permission prompts would cause the headless process to hang indefinitely
- Community Docker setups for Claude Code use this pattern
- Anthropic's [devcontainer reference](https://github.com/anthropics/claude-code/tree/main/.devcontainer) uses this pattern when a firewall provides isolation

### Known Limitations

- **HTTPS exfiltration is unrestricted**: Port 443 is fully open. A prompt injection can exfiltrate data to any HTTPS endpoint, not just Anthropic domains. The firewall does not mitigate this.
- **Covert channels via Anthropic API**: Data can be embedded in normal `api.anthropic.com` traffic. Anthropic acknowledges this limitation.
- **Workspace access**: Everything under `WORKSPACE_HOST_PATH` is accessible to the agent. Do not mount directories containing SSH keys, `.env` files with production secrets, or other sensitive data unless needed.
- **Token refresh**: Access tokens expire every 8 hours. The Claude Code process refreshes them automatically using the refresh token. If the refresh token itself expires (e.g., after extended downtime), re-run `sealpod-auth`.
- **Git CVE surface**: `git` is installed for `--spawn worktree` mode and has a history of CVEs. This is an accepted risk.

## Troubleshooting

### Container shows "unhealthy"

```bash
# Check logs
docker compose logs --tail 50

# Re-authenticate
docker compose run --rm sealpod sealpod-auth

# Restart
docker compose restart
```

### OOM kill (container keeps restarting)

Increase memory limit in `docker-compose.yml`:

```yaml
mem_limit: 4g
memswap_limit: 4g
```

### Session timeout

Remote Control exits after ~10 minutes of network outage. The `restart: unless-stopped` policy automatically restarts it. Check `docker compose logs` for timeout messages.

## Development

### Build with specific version

```bash
docker compose build --build-arg CLAUDE_CODE_VERSION=2.2.0
```

### Run with verbose logging

```bash
RC_VERBOSE=true docker compose up
```

### Use worktree spawn mode

```bash
RC_SPAWN=worktree docker compose up -d
```

### View firewall rules (requires NET_ADMIN — only works during startup)

The main process drops NET_ADMIN after firewall init. To inspect rules, use a separate container:

```bash
docker run --rm --cap-add NET_ADMIN --network container:sealpod \
  debian:bookworm-slim iptables -L -n
```

## Contributing

Contributions welcome. Please:
1. Fork the repo
2. Create a feature branch
3. Ensure `docker compose build` succeeds
4. Open a PR with a clear description

## Sources

- [Claude Code Remote Control docs](https://code.claude.com/docs/en/remote-control)
- [Claude Code devcontainer reference](https://github.com/anthropics/claude-code/tree/main/.devcontainer)
- [CIS Docker Benchmark v1.7.0](https://www.cisecurity.org/benchmark/docker)
- [OWASP LLM Top 10 2025](https://genai.owasp.org/llmrisk/llm01-prompt-injection/)
