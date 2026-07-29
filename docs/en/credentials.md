# Agent configuration, authentication, and Git push credentials

This page explains the authentication boundaries for Codex and Claude Code,
and how to explicitly provide Git push credentials.

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
