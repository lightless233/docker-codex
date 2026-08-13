#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/testlib.bash
source "$ROOT/tests/testlib.bash"

run_kimi_launcher() {
  local directory=$1
  shift
  run_named_launcher "$directory" "$ROOT" docker-kimi "$@"
}

test_both_entrypoints_dispatch_kimi() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  run_kimi_launcher "$repo" -- --version
  assert_ordered_lines "$TEST_DOCKER_LOG" "<kimi>" "<--yolo>" "<--version>"

  : >"$TEST_DOCKER_LOG"
  run_named_launcher "$repo" "$ROOT" docker-agent kimi -- --version
  assert_ordered_lines "$TEST_DOCKER_LOG" "<kimi>" "<--yolo>" "<--version>"
}

test_data_root_is_shared_with_the_container() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  run_kimi_launcher "$repo"

  assert_line "<type=bind,source=$TEST_KIMI_HOME,target=/kimi-home>" \
    "$TEST_DOCKER_LOG"
  assert_line "<KIMI_CODE_HOME=/kimi-home>" "$TEST_DOCKER_LOG"
  # The shared data root carries the login, so no separate credential file or
  # per-worktree state directory is mounted the way Claude needs.
  assert_not_contains "target=/claude-state" "$TEST_DOCKER_LOG"
  assert_not_contains "target=/codex-home" "$TEST_DOCKER_LOG"
}

test_missing_host_data_root_is_created_with_private_mode() {
  local TEST_TMP mode
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  [[ ! -e $TEST_KIMI_HOME ]] ||
    fail "the fake runtime should start without a Kimi Code data root"

  run_kimi_launcher "$repo"

  [[ -d $TEST_KIMI_HOME ]] ||
    fail "the launcher did not create the Kimi Code data root"
  mode=$(file_mode "$TEST_KIMI_HOME")
  [[ $mode == 700 ]] ||
    fail "the Kimi Code data root has mode $mode instead of 700"
}

test_existing_host_data_root_is_reused() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  install -d -m 700 "$TEST_KIMI_HOME"
  printf '%s\n' 'default_model = "kimi"' >"$TEST_KIMI_HOME/config.toml"

  run_kimi_launcher "$repo"

  assert_line "<type=bind,source=$TEST_KIMI_HOME,target=/kimi-home>" \
    "$TEST_DOCKER_LOG"
  assert_contains 'default_model = "kimi"' "$TEST_KIMI_HOME/config.toml"
}

test_a_file_at_the_data_root_path_is_rejected() {
  local TEST_TMP errors
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  errors="$TEST_TMP/errors"
  : >"$TEST_KIMI_HOME"

  if run_kimi_launcher "$repo" >"$errors" 2>&1; then
    fail "a regular file at the data root path unexpectedly succeeded"
  fi
  assert_contains "Kimi Code home is not a directory" "$errors"
}

test_caller_supplied_mode_flags_suppress_the_default_yolo() {
  local TEST_TMP flag
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  # Kimi Code rejects --yolo alongside these, so the launcher must not add it.
  for flag in -p --prompt --auto --plan -y --yolo; do
    : >"$TEST_DOCKER_LOG"
    run_kimi_launcher "$repo" -- "$flag" task
    assert_line "<kimi>" "$TEST_DOCKER_LOG"
    assert_line "<$flag>" "$TEST_DOCKER_LOG"
    if [[ $flag != -y && $flag != --yolo ]]; then
      assert_no_line "<--yolo>" "$TEST_DOCKER_LOG"
    fi
  done

  : >"$TEST_DOCKER_LOG"
  run_kimi_launcher "$repo" -- --prompt=task
  assert_no_line "<--yolo>" "$TEST_DOCKER_LOG"
  assert_line "<--prompt=task>" "$TEST_DOCKER_LOG"
}

test_unrelated_arguments_keep_the_default_yolo() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  run_kimi_launcher "$repo" -- --model kimi-k3
  assert_ordered_lines "$TEST_DOCKER_LOG" \
    "<kimi>" "<--yolo>" "<--model>" "<kimi-k3>"
}

test_claude_only_selectors_are_rejected() {
  local TEST_TMP errors selector
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  errors="$TEST_TMP/errors"

  for selector in --official-subscription --official-api; do
    if run_kimi_launcher "$repo" "$selector" >"$errors" 2>&1; then
      fail "$selector unexpectedly succeeded for Kimi Code"
    fi
    assert_contains "$selector is only valid for Claude" "$errors"
  done

  if run_kimi_launcher "$repo" --profile custom >"$errors" 2>&1; then
    fail "--profile unexpectedly succeeded for Kimi Code"
  fi
  assert_contains "--profile is only valid for Claude" "$errors"

  if run_kimi_launcher "$repo" --create-profile >"$errors" 2>&1; then
    fail "--create-profile unexpectedly succeeded for Kimi Code"
  fi
  assert_contains "--create-profile is only valid for Claude" "$errors"
}

test_shared_launcher_options_apply_to_kimi() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local extra="$TEST_TMP/extra"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  mkdir -p "$extra"

  run_kimi_launcher "$repo" --bind "$extra:ro" --network extra-net \
    --env KIMI_TEST_VALUE=1 -- --version

  assert_line "<type=bind,source=$extra,target=$extra,readonly>" \
    "$TEST_DOCKER_LOG"
  assert_line "<--network>" "$TEST_DOCKER_LOG"
  assert_line "<extra-net>" "$TEST_DOCKER_LOG"
  assert_line "<KIMI_TEST_VALUE=1>" "$TEST_DOCKER_LOG"
}

test_help_describes_the_kimi_launcher() {
  local TEST_TMP output
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  output="$TEST_TMP/help"

  run_kimi_launcher "$repo" --help >"$output"

  assert_contains "Usage: docker-kimi" "$output"
  assert_contains "docker-agent kimi" "$output"
  assert_contains "--yolo" "$output"

  run_named_launcher "$repo" "$ROOT" docker-agent --help >"$output"
  assert_contains "docker-agent kimi" "$output"
}

test_unknown_agent_names_are_rejected() {
  local TEST_TMP errors
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  errors="$TEST_TMP/errors"

  if run_named_launcher "$repo" "$ROOT" docker-agent gemini >"$errors" 2>&1; then
    fail "an unknown agent name unexpectedly succeeded"
  fi
  assert_contains "unsupported agent: gemini" "$errors"
}

init_tests
test_both_entrypoints_dispatch_kimi
test_data_root_is_shared_with_the_container
test_missing_host_data_root_is_created_with_private_mode
test_existing_host_data_root_is_reused
test_a_file_at_the_data_root_path_is_rejected
test_caller_supplied_mode_flags_suppress_the_default_yolo
test_unrelated_arguments_keep_the_default_yolo
test_claude_only_selectors_are_rejected
test_shared_launcher_options_apply_to_kimi
test_help_describes_the_kimi_launcher
test_unknown_agent_names_are_rejected
printf 'kimi launcher tests: PASS\n'
