#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/testlib.bash
source "$ROOT/tests/testlib.bash"

make_fake_system_commands() {
  local fake_bin=$1
  local command
  mkdir -p "$fake_bin"
  cat >"$fake_bin/fake-command" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
name=$(basename "$0")
log=${DOCKER_CODEX_TEST_SYSTEM_LOG:?}
printf '<CALL:%s>\n' "$name" >>"$log"
printf '<%s>\n' "$@" >>"$log"

case $name in
  getent)
    if [[ $1 == group && ${FAKE_GROUP_EXISTS:-0} == 1 ]]; then
      printf 'existing:x:%s:\n' "$2"
      exit 0
    fi
    if [[ $1 == passwd && ${FAKE_PASSWD_EXISTS:-0} == 1 ]]; then
      printf 'existing:x:%s:%s::/existing:/bin/bash\n' "$2" "${HOST_GID:-1}"
      exit 0
    fi
    exit 2
    ;;
  groupadd|useradd|usermod|mkdir|chown)
    exit 0
    ;;
  gosu)
    shift
    if [[ ${1:-} == codex && ${2:-} == login && ${3:-} == status ]]; then
      exit "${FAKE_LOGIN_STATUS:-0}"
    fi
    exec "$@"
    ;;
  codex|custom-command)
    printf '<ENV_USER:%s>\n' "${USER:-}" >>"$log"
    printf '<ENV_CARGO_HOME:%s>\n' "${CARGO_HOME:-}" >>"$log"
    printf '<ENV_CARGO_TARGET_DIR:%s>\n' "${CARGO_TARGET_DIR:-}" >>"$log"
    printf '<ENV_XDG_DATA_HOME:%s>\n' "${XDG_DATA_HOME:-}" >>"$log"
    printf '<ENV_NPM_CONFIG_CACHE:%s>\n' "${NPM_CONFIG_CACHE:-}" >>"$log"
    printf '<ENV_PNPM_STORE_DIR:%s>\n' "${npm_config_store_dir:-}" >>"$log"
    exit "${FAKE_FINAL_STATUS:-0}"
    ;;
esac
exit 2
EOF
  chmod +x "$fake_bin/fake-command"
  for command in getent groupadd useradd usermod mkdir chown gosu codex custom-command; do
    ln -s fake-command "$fake_bin/$command"
  done
}

run_entrypoint() {
  local fake_bin=$1 log=$2
  shift 2
  PATH="$fake_bin:$PATH" \
    HOST_UID=${HOST_UID:-12345} \
    HOST_GID=${HOST_GID:-23456} \
    DOCKER_CODEX_TEST_SYSTEM_LOG="$log" \
    "$ROOT/container-entrypoint" "$@"
}

test_missing_uid_and_gid_are_created_without_touching_shared_mounts() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  : >"$log"
  make_fake_system_commands "$fake_bin"

  FAKE_GROUP_EXISTS=0 FAKE_PASSWD_EXISTS=0 \
    run_entrypoint "$fake_bin" "$log" codex --version

  assert_line "<CALL:groupadd>" "$log"
  assert_line "<CALL:useradd>" "$log"
  assert_line "<--groups>" "$log"
  assert_line "<sudo>" "$log"
  assert_line "</home/codex>" "$log"
  assert_line "</codex-cache>" "$log"
  assert_no_line "<-R>" "$log"
  assert_no_line "</codex-home>" "$log"
}

test_existing_gid_is_reused_and_existing_uid_skips_user_creation() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  : >"$log"
  make_fake_system_commands "$fake_bin"

  HOST_UID=501 HOST_GID=20 FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=0 \
    run_entrypoint "$fake_bin" "$log" custom-command

  assert_no_line "<CALL:groupadd>" "$log"
  assert_line "<CALL:useradd>" "$log"
  assert_no_line "<login>" "$log"

  : >"$log"
  HOST_UID=1000 HOST_GID=1000 FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" custom-command

  assert_no_line "<CALL:groupadd>" "$log"
  assert_no_line "<CALL:useradd>" "$log"
  assert_line "<CALL:usermod>" "$log"
  assert_line "<--append>" "$log"
  assert_line "<--groups>" "$log"
  assert_line "<sudo>" "$log"
  assert_line "<existing>" "$log"
  assert_no_line "<login>" "$log"
}

