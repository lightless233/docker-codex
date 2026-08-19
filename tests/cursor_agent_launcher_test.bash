#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/testlib.bash
source "$ROOT/tests/testlib.bash"

api_key_path() {
  printf '%s\n' "$TEST_AGENT_CONFIG_HOME/cursor-agent/api-key"
}

write_api_key() {
  local path
  path=$(api_key_path)
  install -d -m 700 "$(dirname "$path")"
  install -m 600 /dev/null "$path"
  printf '%s' "${1:-test-api-key}" >"$path"
}

run_cursor_launcher() {
  local directory=$1
  shift
  run_named_launcher "$directory" "$ROOT" docker-cursor-agent "$@"
}

test_both_entrypoints_dispatch_cursor_agent() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  write_api_key

  run_cursor_launcher "$repo" -- --version
  assert_ordered_lines "$TEST_DOCKER_LOG" \
    "<cursor-agent>" "<--disable-auto-update>" "<--force>" "<--version>"

  : >"$TEST_DOCKER_LOG"
  run_named_launcher "$repo" "$ROOT" docker-agent cursor-agent -- --version
  assert_ordered_lines "$TEST_DOCKER_LOG" \
    "<cursor-agent>" "<--disable-auto-update>" "<--force>" "<--version>"
}

test_api_key_is_mounted_read_only_and_never_passed_as_a_value() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  write_api_key super-secret-key-value

  run_cursor_launcher "$repo"

  assert_line \
    "<type=bind,source=$(api_key_path),target=/run/docker-agent/cursor-api-key,readonly>" \
    "$TEST_DOCKER_LOG"
  assert_line \
    "<DOCKER_AGENT_CURSOR_API_KEY_FILE=/run/docker-agent/cursor-api-key>" \
    "$TEST_DOCKER_LOG"
  # The key itself must never reach the docker command line.
  assert_not_contains "super-secret-key-value" "$TEST_DOCKER_LOG"
  assert_not_contains "CURSOR_API_KEY=" "$TEST_DOCKER_LOG"
}

test_shared_data_root_is_mounted_so_trust_and_sessions_persist() {
  local TEST_TMP mode
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  write_api_key

  [[ ! -e $TEST_CURSOR_HOME ]] ||
    fail "the fake runtime should start without a Cursor data directory"

  run_cursor_launcher "$repo"

  # Cursor stores the workspace-trust marker and session history under
  # .cursor/projects, so without sharing this directory every launch would
  # prompt for trust again and lose all history.
  assert_line "<type=bind,source=$TEST_CURSOR_HOME,target=/cursor-home>" \
    "$TEST_DOCKER_LOG"
  assert_line "<DOCKER_AGENT_CURSOR_HOME_MOUNT=/cursor-home>" \
    "$TEST_DOCKER_LOG"
  [[ -d $TEST_CURSOR_HOME ]] ||
    fail "the launcher did not create the Cursor data directory"
  mode=$(file_mode "$TEST_CURSOR_HOME")
  [[ $mode == 700 ]] ||
    fail "the Cursor data directory has mode $mode instead of 700"
}

test_existing_cursor_data_root_is_reused() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  write_api_key
  install -d -m 700 "$TEST_CURSOR_HOME/projects/existing-project"
  : >"$TEST_CURSOR_HOME/projects/existing-project/.workspace-trusted"

  run_cursor_launcher "$repo"

  assert_line "<type=bind,source=$TEST_CURSOR_HOME,target=/cursor-home>" \
    "$TEST_DOCKER_LOG"
  [[ -e $TEST_CURSOR_HOME/projects/existing-project/.workspace-trusted ]] ||
    fail "the launcher disturbed an existing trust marker"
}

test_a_file_at_the_cursor_data_root_path_is_rejected() {
  local TEST_TMP errors
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  write_api_key
  errors="$TEST_TMP/errors"
  : >"$TEST_CURSOR_HOME"

  if run_cursor_launcher "$repo" >"$errors" 2>&1; then
    fail "a regular file at the data root path unexpectedly succeeded"
  fi
  assert_contains "Cursor data directory is not a directory" "$errors"
}

test_missing_or_unsafe_api_key_is_rejected() {
  local TEST_TMP errors path
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  errors="$TEST_TMP/errors"
  path=$(api_key_path)

  if run_cursor_launcher "$repo" >"$errors" 2>&1; then
    fail "a missing API key unexpectedly succeeded"
  fi
  # The error has to be actionable on its own: there is no setup command.
  assert_contains "Cursor API key does not exist" "$errors"
  assert_contains "https://cursor.com/dashboard/api" "$errors"
  assert_contains "install -m 600 /dev/null" "$errors"
  assert_contains "read -rs key" "$errors"
  assert_contains "$(api_key_path)" "$errors"

  write_api_key
  chmod 644 "$path"
  if run_cursor_launcher "$repo" >"$errors" 2>&1; then
    fail "a world-readable API key unexpectedly succeeded"
  fi
  assert_contains "Cursor API key must have mode 600" "$errors"

  chmod 600 "$path"
  : >"$path"
  if run_cursor_launcher "$repo" >"$errors" 2>&1; then
    fail "an empty API key unexpectedly succeeded"
  fi
  assert_contains "Cursor API key file is empty" "$errors"

  write_api_key
  rm -f "$path"
  ln -s /dev/null "$path"
  if run_cursor_launcher "$repo" >"$errors" 2>&1; then
    fail "a symlinked API key unexpectedly succeeded"
  fi
  assert_contains "Cursor API key must not be a symlink" "$errors"
}

