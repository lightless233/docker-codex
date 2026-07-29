# Claude Code integration

This page describes Claude Code connection selection, profile syntax,
subscription reuse, state isolation, container policy, and cleanup.

## Launching and connection menus

Run this in an interactive terminal:

```bash
docker-agent claude
```

The top-level menu offers:

1. Anthropic official subscription / OAuth
2. Anthropic official API key
3. Custom endpoint

The custom choice opens a second menu containing every `*.env` profile except
`official-api.env`, sorted by name under the C locale. Use arrow keys or
`j`/`k`, Enter to confirm, and Escape or Ctrl-C to cancel with status 130. No
choice is remembered.

Direct selectors work well in aliases, scripts, and CI:

```bash
docker-agent claude --official-subscription
docker-agent claude --official-api
docker-agent claude --profile deepseek
```

The three selectors are mutually exclusive. Without a TTY on both stdin and
stdout, one must be specified explicitly. Arguments after `--` pass unchanged:

```bash
docker-agent claude --profile deepseek -- --version
```

## Profile location and permissions

The profile root is:

```text
${DOCKER_AGENT_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent}/claude/profiles
```

Create a profile safely:

```bash
profile_root="${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent/claude/profiles"
install -d -m 700 "$profile_root"
install -m 600 /dev/null "$profile_root/deepseek.env"
"${EDITOR:-vi}" "$profile_root/deepseek.env"
```

A profile must be outside the checkout, owned by the invoking user, a regular
non-symlink file, and exactly mode `0600`; use `0700` for its directory. This is
not a shell script: do not add `export`, shell quoting, or variable expansion.
Each non-comment line is `KEY=value`, with everything after the first `=`
treated literally.

Only these nine keys are accepted:

```text
ANTHROPIC_BASE_URL
ANTHROPIC_AUTH_TOKEN
ANTHROPIC_API_KEY
ANTHROPIC_MODEL
ANTHROPIC_DEFAULT_OPUS_MODEL
ANTHROPIC_DEFAULT_SONNET_MODEL
ANTHROPIC_DEFAULT_HAIKU_MODEL
CLAUDE_CODE_SUBAGENT_MODEL
CLAUDE_CODE_EFFORT_LEVEL
```

Both the host launcher and container entrypoint independently validate the
allowlist, duplicate keys, and connection contract. Neither `source`s nor
`eval`s a profile.

## Official API key

The reserved filename is `official-api.env`; this is the complete minimum:

```bash
profile_root="${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent/claude/profiles"
install -d -m 700 "$profile_root"
install -m 600 /dev/null "$profile_root/official-api.env"
printf '%s\n' 'ANTHROPIC_API_KEY=sk-ant-replace-me' \
  >"$profile_root/official-api.env"
```

It must use `ANTHROPIC_API_KEY` as its only credential and may not set
`ANTHROPIC_BASE_URL` or `ANTHROPIC_AUTH_TOKEN`. Allowed model fields may still
be included.

## Custom endpoint

A DeepSeek profile matching the example configuration is:

```text
ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
ANTHROPIC_AUTH_TOKEN=sk-123456
ANTHROPIC_MODEL=deepseek-v4-pro[1m]
ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-pro[1m]
ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-pro[1m]
ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash
CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-flash
CLAUDE_CODE_EFFORT_LEVEL=max
```

A custom profile requires `ANTHROPIC_BASE_URL` and exactly one of
`ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_API_KEY`. Credentials and model settings
live in the same mode-`0600` file. The selected profile is mounted read-only
into that Claude container, and its contents never appear in `docker run`
arguments.

## Reusing an official subscription / OAuth login

Linux and WSL use the host file:

```text
${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json
```

Only this credential file is mounted, not the complete `~/.claude`. It must be
owned by the invoking user, exactly mode `0600`, and not a symlink. The mount is
read-write at `.credentials.json` inside the isolated Claude state because
Claude Code may refresh it. Sessions, history, and other state remain under
docker-agent's separate data root.

Claude subscriptions on macOS normally live in Keychain, which a Linux
container cannot reuse. `--official-subscription` therefore fails on macOS;
use `--official-api` or a custom profile.

## State isolation

The default data root is:

```text
${DOCKER_AGENT_DATA_HOME:-${DOCKER_CODEX_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/docker-agent}}
```

Claude state is arranged as:

```text
<data-root>/claude/repos/
  <repo-name>-<Git-common-dir-path-hash>/
    worktrees/
      <worktree-name>-<checkout-path-hash>/
        official-subscription/
        official-api/
        profiles/
          <profile-name>/
```

Repository and worktree IDs include a 16-character Git object hash of the
canonical absolute path, so `/home/test` and `/project/test` do not collide.
Each repository, worktree, and connection has a separate `CLAUDE_CONFIG_DIR`;
later containers using the same combination reuse it. Editing a profile
without renaming it also reuses that state.

Every state directory contains a mode-`0600` `.docker-agent-identity`. The
launcher verifies its repository, checkout, and connection identity to reject
collisions or accidental reuse.

## Claude container policy

The entrypoint sets these only for the Claude process:

```text
TZ=Etc/UTC
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
LANGUAGE=en_US:en
DISABLE_AUTOUPDATER=1
DISABLE_TELEMETRY=1
DISABLE_ERROR_REPORTING=1
DISABLE_FEEDBACK_COMMAND=1
CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
```

The policy variables remain separate and cannot be merged into or overridden
by profiles. The English locale changes only the container's operating-system
environment; it does not instruct Claude Code to answer in English. Response
language still follows Claude Code, project instructions, and the user's
request.

Claude always receives `--dangerously-skip-permissions`. The shared agent notes
describe container facts only, with no response-language, personality,
endpoint, or model instruction.

## Security and exact cleanup

The selected container process can read profile secrets. Its user also has
passwordless sudo inside the container, and Claude approvals are disabled.
Use only minimally scoped, revocable credentials and never store profiles in a
repository.

Remove one exact profile file:

```bash
profile_root="${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent/claude/profiles"
rm -- "$profile_root/deepseek.env"
```

Before removing state, list identity files and inspect the exact target:

```bash
data_root="${XDG_DATA_HOME:-$HOME/.local/share}/docker-agent"
find "$data_root/claude/repos" -name .docker-agent-identity -type f -print

# Replace this value with the exact absolute state directory selected above.
state_dir="/home/me/.local/share/docker-agent/claude/repos/repo-HASH/worktrees/worktree-HASH/profiles/deepseek"
rm -rf -- "$state_dir"
```

Do not recursively remove the data root or its `claude`/`repos` roots. Removing
state does not delete the profile or OAuth source file; the next launch creates
empty state.

---

Back to [README](../../README.en.md)
