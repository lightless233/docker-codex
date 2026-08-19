#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/testlib.bash
source "$ROOT/tests/testlib.bash"

test_installer_copies_all_launchers_from_any_working_directory() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local prefix="$TEST_TMP/install prefix"
  local elsewhere="$TEST_TMP/elsewhere"
  local name installed mode
  mkdir -p "$elsewhere"

  (
    cd "$elsewhere"
    "$ROOT/install.sh" --skip-build --prefix "$prefix"
  )

  for name in docker-agent docker-codex docker-claude docker-kimi docker-cursor-agent; do
    installed="$prefix/bin/$name"
    [[ -f $installed && ! -L $installed ]] ||
      fail "$name was not installed as a regular file"
    [[ -x $installed ]] || fail "$name is not executable"
    if stat -c %a "$installed" >/dev/null 2>&1; then
      mode=$(stat -c %a "$installed")
    else
      mode=$(stat -f %Lp "$installed")
    fi
    [[ $mode == 755 ]] ||
      fail "$name does not have mode 755"
    cmp -s "$ROOT/docker-agent" "$installed" ||
      fail "$name does not match docker-agent"
  done

  assert_contains "Usage: docker-agent" \
    <("$prefix/bin/docker-agent" --help)
  assert_contains "Usage: docker-codex" \
    <("$prefix/bin/docker-codex" --help)
  assert_contains "--repair-sessions" \
    <("$prefix/bin/docker-codex" --help)
  assert_contains "Usage: docker-claude" \
    <("$prefix/bin/docker-claude" --help)
  assert_contains "Usage: docker-kimi" \
    <("$prefix/bin/docker-kimi" --help)
  assert_contains "Usage: docker-cursor-agent" \
    <("$prefix/bin/docker-cursor-agent" --help)
}

test_installer_builds_image_after_checking_dependencies() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local prefix="$TEST_TMP/prefix"
  local fake_docker="$TEST_TMP/docker"
  local docker_log="$TEST_TMP/docker.log"
  : >"$docker_log"
  make_fake_docker "$fake_docker"

  DOCKER_AGENT_DOCKER_BIN="$fake_docker" \
    DOCKER_AGENT_TEST_DOCKER_LOG="$docker_log" \
    "$ROOT/install.sh" --prefix "$prefix"

  assert_ordered_lines "$docker_log" \
    '<buildx>' \
    '<version>' \
    '<info>' \
    '<build>' \
    '<--tag>' \
    '<docker-agent:local>' \
    "<$ROOT>"
  [[ -x $prefix/bin/docker-agent ]] ||
    fail "default installation did not install docker-agent"
}

test_installer_skip_build_does_not_require_docker() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local prefix="$TEST_TMP/prefix"

  DOCKER_AGENT_DOCKER_BIN="$TEST_TMP/missing-docker" \
    "$ROOT/install.sh" --skip-build --prefix "$prefix"

  [[ -x $prefix/bin/docker-agent ]] ||
    fail "--skip-build did not install docker-agent"
}

test_installer_reports_missing_docker_cli_before_installing() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local prefix="$TEST_TMP/prefix"
  local missing_docker="$TEST_TMP/missing-docker"
  local errors="$TEST_TMP/errors"

  if DOCKER_AGENT_DOCKER_BIN="$missing_docker" \
      "$ROOT/install.sh" --prefix "$prefix" >"$errors" 2>&1; then
    fail "installation without the Docker CLI unexpectedly succeeded"
  fi

  assert_contains "Docker CLI not found: $missing_docker" "$errors"
  [[ ! -e $prefix ]] || fail "Docker CLI failure created the install prefix"
}

test_installer_reports_missing_buildx_before_installing() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local prefix="$TEST_TMP/prefix"
  local fake_docker="$TEST_TMP/docker"
  local docker_log="$TEST_TMP/docker.log"
  local errors="$TEST_TMP/errors"
  : >"$docker_log"
  make_fake_docker "$fake_docker"

  if DOCKER_AGENT_DOCKER_BIN="$fake_docker" \
      DOCKER_AGENT_TEST_DOCKER_LOG="$docker_log" \
      DOCKER_AGENT_TEST_BUILDX_STATUS=1 \
      "$ROOT/install.sh" --prefix "$prefix" >"$errors" 2>&1; then
    fail "installation without Buildx unexpectedly succeeded"
  fi

  assert_contains "Docker Buildx is required" "$errors"
  assert_contains "brew install docker-buildx" "$errors"
  assert_line '<buildx>' "$docker_log"
  assert_no_line '<info>' "$docker_log"
  [[ ! -e $prefix ]] || fail "Buildx failure created the install prefix"
}

test_installer_reports_unavailable_daemon_before_installing() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local prefix="$TEST_TMP/prefix"
  local fake_docker="$TEST_TMP/docker"
  local docker_log="$TEST_TMP/docker.log"
  local errors="$TEST_TMP/errors"
  : >"$docker_log"
  make_fake_docker "$fake_docker"

  if DOCKER_AGENT_DOCKER_BIN="$fake_docker" \
      DOCKER_AGENT_TEST_DOCKER_LOG="$docker_log" \
      DOCKER_AGENT_TEST_INFO_STATUS=1 \
      "$ROOT/install.sh" --prefix "$prefix" >"$errors" 2>&1; then
    fail "installation without a Docker daemon unexpectedly succeeded"
  fi

  assert_contains "Docker daemon is unavailable" "$errors"
  assert_ordered_lines "$docker_log" '<buildx>' '<version>' '<info>'
  assert_no_line '<build>' "$docker_log"
  [[ ! -e $prefix ]] || fail "daemon failure created the install prefix"
}

