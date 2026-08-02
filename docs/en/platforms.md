# Platform notes

This page covers platform differences and caveats on Linux/WSL2 and macOS
hosts. Clipboard forwarding (including the `powershell.exe` shim on WSL) is
documented separately in [clipboard.md](clipboard.md).

## Shared Docker network

Codex and Claude containers join a persistent `docker-agent` bridge network by
default. The launcher creates it when missing and does not remove it when the
agent exits. Other development services can join the same network:

```bash
docker run -d --name project-pg --network docker-agent \
  -e POSTGRES_PASSWORD=change-me postgres:17
```

The agent can then reach PostgreSQL at `project-pg:5432`. Repeat
`--network NAME` to join additional networks, or use
`--disable-default-network` to skip the shared network. The special `host` and
`none` modes require `--disable-default-network` and cannot be combined with
other networks.

The default network is shared by every docker-agent instance. Containers that
join it can reach ports exposed by other members of that network.

## Linux and WSL2

The entrypoint maps the container process to the host numeric UID/GID and adds
`host.docker.internal` through Docker's `host-gateway`. Keep WSL2 checkouts in
the Linux filesystem rather than `/mnt/c` when build performance matters.

Linux/WSL can mount the host Claude Code `.credentials.json` as a single file
with `--official-subscription`; see [Claude Code integration](claude.md) for
the required path and permissions.

## macOS

Docker Desktop must allow file sharing for the checkout, external Git metadata,
Codex home, and every `--bind` source. Paths below `/Users` are normally covered
by the default Docker Desktop settings.

The entrypoint handles common macOS identities such as UID 501/GID 20 without
assuming the group name is unused. Host Keychain credentials remain outside
the container. Claude subscription mode fails explicitly; use an API profile.

On Apple Silicon, a local build produces a native Linux arm64 image. If a
project specifically needs a Linux amd64 development environment, select it
explicitly, for example:

```bash
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker build -t docker-agent:local .
```

Emulated amd64 builds and workloads are slower.

---

Back to [README](../../README.en.md)
