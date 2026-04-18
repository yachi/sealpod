# Sealpod

## Git

- **NEVER commit to main** — branch protection requires gitleaks + shellcheck to pass. Always feature branch + PR.
- User runs `git push` manually (blocked by policy).
- Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`

## OAuth Gotchas

- Token endpoint is `platform.claude.com/v1/oauth/token` — NOT `console.anthropic.com` (migrated Dec 2025, old endpoint returns Cloudflare 500s)
- User-Agent must be `axios/1.9.0` — Cloudflare Bot Management blocks `claude-code/*`
- 429 rate limits are per-account, shared across endpoints. Wait 5+ minutes. Don't retry rapidly.
- Token refresh can lose scopes (anthropics/claude-code#34785). Always pre-flight refresh before launching remote-control.

## Channels + Remote Control

`claude remote-control` (server mode) rejects `--channels` — `bridgeMain.ts` has its own arg parser that exits on unknown flags. Use `claude --rc --channels` instead (both are Commander.js options in `main.tsx`). Requires `tty: true` + `stdin_open: true` for Ink TUI in Docker.

Trade-off: `--rc` = 1 session/process (no `--spawn`/`--capacity`). Multiple containers for concurrency.

## Telegram in Headless Docker

- `access.json` is pre-seedable — plain JSON, no crypto. Format: `{"dmPolicy":"allowlist","allowFrom":["NUMERIC_ID"],"groups":{},"pending":{}}`
- Plugin auto-resolves from `enabledPlugins` + `extraKnownMarketplaces` in settings.json. "plugin not installed" warning at startup is cosmetic.
- Get user ID without third-party bots: DM your bot, then `curl -s "https://api.telegram.org/bot$TOKEN/getUpdates" | jq '.result[0].message.from.id'` (updates consumed per call — send message first)
- Permission relay has no timeout — session hangs forever if nobody answers. Default to `bypassPermissions` (container is the boundary).

## Bun in Docker

- `unzip` required in bookworm-slim — add to main apt-get layer
- Pin version: `BUN_INSTALL=/usr/local BUN_VERSION=v${BUN_VERSION}` (same ARG pattern as `CLAUDE_CODE_VERSION`)
- v2.1.88 was yanked from npm (leaked source). Always `npm view` before pinning a version.

## Credentials

- Write with `mode: 0o600` and atomic tmp+rename (see `.credentials.json` pattern in entrypoint.sh)
- `TELEGRAM_BOT_TOKEN` is a secret — chmod 600, never log
- SC2016 shellcheck info in entrypoint.sh is intentional (single-quoted `gosu node node -e` blocks)

## Workflow

Follows the global `auto run` pipeline in `~/.claude/CLAUDE.md`. Sealpod-specific additions:
- Research agents should cover CIS Docker compliance, shell injection, OAuth/network, and supply chain angles
- Validation step includes `shellcheck` on all `.sh` files and JSON parse on config files