test_login_failure_warns_but_still_runs_codex() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  local errors="$TEST_TMP/errors"
  : >"$log"
  make_fake_system_commands "$fake_bin"

  FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 FAKE_LOGIN_STATUS=1 \
    run_entrypoint "$fake_bin" "$log" codex --version 2>"$errors"

  assert_contains "host keyrings cannot" "$errors"
  assert_line "<--version>" "$log"
}

test_final_command_exit_status_is_preserved() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  local status
  : >"$log"
  make_fake_system_commands "$fake_bin"

  set +e
  FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 FAKE_FINAL_STATUS=17 \
    run_entrypoint "$fake_bin" "$log" custom-command
  status=$?
  set -e

  [[ $status == 17 ]] ||
    fail "expected final status 17, got $status"
}

test_existing_user_and_package_caches_are_exported_consistently() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  : >"$log"
  make_fake_system_commands "$fake_bin"

  HOST_UID=1000 HOST_GID=1000 FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" custom-command

  assert_line "<ENV_USER:existing>" "$log"
  assert_line "<ENV_CARGO_HOME:/codex-cache/cargo-home>" "$log"
  assert_line "<ENV_XDG_DATA_HOME:/codex-cache/xdg-data>" "$log"
  assert_line "<ENV_NPM_CONFIG_CACHE:/codex-cache/npm>" "$log"
  assert_line "<ENV_PNPM_STORE_DIR:/codex-cache/pnpm-store>" "$log"
  assert_line "<CALL:usermod>" "$log"
  assert_line "<--home>" "$log"
  assert_line "<existing>" "$log"
}

test_cargo_target_dir_is_scoped_per_worktree() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  local repo="$TEST_TMP/work tree"
  local plain="$TEST_TMP/plain dir"
  local root expected
  : >"$log"
  make_fake_system_commands "$fake_bin"
  make_repo "$repo"

  (
    cd "$repo"
    HOST_UID=1000 HOST_GID=1000 FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
      run_entrypoint "$fake_bin" "$log" custom-command
  )
  root=$(git -C "$repo" rev-parse --show-toplevel)
  expected="/codex-cache/cargo-targets/$(basename "$root")-$(printf '%s' "$root" | sha256sum | cut -c1-16)"
  assert_line "<ENV_CARGO_TARGET_DIR:$expected>" "$log"
  assert_line "<ENV_CARGO_HOME:/codex-cache/cargo-home>" "$log"

  mkdir -p "$plain"
  : >"$log"
  (
    cd "$plain"
    HOST_UID=1000 HOST_GID=1000 FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
      run_entrypoint "$fake_bin" "$log" custom-command
  )
  root=$(cd "$plain" && pwd -P)
  expected="/codex-cache/cargo-targets/$(basename "$root")-$(printf '%s' "$root" | sha256sum | cut -c1-16)"
  assert_line "<ENV_CARGO_TARGET_DIR:$expected>" "$log"
}

test_agent_notes_are_injected_into_codex_invocation() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  local notes="$TEST_TMP/agent-notes.md"
  : >"$log"
  make_fake_system_commands "$fake_bin"
  printf 'test container notes\n' >"$notes"

  DOCKER_CODEX_AGENT_NOTES=$notes FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" codex --version

  assert_ordered_lines "$log" \
    "<codex>" \
    "<-c>" \
    "<user_instructions=test container notes>" \
    "<--version>"

  : >"$log"
  DOCKER_CODEX_AGENT_NOTES="$TEST_TMP/missing" \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" codex --version

  assert_no_line "<-c>" "$log"
  assert_ordered_lines "$log" "<codex>" "<--version>"
}

init_tests
test_missing_uid_and_gid_are_created_without_touching_shared_mounts
test_existing_gid_is_reused_and_existing_uid_skips_user_creation
test_login_failure_warns_but_still_runs_codex
test_final_command_exit_status_is_preserved
test_existing_user_and_package_caches_are_exported_consistently
test_cargo_target_dir_is_scoped_per_worktree
test_agent_notes_are_injected_into_codex_invocation
printf 'entrypoint tests: PASS\n'
