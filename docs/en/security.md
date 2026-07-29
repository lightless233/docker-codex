# Security boundary

This page describes the container's privilege model, the default mount
policy, and what the launcher deliberately never mounts. Read it when
evaluating whether this tool is safe to use with a given project.

The container starts as root only long enough to initialize its private home and
cache directory, then uses `gosu` to run the selected agent as the host numeric UID/GID. It
does not recursively change ownership of the checkout, Git metadata, or Codex
home. This keeps ordinary bind-mount writes owned by the host user.

The runtime user has passwordless sudo inside the container and may obtain
container root when needed. It is not added to the root group.

Codex always receives `--yolo`; Claude always receives
`--dangerously-skip-permissions`. Both disable the agent's internal approvals,
so every read-write mount is fully exposed. Docker remains the outer isolation
boundary; the launcher does not use `--privileged`.

Codex receives the complete host Codex home. Claude does not receive the
complete `~/.claude`: subscription mode mounts one `.credentials.json`, while
API/custom modes mount only the selected profile and use state under the
separate data root. The selected container can read profile secrets and can
read/write the OAuth file so Claude may refresh it. See
[Claude Code integration](claude.md).

The launcher never automatically mounts:

- `/var/run/docker.sock`;
- the host filesystem root or full home;
- the checkout's common parent directory;
- SSH/GPG agents or private keys;
- unrelated repositories.

The selected agent can freely modify every read-write path deliberately mounted into the
container. Docker remains the outer boundary for everything else.

---

Back to [README](../../README.en.md)
