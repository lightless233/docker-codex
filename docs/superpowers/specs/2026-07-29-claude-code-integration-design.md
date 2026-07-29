# Claude Code integration design

Date: 2026-07-29

## Summary

Evolve docker-codex into a multi-agent Docker launcher with one shared
development image and one canonical `docker-agent` command. The first two
agents are Codex and Claude Code:

```text
docker-agent codex
docker-agent claude
```

Codex keeps its existing behavior. Claude Code gains three explicit connection
modes: an Anthropic subscription reused from the host, an Anthropic API key,
and named profiles for Anthropic-compatible custom endpoints. When no Claude
connection mode is provided in an interactive terminal, the launcher presents
an arrow-key menu.

Claude state is not stored in or shared through the host's complete
`~/.claude` directory. Sessions and other mutable state are isolated by
repository, worktree, and connection mode under the docker-agent data home.
Only the host OAuth credential file is shared for subscription mode.

## Goals

- Install pinned Codex and Claude Code versions in one reproducible image.
- Provide a neutral canonical command while preserving `docker-codex`
  compatibility.
- Run Claude Code with the same checkout, Git metadata, worktree, cache,
  credential, clipboard, UID/GID, and container isolation behavior already
  provided to Codex.
- Support:
  - host Anthropic subscription/OAuth authentication on Linux and WSL;
  - an Anthropic official API key;
  - named custom Anthropic-compatible endpoints.
- Keep Claude sessions and mutable user state outside the host `~/.claude`
  directory and isolated across worktrees and connection modes.
- Keep profile credentials out of shell history, Docker environment arguments,
  Docker inspection output, and launcher logs.
- Disable Claude telemetry, error reporting, feedback commands, feedback
  surveys, and automatic CLI updates through separate variables.
- Run Claude containers in UTC with an `en_US.UTF-8` locale without changing
  Claude's response language or persona.

## Non-goals

- Separate Codex and Claude images in the first version.
- Install or update either CLI at container startup.
- Mount the complete host `~/.claude` directory.
- Share Claude sessions between different worktrees or connection modes.
- Force Claude to answer in English.
- Add a generic secret manager or support arbitrary environment variables in
  profiles.
- Reuse a macOS Keychain subscription credential inside a Linux container.
- Add Bedrock, Vertex, Foundry, or other provider-specific modes in this
  version.

## Chosen architecture

### One image

Use one `docker-agent:local` image containing both CLIs and the existing Debian
development toolchain. Add an exact Claude Code version build argument beside
the existing pinned versions.

The Dockerfile exposes `CODEX_VERSION` and `CLAUDE_CODE_VERSION` build
arguments whose checked-in defaults are exact published version literals.
Version upgrades happen through explicit source changes or build arguments and
are covered by image tests. The image installs both npm packages in one layer:

```text
@openai/codex@${CODEX_VERSION}
@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
```

Runtime installation was rejected because it would require network access at
startup, introduce version drift, and make sessions less reproducible. Separate
final images were rejected for the first version because they would duplicate
build, release, cache, and test paths without providing enough benefit.

### One dispatcher

The canonical public interface is:

```text
docker-agent codex [common options] -- [codex arguments]
docker-agent claude [common options] [connection option] -- [claude arguments]
```

The dispatcher owns all shared behavior:

- Git checkout and metadata discovery;
- regular and isolated worktrees;
- additional bind mounts;
- the per-repository build cache;
- host UID/GID mapping;
- PAT forwarding for Git push;
- display/clipboard forwarding;
- image building and selection;
- Docker daemon validation.

Agent-specific code only selects state, mounts, environment, entrypoint setup,
and the final CLI arguments.

### Compatibility entrypoints

The same dispatcher can be installed under three names:

```text
docker-agent
docker-codex
docker-claude
```

When invoked as `docker-agent`, the first positional argument must be `codex`
or `claude`. When invoked as `docker-codex` or `docker-claude`, the basename
selects the agent, so existing calls such as this remain valid:

```text
docker-codex -- review "review the current branch"
```

`docker-claude` is equivalent to `docker-agent claude`. A single copied script
therefore remains a valid standalone installation; symlinks are convenient but
not required.

The neutral environment variables use a `DOCKER_AGENT_` prefix. Existing
`DOCKER_CODEX_` variables remain fallbacks for the corresponding common and
Codex behavior so the integration does not silently discard current user
configuration.

## Claude command interface

