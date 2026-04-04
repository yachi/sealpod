# Sealpod — Project Instructions

## What This Is

Security-hardened Docker wrapper for Claude Code Remote Control. Outbound-only HTTPS polling, read-only rootfs, capability drop, custom OAuth PKCE auth (`sealpod-auth.sh`).

## Git Workflow

- **NEVER commit to main** — branch protection with required status checks (gitleaks, shellcheck). Always create a feature branch + PR.
- Remote is SSH: `git@github.com:yachi/sealpod.git`
- Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`

## Security Model

- Every outbound path except HTTPS/443 must remain blocked
- DNS restricted to Docker internal resolver (127.0.0.11)
- Read-only rootfs with noexec tmpfs
- Non-root execution via `capsh --user=node` after firewall init
- Test auth flow after any OAuth changes

## OAuth Reference

- Auth endpoint: `https://claude.ai/oauth/authorize`
- Token endpoint: `https://platform.claude.com/v1/oauth/token`
- Client ID: `9d1c250a-e61b-44d9-88ed-5944d1962f5e`
- Scopes: `user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload`
- Known bug: token refresh can lose scopes (anthropics/claude-code#34785)

## Claude Code Channels + Remote Control

`claude remote-control` (server mode) does NOT accept `--channels`. Verified via source code analysis (v2.1.88): `bridgeMain.ts` has its own `parseArgs()` that rejects unknown flags — the fast-path in `cli.tsx` intercepts before Commander.js loads.

**Workaround:** Use `claude --rc --channels plugin:name@marketplace` instead. Both are Commander.js options on the same program in `main.tsx`. Requires `tty: true` + `stdin_open: true` in docker-compose.yml for the Ink TUI.

**Trade-off:** `--rc` mode = 1 session per process (no `--spawn`/`--capacity`). For concurrent sessions, run multiple container instances.

## Telegram Plugin in Headless Docker

- **Bun runtime required** — plugin runs on grammy/Bun, not Node
- **access.json pre-seedable** — plain JSON, no crypto. Format: `{"dmPolicy":"allowlist","allowFrom":["NUMERIC_USER_ID"],"groups":{},"pending":{}}`
- **Plugin auto-resolves** from `enabledPlugins` + `extraKnownMarketplaces` in settings.json — the "plugin not installed" warning at startup is cosmetic
- **No `claude plugin install` needed** in entrypoint — marketplace config handles it
- **Get Telegram user ID** without third-party bots: DM your own bot, then `curl -s "https://api.telegram.org/bot$TOKEN/getUpdates" | jq '.result[0].message.from.id'`

## Bun in Docker (bookworm-slim)

- `unzip` required (not in slim) — merge into main apt-get layer to avoid redundant `apt-get update`
- Pin version via `BUN_VERSION` ARG, same pattern as `CLAUDE_CODE_VERSION`
- Install to `/usr/local` for PATH: `BUN_INSTALL=/usr/local BUN_VERSION=v${BUN_VERSION}`

## CI

- shellcheck (severity: warning) — SC2016 info in entrypoint.sh is intentional (single-quoted `gosu node node -e` blocks)
- gitleaks — never commit `.env`, credentials, or tokens
- No automated test suite — verification is manual (`docker compose build`, `docker compose up -d`, check logs)
