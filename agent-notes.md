# docker-codex container environment

You are running inside a docker-codex development container. Key facts:

- When `/codex-credentials/pat` exists, Git credentials are already wired
  up through a credential helper: plain `git fetch` / `git pull` /
  `git push` work as-is. Never read, print, or quote the token file.
- Rust builds link with mold by default (via `RUSTFLAGS`). To reuse
  dependency builds across worktrees, opt into sccache:
  `RUSTC_WRAPPER=sccache SCCACHE_DIR=/codex-cache/sccache cargo build`
- Cargo build artifacts go to `CARGO_TARGET_DIR`, which is isolated per
  worktree under `/codex-cache/cargo-targets/` — not `./target`. Resolve
  the real target directory with
  `cargo metadata --no-deps --format-version 1 | jq -r .target_directory`
  instead of hardcoding `./target` paths.
- The system Python is externally managed; use `python3 -m venv` for
  installs instead of global `pip install`.
- The container user has passwordless sudo. Files created in bind-mounted
  checkouts are owned by the host user automatically.
