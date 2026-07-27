# docker-codex

[简体中文](README.md) | **English**

A launcher script that runs Codex CLI inside a Docker container. The container mounts your current Git checkout, so Codex edits your actual files on the host; `~/.codex` is shared, so your login and config carry over. The rest of your system stays out of reach, which makes `--yolo` a reasonable default.

## Quick start

Prerequisites: Git, Bash 3.2+, a running Docker daemon, and an existing `~/.codex` on the host (you get one by using Codex CLI locally).

```bash
# build the image, once
cd /absolute/path/to/docker-codex
./docker-codex --build -- --version

# install the launcher
sudo install -m 0755 ./docker-codex /usr/local/bin/docker-codex

# cd into any project and go
cd /path/to/your-project
docker-codex
```

After that it's the same Codex you already know, just containerized.

No `sudo`? Install into the user directory instead: `install -m 0755 ./docker-codex "$HOME/.local/bin/docker-codex"` (and put `~/.local/bin` on your `PATH`). Rebuilding the image has to happen from this repository via `./docker-codex --build`; rerun `install` whenever the launcher script changes.

Runs on Linux, WSL2, and macOS via Docker Desktop (including Apple Silicon).

> [!WARNING]
> `--yolo` is on by default, and the current checkout, the required Git metadata, and the host Codex home are mounted read-write. Only use this on projects you trust. The container process also gets `--disable apps`, which affects only that process and leaves the shared config alone.

A few common extras:

```bash
docker-codex -- review "review the current branch"   # everything after -- goes to Codex as-is
docker-codex --isolated issue-123                    # work in an isolated worktree → docs/en/worktree.md
docker-codex --bind /path/to/fixtures:ro --          # mount an extra read-only dir → docs/en/worktree.md
docker-codex --pat-path ~/.local/share/docker-codex/pat/github-x  # git push from the container → docs/en/credentials.md
```

## Options

```text
--build
    Build the image before launching.

--image IMAGE
    Use another image reference instead of docker-codex:local.

--isolated NAME
    Create and use retained branch codex/NAME and its host worktree.

--bind PATH[:ro]
    Mount an absolute directory at the same path; repeat as needed.

--pat TOKEN
    Provide a Git access token directly; stored under the data home with
    mode 600 and mounted read-only at /codex-credentials/pat. The token
    appears in shell history; prefer --pat-path.

--pat-path FILE
    Mount a token file read-only at /codex-credentials/pat.
    DOCKER_CODEX_PAT_PATH sets the default.

--disable-clipboard
    Do not forward the host clipboard (display sockets) into the
    container.

--help, -h
    Print command help.
```

To pin different tool versions at build time, use `--build-arg` — see [Development & verification](docs/en/development.md).

## Docs

- [Checkout and worktrees](docs/en/worktree.md): mount rules, `--isolated`, `--bind`.
- [Authentication and credentials](docs/en/credentials.md): how Codex home is shared, and how to `git push` from the container.
- [Image environment and build caches](docs/en/environment.md): what's in the image, how the cache volumes work.
- [Clipboard forwarding](docs/en/clipboard.md): how image paste works, and `--disable-clipboard`.
- [Platform notes](docs/en/platforms.md): WSL2 and macOS caveats.
- [Security boundary](docs/en/security.md): what the container may do, and what the launcher never mounts.
- [Development and verification](docs/en/development.md): running tests, overriding build versions.
