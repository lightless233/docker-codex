# Agent configuration, authentication, and Git push credentials

This page explains the authentication boundaries for Codex and Claude Code,
and how to explicitly provide Git push credentials. Kimi Code shares its whole
data root instead; see [Kimi Code integration](kimi.md). Cursor Agent uses a
protected API key file; see [Cursor Agent integration](cursor-agent.md).

## Codex configuration, memory, and authentication

The complete host `${CODEX_HOME:-$HOME/.codex}` is mounted read-write at the
same logical absolute path inside the container, and the container receives
that path as `CODEX_HOME`. For example, a host path of
`/home/lightless/.codex` produces:

```text
source=/home/lightless/.codex
target=/home/lightless/.codex
CODEX_HOME=/home/lightless/.codex
```

When host `CODEX_HOME` is a symlink, the Docker source is its resolved physical
directory while the target and `CODEX_HOME` preserve the logical path used by
the host. Container `HOME=/home/codex` remains private; the full host home is
not mounted.

The same physical directory is also mounted at `/codex-home`, but only as a
compatibility alias for absolute session paths written by older docker-codex
versions. New sessions do not store this alias. The shared directory includes
configuration, local memories, sessions, skills, plugins, file-based
credentials, and other Codex state.

Host user hooks, checkout hooks, and plugin hooks in the shared state remain
visible to the container, but image-managed requirements exclude them from
Codex hook discovery, so they do not execute in the container. This boundary
does not prevent other container processes from reading or modifying shared
hook files; see the [security boundary](security.md) for the threat model.

Concurrent host and container Codex processes use the same state in the same way
multiple host Codex processes do. Keep the container image's Codex version
close to the host version when upgrading state formats; version alignment does
not replace session-path repair.

### Repairing legacy session paths

Sessions created by an older container may still reference
`/codex-home/sessions/...` in the state database. Exit every host and container
Codex process, then run the repair explicitly:

```bash
docker-codex --repair-sessions
# Equivalent entry point
docker-agent codex --repair-sessions
```

The command uses tooling inside the image, so the host does not need `sqlite3`
or `jq`. It takes a bounded database write lock, first creates a consistent
backup including committed WAL data under
`CODEX_HOME/session-repair-backups`, and prints the backup's full host path.
It migrates only legacy-prefix rows whose rollout remains inside the current
`sessions` directory, is readable, contains parseable JSON session metadata,
and has a metadata session ID matching the database row ID.

Successful output also reports updated and skipped counts. Missing,
out-of-bounds, malformed, or ID-mismatched records are skipped; no session file
or database row is deleted. Repeated runs are safe and do not change already
migrated rows. A normal `docker-codex` launch never runs the repair.

A persistent database lock, unsupported schema, or failed integrity check
rolls the transaction back and exits nonzero. Published backups are never
cleaned up by the tool. Unmigrated legacy sessions can still be resumed in the
container through the `/codex-home` compatibility alias. Restoring a backup is
an explicit user operation and must be done only after every Codex process has
exited.

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

Custom Responses endpoints can use multiple native Codex profiles. The
launcher supports `--create-profile` and `--profile NAME`. Managed files live
under `codex/profiles` in the docker-agent config root and are exposed to host
Codex through compatibility links in `CODEX_HOME`; one mode-`0600` TOML file
contains the endpoint and bearer token. See
[Codex custom endpoint profiles](codex.md) for syntax and security limits.

## Claude Code authentication and state

Claude does not receive the complete `~/.claude`. On Linux/WSL, official
subscription mode mounts only
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json` read-write into state
isolated by repository, worktree, and connection. API keys and custom
endpoints come from mode-`0600` profiles outside the checkout. A Linux
container cannot reuse macOS Keychain.

See [Claude Code integration](claude.md) for profile syntax, selectors, state
paths, and cleanup.

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
install -d -m 700 ~/.local/share/docker-agent/pat
$EDITOR ~/.local/share/docker-agent/pat/github-<repo>   # the token, one line
chmod 600 ~/.local/share/docker-agent/pat/github-<repo>

docker-agent codex --pat-path ~/.local/share/docker-agent/pat/github-<repo>
```

Set `DOCKER_AGENT_PAT_PATH` to make that path the default. The legacy
`DOCKER_CODEX_PAT_PATH` remains a compatibility fallback.

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

---

Back to [README](../../README.en.md)