### Direct connection options

Claude exposes three mutually exclusive selectors:

```text
--official-subscription
--official-api
--profile NAME
```

Examples:

```bash
docker-agent claude --official-subscription
docker-agent claude --official-api
docker-agent claude --profile deepseek
docker-agent claude --profile deepseek -- --model opus
```

The selector is parsed by docker-agent and is never forwarded to Claude.
Arguments after `--` are forwarded unchanged.

Using `--api-key` as a selector was rejected because that spelling suggests
placing the secret itself on the command line. `--official-api` selects a
fixed protected profile instead.

Supplying more than one selector is an error. `--profile` requires a value.
The reserved profile name `official-api` cannot be selected through
`--profile`; callers use `--official-api`.

### Interactive menu

When Claude is launched without a selector and both stdin and stdout are TTYs,
the host launcher displays:

```text
Select how Claude Code should connect:

> Anthropic subscription / OAuth
  Anthropic official API key
  Custom endpoint

Up/Down select - Enter confirm - Esc cancel
```

The menu supports:

- Up and Down arrow keys;
- `j` and `k` as optional alternate navigation;
- Enter to confirm;
- Escape and Ctrl-C to cancel.

Choosing `Custom endpoint` opens a second menu containing profile names in
stable lexical order. The reserved `official-api` profile is excluded. A
selected profile is fully validated before Docker starts. If no custom
profiles exist, the launcher exits with the profile directory and a concise
creation example.

The top-level menu always contains the same three connection types. It does
not remember a previous selection and there is no hidden default profile.

When either stdin or stdout is not a TTY, omission of a selector is an error.
The message lists all three direct forms so CI, pipes, and automation cannot
hang waiting for input.

## Filesystem layout and identity

### Configuration home

The docker-agent configuration root is:

```text
${DOCKER_AGENT_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent}
```

Claude profiles live at:

```text
<config-root>/claude/profiles/
```

The launcher creates configuration directories with mode `0700`. Profiles are
never searched for in the checkout and a configuration root inside the
checkout is rejected.

### Data home

The docker-agent data root is resolved in this order:

1. `DOCKER_AGENT_DATA_HOME`;
2. the legacy `DOCKER_CODEX_DATA_HOME`;
3. `${XDG_DATA_HOME:-$HOME/.local/share}/docker-agent`.

Claude state lives at:

```text
<data-root>/claude/
└── repos/
    └── <repo-slug>-<repo-hash>/
        └── worktrees/
            └── <worktree-slug>-<worktree-hash>/
                ├── official-subscription/
                ├── official-api/
                └── profiles/
                    └── <profile-name>/
```

The selected leaf is mounted read-write at `/claude-state`, and the container
sets:

```text
CLAUDE_CONFIG_DIR=/claude-state
```

This isolates sessions, auto memory, settings, plugins, caches, and other
mutable Claude state by repository, worktree, and connection mode. Repeated
launches of the same worktree and connection mode reuse their state. Changing
the contents of a named profile does not discard that profile's state; renaming
the profile selects a new state directory.

### Collision-resistant IDs

Readable slugs alone are insufficient because `/home/test` and `/project/test`
have the same basename.

Repository identity uses the canonical Git common directory. Worktree identity
uses the canonical checkout root:

```text
repo_hash     = git_hash_object(canonical_common_dir)[0:16]
worktree_hash = git_hash_object(canonical_checkout_root)[0:16]
repo_id       = sanitized_repo_name + "-" + repo_hash
worktree_id   = sanitized_worktree_name + "-" + worktree_hash
```

Canonical paths are resolved with physical-path semantics (`pwd -P`). The hash
uses the existing `git hash-object --stdin` helper because Git is already a
required cross-platform dependency, whereas GNU `sha256sum` is not guaranteed
on macOS.

Slugs replace characters outside `[A-Za-z0-9._-]` with `_`, use a stable
fallback when empty, and are limited to 48 characters for readable paths.

Each state leaf contains an identity metadata file recording the canonical
common directory, checkout path, agent, and connection identity. On reuse, the
launcher compares the metadata before mounting the state. A mismatch is a hard
error, which prevents even a truncated-hash collision from joining unrelated
state.

Moving a repository or worktree intentionally creates a new identity. The old
state remains available for manual inspection or removal and is never
automatically migrated or deleted.

## Authentication

### Anthropic subscription / OAuth

