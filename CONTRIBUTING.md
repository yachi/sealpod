# Contributing

Contributions are welcome. This document covers how to report bugs, submit changes, and what's expected.

## Reporting Bugs

Open a [GitHub Issue](../../issues/new) with:

- Host OS and Docker version (`docker version`)
- Claude Code version (`CLAUDE_CODE_VERSION` in your `.env`)
- Relevant log output (`docker compose logs --tail 100`)
- Steps to reproduce

## Submitting Changes

1. Fork the repository and create a branch from `main`.
2. Make your changes and verify they work locally (see Development Setup below).
3. Commit with a sign-off (see DCO below).
4. Open a pull request with a clear description of what changed and why.

Keep PRs focused. One logical change per PR makes review faster.

## Development Setup

Requirements:

- Docker Engine 25.0.2+ and Docker Compose v2
- `shellcheck` (for shell script linting)

Setup:

```bash
cp .env.example .env
# Edit .env as needed
docker compose build
docker compose run --rm sealpod sealpod-auth
```

Before opening a PR, confirm the build passes:

```bash
docker compose build
```

## Code Style

**Shell scripts:** must pass `shellcheck` with no warnings.

```bash
shellcheck entrypoint.sh init-firewall.sh healthcheck.sh sealpod-auth.sh
```

**Dockerfile:** follow standard best practices -- layer caching, minimal image size, pinned base image digests where feasible, no secrets in layers.

**Commit messages:** use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `chore:`, etc.).

## Developer Certificate of Origin (DCO)

All commits must include a DCO sign-off. By signing off, you certify that you wrote the code or have the right to contribute it under the project's license. See https://developercertificate.org/ for the full text.

Sign off using the `-s` flag:

```bash
git commit -s -m "fix: correct iptables rule ordering"
```

This adds a `Signed-off-by: Your Name <your@email.com>` line to the commit. PRs without sign-off on every commit will not be merged.

## License

By contributing, you agree your contributions are licensed under the [MIT License](LICENSE).
