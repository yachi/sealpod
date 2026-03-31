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

## Other

- [ ] **DCO enforcement in CI**: CONTRIBUTING.md requires DCO sign-off but CI doesn't enforce it. Add a `DCO` check job.
- [ ] **Docker build in CI**: CI runs shellcheck and gitleaks but doesn't verify `docker compose build`. Add a build smoke test.
- [ ] **`DEVCONTAINER=true` audit**: Env var is set but not in Claude Code's [official env vars](https://code.claude.com/docs/en/env-vars). Evaluate replacing with `IS_SANDBOX=1` per [anthropics/claude-code#927](https://github.com/anthropics/claude-code/issues/927).