On Linux and WSL, the host credential source is:

```text
${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json
```

The launcher requires a regular credential file owned by the invoking user
with mode `0600` and mounts that single file read-write at:

```text
/claude-state/.credentials.json
```

The rest of the host Claude directory is not mounted. Claude sessions and
other mutable state continue to use the isolated `/claude-state` directory.

Read-write access is required because Claude Code may refresh OAuth
credentials. The implementation must verify with a real Linux/WSL Claude
login that refresh and credential writes work through a single-file bind
mount. Failure of that acceptance test blocks subscription-reuse support; the
launcher must not silently fall back to mounting the complete `~/.claude`
directory.

On macOS, Claude subscription credentials are stored in Keychain and cannot be
reused by a Linux container through this file contract. The first version
reports this limitation for `--official-subscription` and directs the user to
`--official-api` or a custom profile. It does not claim macOS host-subscription
reuse.

### Anthropic official API

`--official-api` loads the reserved profile:

```text
<config-root>/claude/profiles/official-api.env
```

Minimal content:

```ini
ANTHROPIC_API_KEY=sk-ant-example
```

The profile may contain the allowed model-selection variables but must not
contain `ANTHROPIC_BASE_URL` or `ANTHROPIC_AUTH_TOKEN`. This guarantees that
the mode continues to mean the Anthropic official endpoint using an API key.

### Custom endpoint profiles

`--profile NAME` resolves exactly:

```text
<config-root>/claude/profiles/NAME.env
```

Names must match:

```text
[A-Za-z0-9][A-Za-z0-9._-]*
```

Path separators, traversal, commas, and the reserved `official-api` name are
rejected. Symlink profiles are rejected; the target must be a regular file
owned by the invoking user with exact mode `0600`.

A custom profile must contain:

- a non-empty `ANTHROPIC_BASE_URL`; and
- exactly one of `ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_API_KEY`.

Example:

```ini
ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
ANTHROPIC_AUTH_TOKEN=sk-example
ANTHROPIC_MODEL=deepseek-v4-pro[1m]
ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-pro[1m]
ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-pro[1m]
ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash
CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-flash
CLAUDE_CODE_EFFORT_LEVEL=max
```

### Profile format

Profiles use a deliberately small `.env` subset:

- blank lines are ignored;
- lines whose first non-whitespace character is `#` are comments;
- every other line is one `KEY=VALUE` assignment;
- the first `=` separates key and value;
- keys may not contain whitespace;
- values are literal text and must be non-empty where required;
- `export`, shell quoting, interpolation, command substitution, and line
  continuation have no special meaning.

Users therefore write raw values without shell quotes. The launcher and
entrypoint never `source` or `eval` a profile.

The initial allowlist is:

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

Unknown keys, duplicate keys, conflicting credentials, and invalid effort
levels are errors. `CLAUDE_CODE_EFFORT_LEVEL` accepts `low`, `medium`, `high`,
`xhigh`, `max`, or `auto`. Additional Claude variables require an explicit
source and test change rather than being forwarded by wildcard.

The launcher does not inherit host `ANTHROPIC_*` or `CLAUDE_CODE_*`
configuration implicitly. A selected profile or explicit connection mode is
the complete routing decision. Per-session model selection remains available
through Claude's own arguments after `--`.

### Secret transfer

API profiles are bind-mounted read-only at a fixed container path. The launcher
validates their contents but does not copy values into Docker `--env`
arguments. The root entrypoint parses the mounted file again, exports the
allowlisted variables, and then drops to the host UID/GID before executing
Claude.

Consequences:

- profile contents and tokens are absent from Docker command arguments,
  launcher logs, fake-Docker test logs, and `docker inspect` environment;
- Docker inspection can reveal the host profile path and profile name;
- the profile remains readable inside the container by the container user;
- exported credentials are visible to the Claude process and same-UID
  processes.

Mode `0600` protects the profile from other host users but does not make it
secret from an agent intentionally granted the credential. This is the same
trust boundary as the existing Git PAT mount and must be documented.

## Claude runtime environment

### Locale and timezone

The shared image installs `locales` and `tzdata` and generates
`en_US.UTF-8`. The image does not set a global locale or timezone.

Only Claude launches receive:

```text
TZ=Etc/UTC
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
LANGUAGE=en_US:en
```

This changes process locale, encoding, sorting, and time presentation in the
Claude container. It does not add a system prompt, memory instruction, or
response-language preference. Codex retains its current environment.

