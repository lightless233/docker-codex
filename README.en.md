# docker-codex

[简体中文](README.md) | **English**

Run Codex CLI inside a development container while editing the caller's current
Git checkout. The launcher shares the host Codex home, understands normal
checkouts, linked worktrees, and submodules, and creates a new worktree only
when explicitly requested.

## Quick start

Before starting, make sure the Docker daemon is running and the host already
has a usable `${CODEX_HOME:-$HOME/.codex}`.

### 1. Build the image once

Enter this repository and build the image:

```bash
cd /absolute/path/to/docker-codex
./docker-codex --build -- --version
```

The command should print the Codex CLI version installed in the image. Later
launches reuse the local `docker-codex:local` image and do not need to rebuild
it.

### 2. Install the launcher

Do not add the whole repository to `PATH`. After building the image, install
only the launcher into `/usr/local/bin`:

```bash
sudo install -m 0755 ./docker-codex /usr/local/bin/docker-codex
```

For an installation that does not require `sudo`, use a user-local directory:

```bash
install -d "$HOME/.local/bin"
install -m 0755 ./docker-codex "$HOME/.local/bin/docker-codex"
export PATH="$HOME/.local/bin:$PATH"
```

Add the last line to `~/.bashrc` or `~/.zshrc` only when `~/.local/bin` is not
already in `PATH`.

### 3. Start Codex

Enter the Git checkout you want to work on and run:

```bash
cd /absolute/path/to/your-project
docker-codex
```

Common examples:

```bash
# Pass arguments directly to Codex
docker-codex -- review "review the current branch"

# Create and use a retained isolated worktree
docker-codex --isolated issue-123

# Mount a read-only directory outside the checkout
docker-codex --bind /absolute/path/to/fixtures:ro --
```

> [!WARNING]
> The launcher enables `--yolo` by default and mounts the current checkout,
> required Git metadata, and the host Codex home read-write. Use it only with
> projects you trust and inside the intended Docker isolation boundary.

The launcher also passes `--disable apps` to this container process by default,
preventing built-in `codex_apps` MCP startup problems from delaying local
development. It does not modify the shared host `config.toml`.

Supported hosts:

- Linux
- WSL2
- macOS with Docker Desktop, including Apple Silicon

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

## Prerequisites

- Git
- Bash 3.2 or newer
- Docker with a running daemon
- an existing Codex home, normally `~/.codex`

Build the local image from this repository:

```bash
./docker-codex --build -- --version
```

Then install the single-file launcher:

```bash
sudo install -m 0755 ./docker-codex /usr/local/bin/docker-codex
```

The installed launcher can start an existing image without the source
checkout. `--build` still needs the repository's `Dockerfile` and
`container-entrypoint`, so rebuild from the source checkout with
`./docker-codex --build`; run the `install` command again after updating the
launcher.

Subsequent launches reuse `docker-codex:local`:

```bash
cd /path/to/project
docker-codex
```

The launcher adds `--yolo --disable apps` immediately after `codex`. Apps and
connectors are disabled only for the current container process; the shared host
Codex configuration is not modified. Arguments after `--` then go directly to
Codex:

```bash
docker-codex -- review "review the current branch"
```

## Checkout and worktree behavior

By default, the launcher uses the checkout containing the current directory. It
does not create a branch or worktree.

The checkout is mounted at the same absolute path in the container. When the
checkout is a linked worktree or submodule whose Git metadata lives elsewhere,
the launcher discovers that metadata with Git and mounts only the required
external Git directories, also at the same paths.

For example, a long-lived linked worktree can be used directly:

```bash
cd /home/me/program/my-long-lived-worktree
docker-codex
```

The container receives write access to the Git common directory because staging
and commits update its index and refs. It does not receive the sibling working
trees unless they are separately mounted.

### Optional isolated worktree

Create a new host worktree explicitly:

```bash
docker-codex --isolated issue-123
```

This creates:

- branch `codex/issue-123`;
- a worktree below
  `${DOCKER_CODEX_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/docker-codex}/worktrees`;
- a container using that new worktree.

The worktree and branch are retained when Codex or Docker exits, including when
startup fails. Inspect and remove them explicitly:

```bash
git worktree list
git worktree remove /absolute/path/from-the-list
git branch -d codex/issue-123
```

Git refuses removal when a worktree contains uncommitted changes unless the
user deliberately overrides it. The launcher never removes worktrees itself.

## Additional project directories

Use repeatable `--bind` options for fixtures or tools outside the checkout:

```bash
docker-codex \
  --bind /absolute/path/to/fixtures:ro \
  --bind /absolute/path/to/local-tooling \
  --
```

The source is mounted at the same absolute container path. Only directories are
accepted. Paths containing commas are rejected because Docker's `--mount`
grammar cannot represent them unambiguously.

The launcher deliberately does not mount the checkout's parent directory. This
keeps unrelated repositories and long-lived working trees outside the
container.

## Codex configuration, memory, and authentication

The complete host `${CODEX_HOME:-$HOME/.codex}` is mounted read-write at
`/codex-home`, and the container receives `CODEX_HOME=/codex-home`. This shares
configuration, local memories, sessions, skills, plugins, file-based
credentials, and other Codex state with local Codex clients.

