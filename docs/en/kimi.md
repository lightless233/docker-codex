# Kimi Code integration

This page describes how Kimi Code is launched, how its data root is shared,
how to log in, the default permission mode, how container notes are injected,
and the security boundary.

## Launching

```bash
docker-kimi
docker-agent kimi
```

Both are equivalent. Arguments after `--` reach Kimi Code unchanged:

```bash
docker-kimi -- --model kimi-k3
docker-kimi -- -p "Summarize the current repository status"
```

The shared options (`--build`, `--image`, `--isolated`, `--bind`, `--env`,
`--network`, `--host-docker`, `--pat-path`, `--disable-clipboard`, and the
rest) behave the same as for the other agents; see the
[README](../../README.en.md).

The Claude-only connection selectors (`--official-subscription`,
`--official-api`, `--profile`, and `--create-profile`) are rejected for Kimi
Code. Kimi Code reads provider credentials from its configuration file rather
than from environment variables, so there is no equivalent profile mechanism.

## Data root and login

Kimi Code keeps configuration, sessions, logs, and OAuth credentials under a
single data root, `~/.kimi-code` by default, relocatable with
`KIMI_CODE_HOME`. The launcher mounts the host

```text
${KIMI_CODE_HOME:-$HOME/.kimi-code}
```

at `/kimi-home` in the container and sets `KIMI_CODE_HOME=/kimi-home` there.
Host and container therefore share one login: signing in on either side is
immediately visible to the other.

When the host directory is missing the launcher creates it with mode `0700`,
so the host does not need its own Kimi Code installation. A path that exists
but is not a directory is rejected.

For a first run, log in from inside the container:

```bash
docker-kimi
# Run /login in the TUI and pick Kimi Code OAuth or a Kimi platform API key
```

This differs from the Claude Code handling. Claude mounts a single credential
file and keeps separate state per worktree and connection, while Kimi Code
shares the whole data root, so session history is shared across the host and
all projects too.

## Default permission mode

Kimi Code starts with `--yolo` in the container, auto-approving regular tool
calls, matching the Codex default.

Kimi Code rejects `--yolo` together with `--prompt`, `--auto`, or `--plan`,
and its non-interactive mode already runs with automatic permission. The
launcher therefore skips the default whenever the passed arguments already
contain `-p`, `--prompt`, `--auto`, `--plan`, `-y`, or `--yolo`:

```bash
# Runs kimi --yolo --model kimi-k3
docker-kimi -- --model kimi-k3

# Runs kimi -p "..." with no added --yolo
docker-kimi -- -p "Summarize the current repository status"
```

## How the container notes are injected

Codex and Claude Code both accept a flag that appends to the system prompt.
Kimi Code does not. It merges instruction files instead, and the generic
cross-tool location among them is `~/.agents/AGENTS.md` in the real home,
resolved through `os.homedir()` — inside the container that is
`/home/codex/.agents/AGENTS.md`.

The entrypoint copies the shared agent notes shipped in the image to that
path, and only when no file is already there. The path lives in the
container-private home rather than inside the mounted data root, so nothing is
written into the host `~/.kimi-code`, and a user's own
`$KIMI_CODE_HOME/AGENTS.md` still applies — the two are merged.

The notes only state container facts. They carry no response-language,
persona, endpoint, or model instructions.

## Security boundary

The shared data root holds OAuth credentials or an API key, readable by the
Kimi Code process in the container. The container user also has passwordless
sudo inside the container and tool approvals are disabled by default, so use
this only in project directories you trust.

The data root is a bind mount of a host directory, so configuration and
session changes made in the container are written straight back to the host.
For a run that stays fully isolated from the host state, point it at a
different data root:

```bash
KIMI_CODE_HOME=~/.kimi-code-throwaway docker-kimi
```

---

Back to the [README](../../README.en.md)
