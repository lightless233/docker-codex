# docker-agent container environment

You are running inside a docker-agent development container. Key facts:

- When `/codex-credentials/pat` exists, Git credentials are already wired
  up through a credential helper: plain `git fetch` / `git pull` /
  `git push` work as-is. Never read, print, or quote the token file.
- Do not run `git worktree prune` or `git worktree remove` inside the
  container: sibling worktrees of the mounted checkout are not visible
  here, so pruning would delete their live registrations on the host.
- Rust builds link with mold by default (via `RUSTFLAGS`). To reuse
  dependency builds across worktrees, opt into sccache:
  `RUSTC_WRAPPER=sccache SCCACHE_DIR=/codex-cache/sccache cargo build`
- Cargo build artifacts go to `CARGO_TARGET_DIR`, which is isolated per
  worktree under `/codex-cache/cargo-targets/` — not `./target`. Resolve
  the real target directory with
  `cargo metadata --no-deps --format-version 1 | jq -r .target_directory`
  instead of hardcoding `./target` paths.
- Go modules, build results, and binaries installed with `go install` persist
  in the project cache through `GOMODCACHE`, `GOCACHE`, and `GOPATH`.
- The system Python is externally managed; use `python3 -m venv` for
  installs instead of global `pip install`.
- The container user has passwordless sudo. Files created in bind-mounted
  checkouts are owned by the host user automatically.
- Docker CLI, Buildx, and Compose are installed, but the image contains no
  Docker daemon. When `DOCKER_HOST` points to `/var/run/docker.sock`, the
  launcher was explicitly started with host Docker access and this agent has
  root-equivalent control of the Docker host, including arbitrary host-path
  mounts.
