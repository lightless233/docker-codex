#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DOCKER_BIN=${DOCKER_AGENT_DOCKER_BIN:-${DOCKER_CODEX_DOCKER_BIN:-docker}}
IMAGE=${DOCKER_AGENT_BASH32_IMAGE:-bash:3.2}

"$DOCKER_BIN" run --rm \
  --volume "$ROOT:/repo:ro" \
  --workdir /repo \
  "$IMAGE" \
  -c 'apk add --no-cache coreutils git ncurses python3 util-linux >/dev/null
      tests/run.bash'

printf 'Bash 3.2 compatibility tests: PASS\n'
