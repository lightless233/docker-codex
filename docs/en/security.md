# Security boundary

This page describes the container's privilege model, the default mount
policy, and what the launcher deliberately never mounts. Read it when
evaluating whether this tool is safe to use with a given project.

The container starts as root only long enough to initialize its private home and
cache directory, then uses `gosu` to run the selected agent as the host numeric UID/GID. It
does not recursively change ownership of the checkout, Git metadata, or the
shared Codex home (including its `/codex-home` compatibility alias). This keeps
ordinary bind-mount writes owned by the host user.

The runtime user has passwordless sudo inside the container and may obtain
container root when needed. It is not added to the root group.

Codex always receives `--yolo`; Claude always receives
`--dangerously-skip-permissions`. Both disable the agent's internal approvals,
so every read-write mount is fully exposed. In the default mode, Docker remains
the outer isolation boundary; the launcher does not use `--privileged`.

Codex receives the complete host Codex home at the same logical absolute path
used by the host. A second mount of the same physical directory at
`/codex-home` only resolves legacy session paths and exposes no additional
data. Managed Codex endpoint profiles live outside this directory; only native
compatibility links live in `CODEX_HOME`. The launcher mounts only the selected
profile's directory read-write so Codex can atomically persist trust and other
interactive config; other managed profiles remain unreachable in the
container. Codex and commands it runs can read or modify the selected plaintext
bearer token. Legacy `$CODEX_HOME/*.config.toml` files are
exposed with the complete directory. Use minimally scoped, revocable keys. See
[Codex custom endpoint profiles](codex.md). Claude does not receive the complete `~/.claude`: subscription mode mounts one `.credentials.json`, while
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

## Explicit host Docker access

`--host-docker` mounts the host Docker Unix socket at
`/var/run/docker.sock`, sets `DOCKER_HOST`, and adds the runtime user to the
socket's numeric GID. The launcher prints a prominent bilingual warning every
time this mode is enabled.

This grants the agent full control of the host Docker API. In addition to all
host containers, images, networks, and volumes, it can create a container that
mounts any host path and then read or modify host files. It is therefore
effectively host-root access. A read-only bind mount does not make the Docker
API read-only, so this project does not offer that misleading mode.

The option does not mount the host `~/.docker`. The default socket is
`/var/run/docker.sock`; unusual environments may select another absolute host
path with `DOCKER_AGENT_DOCKER_SOCKET`. Containers created by the agent do not
automatically join the `docker-agent` network; pass `--network docker-agent`
when creating them if they need to communicate with the agent container.

The selected agent can freely modify every read-write path deliberately mounted into the
container. Docker remains the outer boundary for everything else unless
`--host-docker` is enabled.

---

Back to [README](../../README.en.md)