test_caller_supplied_permission_flags_suppress_the_default_force() {
  local TEST_TMP flag
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  write_api_key

  for flag in -f --force --yolo --auto-review; do
    : >"$TEST_DOCKER_LOG"
    run_cursor_launcher "$repo" -- "$flag"
    assert_line "<cursor-agent>" "$TEST_DOCKER_LOG"
    assert_line "<--disable-auto-update>" "$TEST_DOCKER_LOG"
    assert_line "<$flag>" "$TEST_DOCKER_LOG"
    if [[ $flag != --force ]]; then
      assert_no_line "<--force>" "$TEST_DOCKER_LOG"
    fi
  done
}

test_auto_update_is_always_disabled() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  write_api_key

  # The image pins a version; a self-update at runtime would defeat that.
  run_cursor_launcher "$repo" -- -p "task"
  assert_ordered_lines "$TEST_DOCKER_LOG" \
    "<cursor-agent>" "<--disable-auto-update>" "<--force>" "<-p>" "<task>"
}

test_cli_worktree_flag_warns_but_still_passes_through() {
  local TEST_TMP errors
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  write_api_key
  errors="$TEST_TMP/errors"

  run_cursor_launcher "$repo" -- -w probe 2>"$errors"

  assert_contains "WARNING: CURSOR AGENT WORKTREE" "$errors"
  assert_contains "--isolated NAME" "$errors"
  # The flag is still forwarded; the launcher only warns.
  assert_ordered_lines "$TEST_DOCKER_LOG" "<cursor-agent>" "<-w>" "<probe>"

  : >"$errors"
  run_cursor_launcher "$repo" -- --version 2>"$errors"
  assert_not_contains "WARNING: CURSOR AGENT WORKTREE" "$errors"
}

test_claude_only_selectors_are_rejected() {
  local TEST_TMP errors
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  write_api_key
  errors="$TEST_TMP/errors"

  if run_cursor_launcher "$repo" --official-subscription >"$errors" 2>&1; then
    fail "--official-subscription unexpectedly succeeded for Cursor Agent"
  fi
  assert_contains "--official-subscription is only valid for Claude" "$errors"

  if run_cursor_launcher "$repo" --create-profile >"$errors" 2>&1; then
    fail "--create-profile unexpectedly succeeded for Cursor Agent"
  fi
  assert_contains "--create-profile is only valid for Codex or Claude" "$errors"
}

test_shared_launcher_options_apply_to_cursor_agent() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local extra="$TEST_TMP/extra"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  write_api_key
  mkdir -p "$extra"

  run_cursor_launcher "$repo" --bind "$extra:ro" --network extra-net \
    --env CURSOR_TEST_VALUE=1 -- --version

  assert_line "<type=bind,source=$extra,target=$extra,readonly>" \
    "$TEST_DOCKER_LOG"
  assert_line "<extra-net>" "$TEST_DOCKER_LOG"
  assert_line "<CURSOR_TEST_VALUE=1>" "$TEST_DOCKER_LOG"
  assert_line "<type=bind,source=$repo,target=$repo>" "$TEST_DOCKER_LOG"
}

test_help_describes_the_cursor_agent_launcher() {
  local TEST_TMP output
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  output="$TEST_TMP/help"

  # Help must work before any API key exists.
  run_cursor_launcher "$repo" --help >"$output"

  assert_contains "Usage: docker-cursor-agent" "$output"
  assert_contains "docker-agent cursor-agent" "$output"
  assert_contains "CURSOR_API_KEY" "$output"

  run_named_launcher "$repo" "$ROOT" docker-agent --help >"$output"
  assert_contains "docker-agent cursor-agent" "$output"
}

init_tests
test_both_entrypoints_dispatch_cursor_agent
test_shared_data_root_is_mounted_so_trust_and_sessions_persist
test_existing_cursor_data_root_is_reused
test_a_file_at_the_cursor_data_root_path_is_rejected
test_api_key_is_mounted_read_only_and_never_passed_as_a_value
test_missing_or_unsafe_api_key_is_rejected
test_caller_supplied_permission_flags_suppress_the_default_force
test_auto_update_is_always_disabled
test_cli_worktree_flag_warns_but_still_passes_through
test_claude_only_selectors_are_rejected
test_shared_launcher_options_apply_to_cursor_agent
test_help_describes_the_cursor_agent_launcher
printf 'cursor agent launcher tests: PASS\n'
