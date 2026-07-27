# Platform notes

This page covers platform differences and caveats on Linux/WSL2 and macOS
hosts. Clipboard forwarding (including the `powershell.exe` shim on WSL) is
documented separately in [clipboard.md](clipboard.md).

## Linux and WSL2

The entrypoint maps the container process to the host numeric UID/GID and adds
`host.docker.internal` through Docker's `host-gateway`. Keep WSL2 checkouts in
the Linux filesystem rather than `/mnt/c` when build performance matters.

## macOS

Docker Desktop must allow file sharing for the checkout, external Git metadata,
Codex home, and every `--bind` source. Paths below `/Users` are normally covered
by the default Docker Desktop settings.

The entrypoint handles common macOS identities such as UID 501/GID 20 without
assuming the group name is unused. Host Keychain credentials remain outside the
container.

On Apple Silicon, a local build produces a native Linux arm64 image. If a
project specifically needs a Linux amd64 development environment, select it
explicitly, for example:

```bash
DOCKER_DEFAULT_PLATFORM=linux/amd64 ./docker-codex --build -- --version
```

Emulated amd64 builds and workloads are slower.

---

Back to [README](../../README.en.md)
