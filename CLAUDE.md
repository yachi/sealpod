# Sealpod — Project Instructions

## What This Is

Security-hardened Docker wrapper for Claude Code Remote Control. Outbound-only HTTPS polling, read-only rootfs, capability drop, custom OAuth PKCE auth (`sealpod-auth.sh`).

## Git Workflow

- **NEVER commit to main** — branch protection with 2 required status checks (gitleaks, shellcheck). Always create a feature branch + PR.
- Remote is SSH: `git@github.com:yachi/sealpod.git`
- Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`
- User must run `git push` manually (blocked by policy)

## Security Model

- Every outbound path except HTTPS/443 must remain blocked. Test firewall after any network change.
- DNS restricted to Docker internal resolver (127.0.0.11)
- Read-only rootfs with noexec tmpfs for `/tmp`, `.cache`, `.npm`
- Non-root execution via `capsh --user=node` after firewall init. Privilege chain: root (firewall) → gosu node (file setup) → capsh drop+exec (runtime)
- `no-new-privileges:true` in docker-compose prevents re-escalation
- Credential files must be written with `mode: 0o600` and use atomic tmp+rename pattern (see `.credentials.json` handling in entrypoint.sh)
- `TELEGRAM_BOT_TOKEN` is a secret — write with chmod 600, never log

## OAuth Reference

Verified 2026-03-29. Anthropic migrated OAuth from `console.anthropic.com` to `platform.claude.com` (Dec 2025). The old endpoint returns Cloudflare 500s.

- Auth endpoint: `https://claude.ai/oauth/authorize`
- Token endpoint: `https://platform.claude.com/v1/oauth/token` (NOT console.anthropic.com)
- Client ID: `9d1c250a-e61b-44d9-88ed-5944d1962f5e`
- Redirect URI: `https://platform.claude.com/oauth/code/callback`
- Scopes: `user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload`
- User-Agent must be `axios/1.9.0` — Cloudflare Bot Management blocks `claude-code/*`
- Known bug: token refresh can lose scopes (anthropics/claude-code#34785)
- 429 rate limits are per-account, shared across all endpoints. Wait time can be 5+ minutes. Retry with exponential backoff.

## Claude Code Channels + Remote Control

`claude remote-control` (server mode) does NOT accept `--channels`. Verified via leaked source code analysis (v2.1.88): `bridgeMain.ts` has its own `parseArgs()` that rejects unknown flags — the fast-path in `cli.tsx` intercepts before Commander.js loads.

**Workaround:** Use `claude --rc --channels plugin:name@marketplace` instead. Both are Commander.js options on the same program in `main.tsx`. Requires `tty: true` + `stdin_open: true` in docker-compose.yml for the Ink TUI.

**Trade-off:** `--rc` mode = 1 session per process (no `--spawn`/`--capacity`). For concurrent sessions, run multiple container instances.

**Permission modes with Telegram:**
- `bypassPermissions` (default) — container is the security boundary, no prompts. Matches original server mode behavior.
- `default` — all tool calls prompt, forwarded to Telegram via permission relay. Risk: session hangs indefinitely if no one answers (no timeout).
- `acceptEdits` — auto-approves file edits, still prompts for Bash. Unusably slow for unattended work.

## Telegram Plugin in Headless Docker

- **Bun runtime required** — plugin runs on grammy/Bun, not Node
- **access.json pre-seedable** — plain JSON, no crypto verification. Server re-reads on every message. Format: `{"dmPolicy":"allowlist","allowFrom":["NUMERIC_USER_ID"],"groups":{},"pending":{}}`
- **Plugin auto-resolves** from `enabledPlugins` + `extraKnownMarketplaces` in settings.json — the "plugin not installed" warning at startup is cosmetic and resolves itself
- **No `claude plugin install` needed** in entrypoint — marketplace config handles it
- **Get Telegram user ID** without third-party bots: DM your own bot, then call `getUpdates` — `curl -s "https://api.telegram.org/bot$TOKEN/getUpdates" | jq '.result[0].message.from.id'`. Updates are consumed by each `getUpdates` call, so send a message immediately before running.
- **`TELEGRAM_USER_ID` must be numeric** — validated in entrypoint. `allowFrom` values are strings in JSON.

## Playwright / Browser Hardening

Chromium's namespace sandbox cannot run under default Docker seccomp. Sealpod uses a custom seccomp profile (`chrome-seccomp.json`) that allows `CLONE_NEWUSER` + `CLONE_NEWPID` only (blocks NEWNS/NEWNET/NEWUTS/NEWIPC/NEWCGROUP). This eliminates the need for `--no-sandbox`.

Key constraints:
- Browser system deps installed at build time (needs root), browser binary at runtime to separate volume
- `PLAYWRIGHT_BROWSERS_PATH=/home/node/.playwright-browsers` persists across restarts
- `file://` protocol blocked in `playwright-cli.config.json`
- `/dev/shm` needs 512MB tmpfs for Chromium (was 64MB default)
- See `ROADMAP.md` for P0/P1/P2 hardening checklist

## Bun in Docker (bookworm-slim)

- `unzip` required (not in slim) — merge into main `apt-get` layer to avoid redundant `apt-get update`
- Pin version via `BUN_VERSION` ARG, same pattern as `CLAUDE_CODE_VERSION`
- Install to `/usr/local` for PATH: `BUN_INSTALL=/usr/local BUN_VERSION=v${BUN_VERSION}`
- v2.1.88 was yanked from npm (leaked source). Always verify version exists before pinning.

## Entrypoint Architecture

Phases run in order, each with specific privilege level:
1. **Phase 1** (root): Firewall setup via `init-firewall.sh`
2. **Phase 0** (gosu node): Workspace trust, mktemp hooks, plugin marketplace, Telegram access.json
3. **Pre-flight** (gosu node): OAuth token refresh (always refresh — don't trust `expiresAt`)
4. **Phase 2** (capsh drop): Build and exec `claude remote-control` or `claude --rc --channels`

Passthrough mode allows only `claude` and `sealpod-auth` commands — all else rejected.

## CI

- shellcheck (severity: warning) — SC2016 info in entrypoint.sh is intentional (single-quoted `gosu node node -e` blocks)
- gitleaks — never commit `.env`, credentials, or tokens
- No automated test suite — verification is manual (`docker compose build`, `docker compose up -d`, check logs)
- No `docker compose build` in CI yet (see ROADMAP.md)

## PR History

| PR | What |
|----|------|
| #3 | OAuth endpoint migration (console→platform.claude.com) + sealpod-auth hardening |
| #4 | 11 doc/code fixes + pre-loaded skills (deep-research, playwright-cli) |
| #5 | Roadmap: Playwright security hardening plan (13 findings) |
| #6 | Playwright browser deps fix |
| #7 | Code review fixes missed in #6 merge |
| #8 | @playwright/cli pin to 0.1.1 |
| #9 | Pre-flight OAuth token refresh before remote-control launch |
| #10 | P0 browser hardening — feature flag, seccomp, resource limits |
| #11 | Playwright official seccomp profile, default browser true |
| #12 | Telegram channel integration for remote session control |