### Update and telemetry policy

Every Claude launch sets these variables independently:

```text
DISABLE_AUTOUPDATER=1
DISABLE_TELEMETRY=1
DISABLE_ERROR_REPORTING=1
DISABLE_FEEDBACK_COMMAND=1
CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
```

The combined `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` variable is not used.
Profiles cannot override or unset these process-wide defaults.

### Final command

The entrypoint executes Claude as the mapped non-root host user:

```text
claude --dangerously-skip-permissions \
  --append-system-prompt-file <container-agent-notes> \
  <caller arguments>
```

Caller arguments retain their original ordering after the launcher-owned
arguments.

The appended notes contain only container facts already provided to Codex,
including:

- Git credential wiring without revealing the credential;
- the prohibition on `git worktree prune` and `git worktree remove` inside
  the container;
- cache and `CARGO_TARGET_DIR` locations;
- mold and optional sccache behavior;
- externally managed Python guidance;
- passwordless container sudo and host UID/GID ownership.

They contain no language, personality, answer-style, or provider instruction.
Project `CLAUDE.md` and `.claude/` files remain available naturally through
the checkout mount.

## Entrypoint and data flow

For a direct custom launch:

```text
docker-agent claude --profile deepseek -- --model opus
```

the data flow is:

1. Select the Claude agent and `deepseek` connection identity.
2. Resolve the checkout, common Git directory, and canonical worktree path.
3. Compute and verify repository/worktree identity metadata.
4. Resolve `deepseek.env` under the protected configuration root.
5. Validate name, ownership, mode, format, allowlist, endpoint, and credential.
6. Create the mode-specific data directory with mode `0700`.
7. Bind the data directory to `/claude-state`.
8. Bind the profile read-only to the fixed profile path.
9. Add Claude-only locale, timezone, update, and telemetry environment.
10. Start the shared image with the selected workdir and normal project
    mounts.
11. Revalidate and parse the profile in the entrypoint.
12. Drop privileges with `gosu`.
13. Execute Claude with the launcher flags and caller arguments.

The official API flow replaces step 4 with the reserved profile. The
subscription flow replaces profile mounting and parsing with the read-write
credential file mount.

## Error handling

All discoverable host errors occur before `docker run`:

- missing or unsupported agent;
- missing connection selector in a non-TTY context;
- mutually exclusive connection selectors;
- invalid profile name;
- missing profile directory or file;
- symlink, ownership, or permission failure;
- profile located inside the checkout;
- malformed, unknown, duplicate, or conflicting profile assignments;
- missing custom endpoint or credential;
- invalid official API profile;
- missing Linux/WSL OAuth credential;
- unsupported macOS subscription reuse;
- state identity metadata mismatch;
- existing Git, bind, Docker daemon, and image failures.

Entrypoint validation remains mandatory because the mounted file is the final
input consumed by the process. Entrypoint failures name the invalid key or
contract but never print a secret value or complete profile contents.

Cancellation from the menu exits without creating a worktree, state
directory, or Docker container. Ctrl-C exits with status `130`.

## Security model

Claude runs with `--dangerously-skip-permissions`, matching the current Codex
`--yolo` posture. Docker remains the outer isolation boundary.

The integration does not add:

- Docker socket access;
- privileged mode;
- host SSH/GPG agents or private keys;
- a complete home-directory mount;
- a complete `~/.claude` mount;
- automatic access to unrelated profiles or states.

Claude can modify the checkout, necessary Git metadata, per-repository build
cache, its selected state directory, and the OAuth credential file in
subscription mode. It can read the selected API profile. It cannot read other
profile files or other Claude state leaves unless the user explicitly adds a
bind mount.

The existing clipboard warning continues to apply: display socket forwarding
allows container processes to interact with the host clipboard protocol.

## Backward compatibility

- Existing `docker-codex` command syntax remains accepted.
- Codex continues to share the host Codex home exactly as before.
- Existing worktree, PAT, bind, cache, clipboard, and image options retain
  their behavior.
- Legacy `DOCKER_CODEX_*` configuration remains a fallback for corresponding
  behavior.
- The first multi-agent version keeps the existing `/codex-cache` path and
  cache-volume naming to avoid discarding large dependency caches solely for a
  naming change.
- No existing Codex state is migrated automatically.

The repository itself does not need to be renamed as part of the functional
change. Documentation presents `docker-agent` as the canonical interface.

