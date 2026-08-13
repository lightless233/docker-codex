# Development and verification

This page explains how to run this project's tests and how to explicitly
change tool versions at image build time. Read it after modifying the
launcher, the Dockerfile, or the entrypoint.

## Build-time version arguments

Build-time versions can be changed explicitly:

```bash
docker build \
  --build-arg NODE_VERSION=24.19.0 \
  --build-arg CODEX_VERSION=0.147.0 \
  --build-arg CLAUDE_CODE_VERSION=2.1.229 \
  --build-arg KIMI_CODE_VERSION=0.36.0 \
  --build-arg CURSOR_AGENT_VERSION=2026.08.11-e8db854 \
  --build-arg PNPM_VERSION=11.21.0 \
  -t docker-agent:local .
```

`NODE_VERSION` upgrades are explicit. The image does not install Node.js or npm
from Debian or third-party package repositories.

Bumping `CURSOR_AGENT_VERSION` requires updating `CURSOR_AGENT_SHA256_AMD64`
and `CURSOR_AGENT_SHA256_ARM64` in the Dockerfile in the same change. Cursor
publishes no checksum, so those digests are maintained here and can be
recomputed with:

```bash
for arch in x64 arm64; do
  curl -fsSL "https://downloads.cursor.com/lab/VERSION/linux/$arch/agent-cli-package.tar.gz" |
    sha256sum
done
```

## Verification

Validate the Dockerfile, build the image, then run shell and real-container tests:

```bash
docker build --check .
docker build -t docker-agent:local .
tests/run.bash
DOCKER_AGENT_TEST_IMAGE=docker-agent:local tests/image_test.bash
```

The test suite uses real temporary Git repositories, linked worktrees, and
submodules while replacing only the external Docker boundary. The separate
image test runs a real container and verifies Debian, Node provenance,
Codex/Claude/Kimi versions, numeric UID/GID, Claude UTC/locale/telemetry
policy, where the Kimi instruction file lands, absence of the root group, and
passwordless sudo. Linux image builds and
runtime smoke tests are part of release verification.

macOS path/argument branches and the multi-architecture image definition are
covered by automated checks. A real macOS Docker Desktop/Apple Silicon runtime
has not yet been exercised by this project and must not be inferred from Linux
test results.

---

Back to [README](../../README.en.md)