Concurrent host and container Codex processes use the same state in the same way
multiple host Codex processes do. Keep the container image's Codex version
aligned with the host when upgrading state formats.

Authentication has an operating-system boundary:

- credentials stored in `auth.json` are visible through the mount;
- Linux keyring and macOS Keychain credentials are not available inside the
  Linux container.

The entrypoint checks `codex login status`. If it fails, it warns and continues
so Codex can present its normal login flow. The launcher never changes
`cli_auth_credentials_store` and never copies credentials into an image layer.

Configuration that names other absolute host paths still needs a corresponding
`--bind`. STDIO MCP commands and native tools referenced by `config.toml` must
also be installed in the image or made visible explicitly.

## Providing Git push credentials

The container starts with no Git credentials, so pushes fail. Two explicit
opt-in options mount a token as a read-only file at the fixed container path
`/codex-credentials/pat`. The launcher also injects a generic credential
helper and an SSH-to-HTTPS `insteadOf` rewrite for the origin host through
`GIT_CONFIG_*` environment variables. These settings live only in the
container process environment; nothing is written to config files shared
with the host.

The recommended form keeps the token in a dedicated file outside the
checkout:

```bash
install -d -m 700 ~/.local/share/docker-codex/pat
$EDITOR ~/.local/share/docker-codex/pat/github-<repo>   # the token, one line
chmod 600 ~/.local/share/docker-codex/pat/github-<repo>

docker-codex --pat-path ~/.local/share/docker-codex/pat/github-<repo>
```

Set `DOCKER_CODEX_PAT_PATH` to make that path the default and skip typing it.

`--pat TOKEN` passes the token on the command line instead: the launcher
writes it to `pat/<repo-id>` under the data home (directory mode 700, file
mode 600) and follows the same mounting path. The token value ends up in
your shell history and process listings, so **this is only a fallback for
situations where a token file cannot be prepared; prefer `--pat-path`**.
If you do use `--pat`, make sure the token is minimally scoped, revocable,
and short-lived.

Once inside the container, the token is readable by the agent. Use tokens
scoped to a single repository with minimal permissions and an expiration
date (for example GitHub fine-grained PATs), and revoke them server-side
when they are no longer needed.

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

## Platform notes

### Linux and WSL2

The entrypoint maps the container process to the host numeric UID/GID and adds
`host.docker.internal` through Docker's `host-gateway`. Keep WSL2 checkouts in
the Linux filesystem rather than `/mnt/c` when build performance matters.

### macOS

Docker Desktop must allow file sharing for the checkout, external Git metadata,
Codex home, and every `--bind` source. Paths below `/Users` are normally covered
by the default Docker Desktop settings.

The entrypoint handles common macOS identities such as UID 501/GID 20 without
assuming the group name is unused. Host Keychain credentials remain outside the
container.

On Apple Silicon, a local build produces a native Linux arm64 image. If a
project specifically needs a Linux amd64 development environment, select it
explicitly, for example:

```bash
DOCKER_DEFAULT_PLATFORM=linux/amd64 ./docker-codex --build -- --version
```

Emulated amd64 builds and workloads are slower.

## Security boundary

The container starts as root only long enough to initialize its private home and
cache directory, then uses `gosu` to run Codex as the host numeric UID/GID. It
does not recursively change ownership of the checkout, Git metadata, or Codex
home. This keeps ordinary bind-mount writes owned by the host user.

The runtime user has passwordless sudo inside the container and may obtain
container root when needed. It is not added to the root group.

The launcher's default `--yolo` disables Codex's own approvals and command
sandbox, so every read-write mount is fully exposed to the agent. Docker
remains the outer isolation boundary; the launcher does not use `--privileged`.

The launcher never automatically mounts:

- `/var/run/docker.sock`;
- the host filesystem root or full home;
- the checkout's common parent directory;
- SSH/GPG agents or private keys;
- unrelated repositories.

Codex can freely modify every read-write path deliberately mounted into the
container. Docker remains the outer boundary for everything else.

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

--help, -h
    Print command help.
```

Build-time versions can be changed explicitly:

```bash
docker build \
  --build-arg NODE_VERSION=24.18.0 \
  --build-arg CODEX_VERSION=0.145.0 \
  --build-arg PNPM_VERSION=10.14.0 \
  -t docker-codex:local .
```

`NODE_VERSION` upgrades are explicit. The image does not install Node.js or npm
from Debian or third-party package repositories.

## Verification

Run the shell suite:

```bash
tests/run.bash
```

Validate and build the image:

```bash
docker build --check .
docker build -t docker-codex:local .
DOCKER_CODEX_TEST_IMAGE=docker-codex:local tests/image_test.bash
```

The test suite uses real temporary Git repositories, linked worktrees, and
submodules while replacing only the external Docker boundary. The separate
image test runs a real container and verifies Debian, Node provenance, numeric
UID/GID, absence of the root group, and passwordless sudo. Linux image builds
and runtime smoke tests are part of release verification.

macOS path/argument branches and the multi-architecture image definition are
covered by automated checks. A real macOS Docker Desktop/Apple Silicon runtime
has not yet been exercised by this project and must not be inferred from Linux
test results.
