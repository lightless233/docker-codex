# Cursor Agent integration

This page describes how Cursor Agent is launched, where its API key lives, the
default permission mode, a worktree caveat, where project instructions come
from, and the security boundary.

## Launching

```bash
docker-cursor-agent
docker-agent cursor-agent
```

Both are equivalent. Arguments after `--` reach Cursor Agent unchanged:

```bash
docker-cursor-agent -- --model gpt-5
docker-cursor-agent -- -p "Summarize the current repository status" --output-format json
```

The shared options (`--build`, `--image`, `--isolated`, `--bind`, `--env`,
`--network`, `--host-docker`, `--pat-path`, `--disable-clipboard`, and the
rest) behave the same as for the other agents; see the
[README](../../README.en.md).

The Claude-only connection selectors (`--official-subscription`,
`--official-api`, `--profile`, and `--create-profile`) are rejected.

## API key

Cursor officially supports only API key authentication for containers and CI.
The launcher reads it from a fixed path:

```text
${DOCKER_AGENT_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent}/cursor-agent/api-key
```

Generate a key at [Cursor Dashboard → API Keys](https://cursor.com/dashboard/api),
then write it to that file:

```bash
config_root="${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent"
install -d -m 700 "$config_root/cursor-agent"
install -m 600 /dev/null "$config_root/cursor-agent/api-key"
read -rs key && printf '%s' "$key" > "$config_root/cursor-agent/api-key" && unset key
```

The file must be a regular, non-symlink file owned by the current user with
mode exactly `0600`, and it must not be empty; otherwise the launcher refuses
to start. Put only the key in it — a trailing newline is ignored.

There is no need to memorize these paths: when the file is missing the launcher
prints exactly these commands with the paths already expanded, ready to paste.

The key is mounted read-only at `/run/docker-agent/cursor-api-key` and exported
as `CURSOR_API_KEY` by the entrypoint. **The value never appears in the
`docker run` arguments**, so it is not visible to `docker inspect` or in the
host process list.

One behavior worth knowing: the CLI's `status` and `whoami` subcommands report
only the local OAuth login and **ignore `CURSOR_API_KEY` entirely**, so they
always print `Not logged in` in the container even with a valid key. A key
therefore cannot be verified before launching; the launcher validates the file
instead.

On billing, usage from a user API key draws down the included usage of that
user's own subscription plan rather than producing a separate API bill. Once
the included usage is exhausted, on-demand billing must be enabled explicitly
in the dashboard; setting a spend limit alongside it is advisable. Model choice
significantly affects how fast the quota is consumed.

## Default permission mode and auto-update

Cursor Agent starts with `--force` (`--yolo` is its alias), auto-approving tool
calls. The launcher skips that default whenever the passed arguments already
contain `-f`, `--force`, `--yolo`, or `--auto-review`.

The launcher also always adds the hidden `--disable-auto-update` flag. The CLI
updates itself by default, which would defeat the version pinned by
`CURSOR_AGENT_VERSION` in the image.

## Do not use the CLI's own worktree flag

Cursor Agent has its own `-w/--worktree`, which creates a worktree under
`~/.cursor/worktrees/`. Because `$HOME` is container-private, that has two
consequences:

- every edit made in that worktree is lost when the container exits; and
- the host repository is left with a worktree registration pointing at a
  container path (`git worktree list` marks it `prunable`) plus the new branch,
  requiring manual `git worktree prune` and `git branch -D`.

The worktree is also created before authentication, so the repository is
polluted even on a run that does nothing because the key was rejected.

The launcher prints a warning when it sees the flag but still passes it through
unchanged. For an isolated worktree, use the project's own `--isolated NAME`,
which creates and retains it on the host.

## Project instructions

Cursor Agent natively reads `AGENTS.md`, `CLAUDE.md`, and `.cursor/rules` from
the project root, so a project's own rules apply in the container without any
extra injection.

It has no flag to append to or override the system prompt, so the shared agent
notes shipped in the image are not injected for Cursor Agent. This differs from
Codex, Claude Code, and Kimi Code.

## Runtime inside the container

The CLI is distributed as an archive carrying its whole runtime. It is unpacked
at `/opt/cursor-agent` and includes its own Node and ripgrep rather than using
the image's Node. `/usr/local/bin` holds both a `cursor-agent` and an `agent`
symlink, matching the two names the official installer provides.

The image does not run the official install script, which resolves a floating
version and edits shell rc files. The Dockerfile downloads the pinned archive
directly and verifies it against a SHA-256 recorded in the `Dockerfile` —
Cursor publishes no checksum, so that digest is maintained by this project and
must be updated whenever the version changes.

## Security boundary

The API key is readable by processes in the container, the container user has
passwordless sudo inside the container, and tool approvals are disabled by
default, so use this only in project directories you trust.

The key is an account-level credential. Set a spend limit in the Cursor
dashboard, and revoke the key immediately if it leaks or is no longer needed.

---

Back to the [README](../../README.en.md)
