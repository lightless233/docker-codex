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

test_login_shell_keeps_toolchain_on_path() {
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    "$IMAGE" \
    bash -lc '
      set -euo pipefail
      [[ :$PATH: == *:/usr/local/cargo/bin:* ]]
      [[ :$PATH: == *:/codex-cache/pnpm:* ]]
      command -v cargo rustc rustfmt cargo-clippy pnpm >/dev/null
    '
}

test_python_and_archive_tools_are_available() {
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm --entrypoint bash "$IMAGE" -c '
    set -euo pipefail
    command -v python3 python pip3 unzip zip >/dev/null
    python3 -m venv --help >/dev/null
  '
}

test_mold_is_default_linker_and_sccache_is_available() {
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    "$IMAGE" \
    bash -lc '
      set -euo pipefail
      command -v mold sccache >/dev/null
      [[ $RUSTFLAGS == *fuse-ld=mold* ]]
      work=$(mktemp -d)
      cd "$work"
      cargo init -q --vcs none --name mold-smoke
      cargo run -q
    '
}

init_tests
test_debian_and_official_node_runtime
test_runtime_user_has_passwordless_sudo_without_root_group
test_login_shell_keeps_toolchain_on_path
test_python_and_archive_tools_are_available
test_mold_is_default_linker_and_sccache_is_available
printf 'image tests: PASS\n'
