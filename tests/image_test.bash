#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/testlib.bash
source "$ROOT/tests/testlib.bash"

DOCKER_BIN=${DOCKER_CODEX_DOCKER_BIN:-docker}
IMAGE=${DOCKER_CODEX_TEST_IMAGE:-docker-codex:local}

test_debian_and_official_node_runtime() {
  "$DOCKER_BIN" image inspect "$IMAGE" >/dev/null
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm --entrypoint bash "$IMAGE" -lc '
    set -euo pipefail
    source /etc/os-release
    [[ $ID == debian ]]
    [[ $VERSION_ID == 13 ]]
    [[ $(node --version) == v24.18.0 ]]
    if dpkg-query --show nodejs npm >/dev/null 2>&1; then
      printf "%s\n" "nodejs/npm unexpectedly installed through dpkg" >&2
      exit 1
    fi
  '
}

test_runtime_user_has_passwordless_sudo_without_root_group() {
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    "$IMAGE" \
    bash -lc '
      set -euo pipefail
      [[ $(id -u) == 12345 ]]
      [[ $(id -g) == 23456 ]]
      ! id -G | tr " " "\n" | grep -qx 0
      sudo -n true
    '
}

init_tests
test_debian_and_official_node_runtime
test_runtime_user_has_passwordless_sudo_without_root_group
printf 'image tests: PASS\n'
