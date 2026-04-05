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

This is how the user works on this project. Follow this pattern unless told otherwise.

### How to trigger

**Full auto-run:**

```
auto run <task>
```

When the user says `auto run <task>`, execute the entire pipeline autonomously:
1. `/deep-research` with convergence loops until no new findings
2. Save findings to memory
3. Draft code to `.goal/` — DO NOT touch source files yet
4. `/simplify` review (3 agents: reuse, quality, efficiency)
5. Fix review findings in the draft
6. Create feature branch, spawn implementation agents (`bypassPermissions`)
7. Validate (shellcheck, JSON parse, git diff review)
8. Commit on feature branch
9. Tell user to push, then create PR via GitHub MCP

Stop and ask only if: a finding changes the scope significantly, or a validation fails after retry.

**Individual phases** — the user can also trigger phases separately:

| User says | Phase triggered |
|-----------|----------------|
| `loop until no new findings -> /deep-research <topic>` | Phase 1: Research audit on `<topic>` |
| `loop ... -> /deep-research draft <priority> code first, dont change code yet, review with /simplify` | Phase 2: Draft code + review |
| `/st agents go` or `/st opus agents go` | Phase 3: Implement the approved draft |
| `remember first` or `remember` | Save findings to memory before proceeding |
| `pushed` | User pushed the branch — create PR via GitHub MCP |
| `ok` or `go` | Approve and proceed with the next step |

When the user combines phases (e.g., "research, draft, and implement X"), run all three sequentially. When they say "loop until no new findings", iterate convergence rounds until zero new gaps surface.

### Phase 1: Deep Research Audit

```
loop until no new findings -> /deep-research <task description>
```

- Spawn 4+ specialized research agents in parallel (background mode) covering orthogonal domains (e.g., CIS compliance, shell injection, OAuth/network, supply chain)
- Main thread reads source files directly while agents research external sources
- WebSearch for CVEs, standards (NIST, OWASP, CIS), RFC compliance
- Convergence loop: cross-validate agent findings, correct errors (agents get things wrong — always verify), merge into structured report
- Save findings to memory (`security_audit_findings.md` or equivalent) before moving on

### Phase 2: Draft Code (no changes yet)

```
loop until no new findings -> /deep-research draft <priority> code first, dont change code yet, review with /simplify
```

- Research correct values first (checksums, flag values, action SHAs, version compatibility)
- Write complete draft to `.goal/<name>-draft.md` with exact diffs, rationale, and verification plan
- Run `/simplify` review: 3 parallel agents (reuse, quality, efficiency) critique the draft
- Fix all review findings and produce a v2 draft
- DO NOT touch source files until user approves

### Phase 3: Implement via Subagents

```
/st agents go
```

- Create feature branch (`fix/<name>` or `feat/<name>`) — NEVER commit to main
- Spawn parallel implementation agents (one per independent file group), all with `bypassPermissions` mode
- Each agent prompt includes "DO NOT commit"
- After all agents complete: validate (shellcheck, JSON parse, git diff), then commit on feature branch
- User runs `git push` manually, then Claude creates PR via GitHub MCP

### Key Patterns Observed

- **Agent errors are common** — always verify agent output (e.g., cap_sys_ptrace finding was wrong, mask calculation was wrong). Run your own validation.
- **Research agents in background, read files in foreground** — don't duplicate work
- **SHA-pin everything** — GitHub Actions, npm packages. The Trivy supply chain attack (March 2026) proved tags are mutable.
- **User commands are terse** — "ok", "pushed", "remnember first". Act on minimal input without asking for clarification.
- **Loop structure**: research → draft → review → fix → implement → validate → commit → PR. Each phase produces an artifact before moving to the next.
- **Memory before implementation** — save audit findings/decisions to memory files so future sessions have context
