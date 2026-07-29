# docker-agent

[简体中文](README.md) | **English**

Run Codex CLI or Claude Code in one Docker image. The container mounts the
current project directory, so agent edits land directly on host files. For a
Git checkout, the unified launcher also manages Git metadata, build caches,
optional worktrees, and clipboard forwarding. The original `docker-codex`
command remains compatible.

## Quick start

Prerequisites are Git, Bash 3.2+, and a running Docker daemon. Codex requires
`${CODEX_HOME:-$HOME/.codex}` on the host. Reusing a Claude subscription
requires a completed Claude Code login on a Linux or WSL host.

```bash
# Build the shared image once, from this source checkout
docker build -t docker-agent:local .

# Install docker-agent, docker-codex, and docker-claude
sudo ./install.sh

# Interactively create a custom-endpoint profile
docker-claude --create-profile

# Launch from any project directory (no Git repository required)
cd /path/to/your-project
docker-agent codex
docker-agent claude
docker-agent claude --profile deepseek
```

`docker-codex` is equivalent to `docker-agent codex`, and `docker-claude` is
equivalent to `docker-agent claude`. Without `sudo`, run
`./install.sh --prefix "$HOME/.local"` to install under `$HOME/.local/bin`.

In an interactive terminal, `docker-agent claude` shows connection choices for
an official subscription/OAuth login, an official API key, or a custom
endpoint. The custom choice opens a second, name-sorted profile menu. Scripts
and CI without a TTY must use one of the explicit connection selectors.

> [!WARNING]
> Codex runs with `--yolo`; Claude Code runs with
> `--dangerously-skip-permissions`. The selected agent receives the current
> project directory, required Git metadata, and explicitly selected credentials. Use
> this only with projects you trust.

Common commands:

```bash
docker-agent codex -- review "review the current branch"
docker-agent claude --create-profile
docker-agent claude --official-subscription
docker-agent claude --official-api
docker-agent claude --profile deepseek -- --version
docker-agent codex --isolated issue-123
docker-agent claude --bind /path/to/fixtures:ro --profile deepseek
docker-agent codex --pat-path ~/.local/share/docker-agent/pat/github-x
```

## Command-line options

Shared options:

```text
--build
    Build docker-agent:local before launching; requires the source checkout.

--image IMAGE
    Use another image instead of docker-agent:local.

--isolated NAME
    In a Git checkout, create and use a retained codex/NAME branch and worktree.

--bind PATH[:ro]
    Mount an absolute directory at the same path; repeatable, :ro is read-only.

--pat TOKEN
    Provide a Git token directly; it enters shell history, so prefer --pat-path.

--pat-path FILE
    Mount a Git token file read-only at /codex-credentials/pat.

--disable-clipboard
    Do not forward host display sockets and clipboard access.

--help, -h
    Print help.
```

Arguments after `--` are passed unchanged to Codex or Claude Code.

Claude connection and profile options:

```text
--create-profile
    Interactively create a custom-endpoint profile; must be used alone.

--official-subscription
    On Linux/WSL, reuse the host Claude Code .credentials.json.

--official-api
    Use ANTHROPIC_API_KEY from the protected official-api.env profile.

--profile NAME
    Use the protected NAME.env custom-endpoint profile.
```

See [Claude Code integration](docs/en/claude.md) for profile creation, OAuth
mounting, state isolation, UTC/locale policy, and security details.

## Docs

- [Claude Code integration](docs/en/claude.md): menus, profiles, OAuth, state, cleanup.
- [Checkout and worktrees](docs/en/worktree.md): mount rules, `--isolated`, `--bind`.
- [Authentication and credentials](docs/en/credentials.md): Codex home, Claude credentials, Git push.
- [Image environment and build caches](docs/en/environment.md): toolchain, locale, cache volumes.
- [Clipboard forwarding](docs/en/clipboard.md): image paste and `--disable-clipboard`.
- [Platform notes](docs/en/platforms.md): Linux, WSL2, and macOS differences.
- [Security boundary](docs/en/security.md): container privileges, disabled approvals, credential visibility.
- [Development and verification](docs/en/development.md): tests and build versions.
