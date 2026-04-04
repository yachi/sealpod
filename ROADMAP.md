# Sealpod Roadmap

## Playwright Security Hardening

Playwright browser automation is installed but **gated behind mitigations** before production use. See the [security audit](https://github.com/yachi/sealpod/pull/4) for full details.

### P0 — Must-have before enabling browser

- [x] **Feature flag**: `SEALPOD_BROWSER_ENABLED` (default on). Skill not installed when disabled; clean removal on toggle-off.
- [x] **Custom seccomp profile**: `chrome-seccomp.json` allows `CLONE_NEWUSER`+`CLONE_NEWPID` only (blocks NEWNS/NEWNET/NEWUTS/NEWIPC/NEWCGROUP). `--no-sandbox` removed.
- [x] **Increase tmpfs sizes**: `/tmp` → 512MB, `.cache` → 256MB, `/dev/shm` → 512MB (new). `--disable-dev-shm-usage` removed.
- [x] **Block `file://` protocol**: `network.blockedOrigins: ["file://*"]` in `playwright-cli.config.json`.
- [x] **Increase resource limits when browser enabled**: Configurable via `SEALPOD_MEM_LIMIT` (default 2g) and `SEALPOD_PIDS_LIMIT` (default 512).
- [ ] **Single concurrent browser instance**: Lock file or semaphore preventing multiple browser sessions per container.

### P1 — Should-have

- [ ] **Content sanitization layer**: Strip hidden text (`display:none`, `visibility:hidden`), HTML comments, `<script>` contents, and `<meta>` tags from Playwright output before returning to Claude's context. Limit returned text to 50KB.
- [ ] **Chromium hardening flags**: `--disable-webrtc`, `--disable-webgl`, `--disable-extensions`, `--disable-plugins`, `--disable-background-networking`, `--disable-sync`, `--js-flags='--max-old-space-size=256'`.
- [ ] **Isolated browser sessions**: No persistent cookies/storage across invocations. Each Playwright session starts with a clean profile.
- [ ] **Domain allowlist**: Add `PLAYWRIGHT_ALLOWED_DOMAINS` env var as defense-in-depth (bypassable — not primary control).

### P2 — Accepted residual risk

- **Prompt injection via rendered web content**: Inherent to any AI-browser system. Anthropic and OpenAI confirm mitigations reduce but don't eliminate this.
- **Chromium CVE surface**: 32 CVEs in 2026 (avg CVSS 7.9). Mitigated by container sandbox + browser sandbox (after seccomp fix). Zero-days will always exist.
- **HTTPS exfiltration**: Port 443 is open by design. WebSocket over TLS adds persistent channels but the risk was already accepted for WebFetch/curl.

## Telegram Channel Integration

**User story**: As a developer, I want to control my sealpod remote-control session from Telegram on my phone, so I can send tasks, receive replies, and approve/deny tool permissions without opening claude.ai or a browser.

### Background

Claude Code Channels (v2.1.80+, research preview) natively bridge Telegram into a running session via an official MCP plugin (`plugin:telegram@claude-plugins-official`). The plugin uses outbound HTTPS polling (compatible with sealpod's firewall), sender allowlisting, and permission relay.

**Critical finding from source code analysis (v2.1.88):** `claude remote-control` (server mode) does NOT accept `--channels` — `bridgeMain.ts` has its own `parseArgs()` that rejects unknown flags. The workaround is `claude --rc --channels`, which runs both as Commander.js options on the same program. This means switching from server mode to interactive+remote-control mode.

| Launch path | `--channels`? | `--spawn`/`--capacity`? |
|---|---|---|
| `claude remote-control --channels ...` | **No** (rejected) | Yes |
| `claude --rc --channels ...` | **Yes** | No (1 session/process) |

### Tasks

- [x] **Bump Claude Code to ≥2.1.80**: Update `CLAUDE_CODE_VERSION` to 2.1.88 in `.env.example` and `Dockerfile`.
- [x] **Install Bun in Dockerfile**: Official Telegram plugin requires Bun runtime (~33MB). Installed to `/usr/local/bin/bun`.
- [x] **Add `TELEGRAM_BOT_TOKEN` env var**: New optional env var in `.env.example`. When set, enables Telegram channel.
- [x] **Switch entrypoint from server mode to `--rc` mode**: Phase 2 conditionally uses `claude --rc --channels` (with token) or `claude remote-control` (without). Backward-compatible.
- [x] **Enable `claude-plugins-official` marketplace**: Added in Phase 0 settings.json setup.
- [x] **Pre-seed `access.json`**: `TELEGRAM_USER_ID` env var writes allowlist-mode access.json at startup, skipping interactive pairing.
- [x] **Permission mode**: `SEALPOD_PERMISSION_MODE` env var (default `bypassPermissions`). Container is the security boundary.
- [x] **TTY allocation**: `tty: true` + `stdin_open: true` in docker-compose.yml for Ink TUI in `--rc` mode.
- [ ] **Handle `--spawn`/`--capacity` loss**: `--rc` mode supports 1 session per process. Document that concurrent sessions require multiple container instances instead of `--spawn worktree`.

### Resolved questions

- **`--rc` headless in Docker**: Yes — `tty: true` + `stdin_open: true` gives the Ink TUI a PTY. Renders into the void in detached mode. Session stays alive. (Ref: anthropics/claude-code#30447, #23874)
- **Pre-seed `access.json`**: Yes — plain JSON, no crypto verification. Server re-reads on every message. `TELEGRAM_USER_ID` writes `{"dmPolicy":"allowlist","allowFrom":["<id>"]}` at startup.
- **Permission mode**: Default `bypassPermissions` — container is the security boundary (read-only FS, cap drop, outbound-only firewall). Matches original `claude remote-control` server mode behavior. Override via `SEALPOD_PERMISSION_MODE=default` for Telegram permission relay.

## Other

- [ ] **DCO enforcement in CI**: CONTRIBUTING.md requires DCO sign-off but CI doesn't enforce it. Add a `DCO` check job.
- [ ] **Docker build in CI**: CI runs shellcheck and gitleaks but doesn't verify `docker compose build`. Add a build smoke test.
- [ ] **`DEVCONTAINER=true` audit**: Env var is set but not in Claude Code's [official env vars](https://code.claude.com/docs/en/env-vars). Evaluate replacing with `IS_SANDBOX=1` per [anthropics/claude-code#927](https://github.com/anthropics/claude-code/issues/927).