## Testing

### Launcher tests

Extend the fake-Docker launcher tests to cover:

- canonical `docker-agent codex` and `docker-agent claude` dispatch;
- basename compatibility for `docker-codex` and `docker-claude`;
- unchanged Codex argument ordering;
- all three direct Claude selectors;
- mutual-exclusion and missing-value errors;
- non-TTY failure without a selector;
- top-level menu key handling and cancellation;
- custom-profile second-level selection and stable ordering;
- missing and invalid profile diagnostics;
- mode `0600`, ownership, regular-file, symlink, checkout-location, and
  allowlist validation;
- tokens absent from Docker arguments and test logs;
- Claude state mounts for repository, worktree, mode, and profile;
- different same-named paths producing different IDs;
- linked worktrees sharing the repository ID but not the worktree ID;
- identity metadata collision detection;
- OAuth single-file read-write mount;
- Claude-only environment not appearing in Codex launches.

Menu rendering and selection logic must be testable with injected input rather
than depending exclusively on a human PTY.

### Entrypoint tests

Cover:

- parsing every allowed profile key;
- rejecting unknown, duplicate, empty, and conflicting keys;
- preserving literal values without shell execution;
- setting the four separate telemetry/feedback variables;
- disabling the auto-updater separately;
- exporting the Claude locale and timezone;
- selecting the isolated `CLAUDE_CONFIG_DIR`;
- injecting container notes through the Claude CLI flag;
- preserving caller arguments and final exit status;
- keeping secret values out of diagnostics.

### Image tests

Build a fresh image and verify:

- exact Codex and Claude CLI versions;
- both CLIs support amd64 and arm64 image builds;
- `locale -a` contains `en_US.utf8`;
- a Claude-mode process reports `LANG` and `LC_ALL` as `en_US.UTF-8`;
- `locale charmap` reports `UTF-8`;
- `TZ=Etc/UTC date '+%Z %z'` reports `UTC +0000`;
- Claude runs as the mapped non-root UID/GID;
- existing sudo, PATH, Rust, mold, sccache, Python, archive, and clipboard
  smoke tests remain green.

Network inference is not required for the regular image test.

### Manual acceptance

On a real WSL/Linux host:

1. Reuse an existing host Claude subscription credential.
2. Start, resume, and refresh a subscription session.
3. Confirm credential writes work through the single-file bind.
4. Run an Anthropic official API profile.
5. Run the DeepSeek-compatible example profile.
6. Confirm profile secrets do not appear in Docker inspection output.
7. Resume sessions independently in each connection mode.
8. Run two same-named repositories at different paths.
9. Run two worktrees of one repository concurrently.
10. Confirm the Claude container reports UTC and `en_US.UTF-8` while Codex is
    unaffected.

On macOS, verify official API and custom profiles and verify that subscription
reuse fails with the documented Keychain limitation rather than a misleading
credential error.

## Documentation

Update both Chinese and English documentation:

- quick start and installation for `docker-agent`;
- Codex compatibility entrypoints;
- Claude menu and direct selectors;
- creation and protection of `official-api.env` and custom profiles;
- state directory layout and cleanup;
- Linux/WSL OAuth sharing and macOS limitation;
- UTC and locale behavior;
- telemetry and auto-update policy;
- the fact that selected API profiles and OAuth credentials are readable by
  the selected container;
- development commands and manual acceptance steps.

The security documentation must continue to state that both agents run without
their internal permission prompts and can exfiltrate any credential or data
explicitly mounted into their container.

## Acceptance criteria

The feature is complete when:

- a fresh shared image contains pinned, working Codex and Claude CLIs;
- all existing Codex tests and documented workflows remain valid;
- interactive Claude launch presents the two-level menu;
- all three direct Claude connection modes work without a menu;
- state is isolated by repository, worktree, and connection identity;
- same-named paths cannot share state accidentally;
- only the OAuth credential file, not the full host Claude directory, is
  mounted for subscription reuse;
- OAuth credential refresh succeeds through that single-file mount on WSL or
  Linux;
- API profile values do not appear in Docker arguments, inspection
  environment, or logs;
- every Claude process receives the separate update, telemetry, error,
  feedback, UTC, and locale variables;
- no Claude language-response instruction is introduced;
- Chinese and English documentation describe the behavior and security
  boundary;
- shell, entrypoint, image, and manual acceptance checks pass.