test_installer_rejects_sudo_for_the_build_phase() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local prefix="$TEST_TMP/prefix"
  local fake_bin="$TEST_TMP/bin"
  local errors="$TEST_TMP/errors"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "0\\n"' \
    >"$fake_bin/id"
  chmod +x "$fake_bin/id"

  if PATH="$fake_bin:$PATH" SUDO_USER=test-user \
      DOCKER_AGENT_DOCKER_BIN="$TEST_TMP/missing-docker" \
      "$ROOT/install.sh" --prefix "$prefix" >"$errors" 2>&1; then
    fail "sudo installation unexpectedly reached the build phase"
  fi

  assert_contains "do not run this installer with sudo" "$errors"
  assert_contains "run ./install.sh" "$errors"
  [[ ! -e $prefix ]] || fail "sudo rejection created the install prefix"
}

test_installer_uses_sudo_only_for_protected_install_steps() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local prefix="$TEST_TMP/prefix"
  local fake_bin="$TEST_TMP/bin"
  local fake_docker="$TEST_TMP/docker"
  local docker_log="$TEST_TMP/docker.log"
  local sudo_log="$TEST_TMP/sudo.log"
  local real_install
  real_install=$(command -v install)
  mkdir -p "$fake_bin"
  : >"$docker_log"
  : >"$sudo_log"
  make_fake_docker "$fake_docker"

  # shellcheck disable=SC2016 # Variables expand when the generated fake runs.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[[ ${DOCKER_AGENT_TEST_ELEVATED:-0} == 1 ]] || exit 1' \
    'exec "$DOCKER_AGENT_TEST_REAL_INSTALL" "$@"' \
    >"$fake_bin/install"
  # shellcheck disable=SC2016 # Variables expand when the generated fake runs.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "CALL\\n" >>"$DOCKER_AGENT_TEST_SUDO_LOG"' \
    'printf "<%s>\\n" "$@" >>"$DOCKER_AGENT_TEST_SUDO_LOG"' \
    'export DOCKER_AGENT_TEST_ELEVATED=1' \
    'exec "$@"' \
    >"$fake_bin/sudo"
  chmod +x "$fake_bin/install" "$fake_bin/sudo"

  PATH="$fake_bin:$PATH" \
    DOCKER_AGENT_DOCKER_BIN="$fake_docker" \
    DOCKER_AGENT_TEST_DOCKER_LOG="$docker_log" \
    DOCKER_AGENT_TEST_REAL_INSTALL="$real_install" \
    DOCKER_AGENT_TEST_SUDO_LOG="$sudo_log" \
    "$ROOT/install.sh" --prefix "$prefix"

  assert_line '<build>' "$docker_log"
  assert_contiguous_lines "$sudo_log" '<install>' '<-d>' "<$prefix/bin>"
  assert_not_contains "$fake_docker" "$sudo_log"
  [[ -x $prefix/bin/docker-agent ]] ||
    fail "sudo-assisted installation did not install docker-agent"
}

test_installer_rejects_invalid_arguments_without_installing() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local prefix="$TEST_TMP/prefix"
  local errors="$TEST_TMP/errors"

  if "$ROOT/install.sh" --unknown >"$errors" 2>&1; then
    fail "unknown installer option unexpectedly succeeded"
  fi
  assert_contains "unknown option: --unknown" "$errors"

  if "$ROOT/install.sh" --prefix >"$errors" 2>&1; then
    fail "missing prefix value unexpectedly succeeded"
  fi
  assert_contains "--prefix requires a value" "$errors"
  [[ ! -e $prefix ]] || fail "invalid invocation created an install prefix"
}

test_installer_help_documents_system_and_user_prefixes() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local output="$TEST_TMP/help"

  "$ROOT/install.sh" --help >"$output"

  assert_contains "Usage: install.sh [--prefix PREFIX] [--skip-build]" "$output"
  assert_contains "Default: /usr/local" "$output"
  assert_contains "--skip-build" "$output"
  assert_contains "./install.sh" "$output"
  assert_contains "--prefix \"\$HOME/.local\"" "$output"
  assert_not_contains "sudo ./install.sh" "$output"
}

init_tests
test_installer_copies_all_launchers_from_any_working_directory
test_installer_builds_image_after_checking_dependencies
test_installer_skip_build_does_not_require_docker
test_installer_reports_missing_docker_cli_before_installing
test_installer_reports_missing_buildx_before_installing
test_installer_reports_unavailable_daemon_before_installing
test_installer_rejects_sudo_for_the_build_phase
test_installer_uses_sudo_only_for_protected_install_steps
test_installer_rejects_invalid_arguments_without_installing
test_installer_help_documents_system_and_user_prefixes
printf 'install tests: ok\n'
