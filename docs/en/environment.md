# Image environment and build caches

This page describes the toolchain shipped in the image, the environment notes
file shown to the in-container agent, and the build-cache volume behavior.
Read it when you need to know what is preinstalled, when changing the
toolchain, or when investigating cache usage.

## Image toolchain

The image uses Debian 13 slim and installs Node.js 24.18.0 LTS from the
official nodejs.org linux-x64/linux-arm64 archive after checking it against
the release's `SHASUMS256.txt`. It also contains pnpm, Rust stable (with
rustfmt and clippy), Codex CLI, Git, Python 3 (pip and venv), common native
build dependencies, and shell utilities useful during agentic development.
An `/etc/profile.d` entry keeps Cargo and pnpm on PATH for login shells.
The image links Rust builds with mold by default via `RUSTFLAGS` (a project's
own rustflags or `docker run -e RUSTFLAGS=...` override it), and ships
sccache for opt-in reuse of dependency builds across worktrees:

```bash
RUSTC_WRAPPER=sccache SCCACHE_DIR=/codex-cache/sccache cargo build
```

## Environment notes for the in-container agent

The image ships `/usr/local/share/docker-codex/agent-notes.md`, which
records key environment facts: whether push credentials are configured, the
default mold linker, opt-in sccache usage, the `CARGO_TARGET_DIR` location,
and so on. The entrypoint injects it automatically via
`-c user_instructions=...` when starting `codex`, so the in-container agent
knows the environment without being told; `-c` overrides passed by the
caller after `--` take precedence. The file is versioned with the image —
update it whenever the toolchain facts change.

## Build caches

Each Git common directory gets a stable Docker volume named like:

```text
docker-codex-cache-<git-path-hash>
```

The volume backs `/codex-cache`. Cargo registry/git download caches, pnpm
files, and general XDG caches stay inside Docker's Linux filesystem and are
shared across all worktrees of one repository, while Cargo build artifacts
are isolated per worktree under
`/codex-cache/cargo-targets/<worktree-name>-<path-hash>` so build.rs
fingerprints cannot leak between worktrees. This is particularly important
for Rust and Node performance on macOS Docker Desktop.

List or remove caches explicitly:

```bash
docker volume ls --filter name=docker-codex-cache-
docker volume rm docker-codex-cache-<git-path-hash>
```

Removing a cache discards only rebuildable dependency/build data.

---

Back to [README](../../README.en.md)
