# Image environment and build caches

This page describes the toolchain shipped in the image, the environment notes
file shown to the in-container agent, and the build-cache volume behavior.
Read it when you need to know what is preinstalled, when changing the
toolchain, or when investigating cache usage.

## Image toolchain

The image uses Debian 13 slim and installs Node.js 24.19.0 LTS from the
official nodejs.org linux-x64/linux-arm64 archive after checking it against
the release's `SHASUMS256.txt`. Go 1.26.6 is installed from the official
linux-amd64/linux-arm64 archive with a pinned SHA-256 checksum. The image also
contains pnpm, Rust stable (with rustfmt and clippy), Codex CLI, Git, Python 3
(pip and venv), common native build dependencies, Claude Code, Kimi Code,
Cursor Agent (self-contained under `/opt/cursor-agent`), Docker CLI, Buildx,
Compose, and shell
utilities useful during agentic development. It ships Docker clients only,
not `dockerd`; they can reach the host daemon only when `--host-docker`
explicitly mounts its Unix socket.

Docker gives a container only a bare `TERM=xterm`, capping it at 8 colors and
costing agent TUIs the background rendering of elements such as the input box.
With a TTY the launcher forwards the host `TERM` and `COLORTERM`, and when the
image has no terminfo entry for that terminal the entrypoint says so and falls
back to `xterm-256color` instead of breaking curses or dropping to 8 colors.
The image installs `ncurses-term` for broad coverage, though a few newer
terminals such as kitty and ghostty still rely on that fallback. An explicit
`--env TERM=...` overrides the forwarded value.

The image generates the `en_US.UTF-8`
locale. An `/etc/profile.d` entry keeps Cargo, Go, and pnpm on PATH for login
shells.
The image links Rust builds with mold by default via `RUSTFLAGS` (a project's
own rustflags or `docker run -e RUSTFLAGS=...` override it), and ships
sccache for opt-in reuse of dependency builds across worktrees:

```bash
RUSTC_WRAPPER=sccache SCCACHE_DIR=/codex-cache/sccache cargo build
```

## Environment notes for the in-container agent

The image ships `/usr/local/share/docker-agent/agent-notes.md`, which
records key environment facts: whether push credentials are configured, the
default mold linker, opt-in sccache usage, the `CARGO_TARGET_DIR` location,
and the persistent Go cache paths. It contains no response-language,
personality, endpoint, or model instruction.

Each agent has a different injection channel. Codex uses
`-c developer_instructions=...` (which appends; `model_instructions_file`
replaces the built-in instructions and is therefore unsuitable), Claude uses
`--append-system-prompt-file`, and Kimi Code, having no such flag, reads the
notes from `$HOME/.agents/AGENTS.md` written inside the container. Cursor Agent
has no way to append to its system prompt and so never receives these notes,
though it does read the project's own `AGENTS.md` and `.cursor/rules`. Codex
`-c` overrides passed after `--` take precedence.

Every one of these channels is a coupling to an upstream CLI, and they tend to
break silently: Codex ignores unrecognized `-c` keys without an error, so when
`user_instructions` was removed in 0.147.0 the notes stopped arriving
unnoticed. `tests/image_test.bash` therefore asserts each channel against the
pinned builds.

Claude alone receives UTC and `en_US.UTF-8`; this does not change Codex or
ordinary container commands and does not force Claude to answer in English.
See [Claude Code integration](claude.md) for the complete policy.

## Build caches

Each Git common directory or plain project directory gets a stable Docker
volume named like:

```text
docker-codex-cache-<git-path-hash>
```

A plain directory hashes the synthetic absolute path
`<current-directory>/.git`, so running `git init` there later does not change
the volume name. The volume backs `/codex-cache`. Cargo registry/git downloads,
Go modules, Go build results, pnpm files, and general XDG caches stay inside
Docker's Linux filesystem and are shared across all worktrees of one
repository, while Cargo build artifacts are isolated per worktree under
`/codex-cache/cargo-targets/<worktree-name>-<path-hash>` so build.rs
fingerprints cannot leak between worktrees. This is particularly important
for Rust, Go, and Node performance on macOS Docker Desktop.

List or remove caches explicitly:

```bash
docker volume ls --filter name=docker-codex-cache-
docker volume rm docker-codex-cache-<git-path-hash>
```

Removing a cache discards only rebuildable dependency/build data.

---

Back to [README](../../README.en.md)
