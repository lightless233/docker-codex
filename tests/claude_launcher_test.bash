#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/testlib.bash
source "$ROOT/tests/testlib.bash"

PROFILE_PATH=

write_profile() {
  local name=$1
  shift
  PROFILE_PATH="$TEST_AGENT_CONFIG_HOME/claude/profiles/$name.env"
  printf '%s\n' "$@" >"$PROFILE_PATH"
  chmod 600 "$PROFILE_PATH"
}

run_claude_launcher() {
  local repo=$1
  shift
  DOCKER_AGENT_DATA_HOME="$TEST_AGENT_DATA_HOME" \
    run_named_launcher "$repo" "$ROOT" docker-agent claude "$@"
}

run_claude_menu() {
  local repo=$1 keys=$2 menu_log=$3
  shift 3
  (
    exec 9<"$keys"
    exec 8>"$menu_log"
    export DOCKER_AGENT_TEST_FORCE_TTY=1
    export DOCKER_AGENT_MENU_INPUT_FD=9
    export DOCKER_AGENT_MENU_OUTPUT_FD=8
    DOCKER_AGENT_DATA_HOME="$TEST_AGENT_DATA_HOME" \
      run_named_launcher "$repo" "$ROOT" docker-agent claude "$@"
  )
}

wait_for_profile_output() {
  local output=$1 expected=$2 done_file=$3
  local attempt
  for ((attempt = 0; attempt < 500; attempt++)); do
    grep -Fq -- "$expected" "$output" 2>/dev/null && return 0
    [[ ! -e $done_file ]] || return 1
    sleep 0.01
  done
  fail "timed out waiting for profile creator output: $expected"
}

run_profile_creator() {
  local directory=$1 input=$2 output=$3
  local fifo="$directory/profile-input.fifo"
  local done_file="$directory/profile-done"
  local line pid result

  command -v script >/dev/null 2>&1 ||
    fail "script is required for profile creator PTY tests"
  mkfifo "$fifo"
  exec 7<>"$fifo"
  # shellcheck disable=SC2016 # Variables expand in script's child shell.
  DOCKER_AGENT_CONFIG_HOME="$TEST_AGENT_CONFIG_HOME" \
    DOCKER_AGENT_DOCKER_BIN="$directory/does-not-exist-docker" \
    DOCKER_AGENT_TEST_LAUNCHER="$ROOT/docker-claude" \
    DOCKER_AGENT_TEST_DONE_FILE="$done_file" \
    script -qfec \
      '"$DOCKER_AGENT_TEST_LAUNCHER" --create-profile; result=$?; printf "%s\n" "$result" >"$DOCKER_AGENT_TEST_DONE_FILE"; exit "$result"' \
      /dev/null <&7 >"$output" 2>&1 &
  pid=$!

  exec 9<"$input"
  if wait_for_profile_output "$output" "Profile 名称:" "$done_file"; then
    IFS= read -r line <&9 || line=
    printf '%s\n' "$line" >&7
  fi
  if wait_for_profile_output "$output" "API endpoint:" "$done_file"; then
    IFS= read -r line <&9 || line=
    printf '%s\n' "$line" >&7
  fi
  if wait_for_profile_output "$output" "API key:" "$done_file"; then
    IFS= read -r line <&9 || line=
    printf '%s\n' "$line" >&7
  fi
  exec 9<&-
  exec 7>&-

  if wait "$pid"; then
    result=0
  else
    result=$?
  fi
  rm -f "$fifo" "$done_file"
  return "$result"
}

test_file_mode() {
  if stat -c %a "$1" >/dev/null 2>&1; then
    stat -c %a "$1"
  else
    stat -f %Lp "$1"
  fi
}

state_mount_source() {
  local log=$1 line
  line=$(grep -F 'target=/claude-state>' "$log")
  line=${line#<type=bind,source=}
  printf '%s\n' "${line%,target=/claude-state>}"
}

test_profile_creator_masks_key_and_writes_protected_profile_outside_git() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local outside="$TEST_TMP/not a repository"
  local input="$TEST_TMP/input"
  local output="$TEST_TMP/output"
  local profile
  mkdir -p "$outside"
  prepare_fake_runtime "$TEST_TMP"
  profile="$TEST_AGENT_CONFIG_HOME/claude/profiles/deepseek.env"
  printf '%s\n' \
    'deepseek' \
    'https://api.deepseek.com/anthropic' \
    'secret-key' >"$input"

  run_profile_creator "$outside" "$input" "$output"

  assert_line 'ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic' \
    "$profile"
  assert_line 'ANTHROPIC_AUTH_TOKEN=secret-key' "$profile"
  [[ $(wc -l <"$profile") == 2 ]] ||
    fail "created profile contains unexpected lines"
  [[ $(test_file_mode "$TEST_AGENT_CONFIG_HOME/claude/profiles") == 700 ]] ||
    fail "profile directory does not have mode 700"
  [[ $(test_file_mode "$profile") == 600 ]] ||
    fail "created profile does not have mode 600"
  assert_contains 'API key: **********' "$output"
  assert_not_contains 'secret-key' "$output"
  assert_contains "Profile 已创建：$profile" "$output"
  assert_contains 'docker-claude --profile deepseek' "$output"
  assert_contains '************************************************************' "$output"
  assert_contains '⚠ 重要：尚未配置 ANTHROPIC_MODEL' "$output"
  assert_contains '将使用 Claude 默认模型名' "$output"
  assert_contains "请编辑：$profile" "$output"
  assert_contains 'ANTHROPIC_MODEL=你的模型名称' "$output"
}

test_profile_creator_backspace_removes_masked_character_and_secret_character() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local outside="$TEST_TMP/outside"
  local input="$TEST_TMP/input"
  local output="$TEST_TMP/output"
  local profile
  mkdir -p "$outside"
  prepare_fake_runtime "$TEST_TMP"
  profile="$TEST_AGENT_CONFIG_HOME/claude/profiles/editing.env"
  printf 'editing\nhttps://example.invalid/anthropic\nrightX\177\n' >"$input"

  run_profile_creator "$outside" "$input" "$output"

  assert_line 'ANTHROPIC_AUTH_TOKEN=right' "$profile"
  assert_contains $'API key: ******\b \b' "$output"
  assert_not_contains 'rightX' "$profile"
}

test_profile_creator_refuses_existing_profile_without_modifying_it() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local outside="$TEST_TMP/outside"
  local input="$TEST_TMP/input"
  local output="$TEST_TMP/output"
  local profile expected
  mkdir -p "$outside"
  prepare_fake_runtime "$TEST_TMP"
  profile="$TEST_AGENT_CONFIG_HOME/claude/profiles/deepseek.env"
  expected="$TEST_TMP/expected"
  printf '%s\n' \
    'ANTHROPIC_BASE_URL=https://existing.example.invalid/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=existing-secret' >"$profile"
  chmod 600 "$profile"
  cp "$profile" "$expected"
  printf 'deepseek\n' >"$input"

  if run_profile_creator "$outside" "$input" "$output"; then
    fail "profile creator unexpectedly overwrote an existing profile"
  fi

  assert_contains "Claude profile already exists: $profile" "$output"
  cmp -s "$expected" "$profile" ||
    fail "existing profile content was modified"
  assert_not_contains 'API endpoint:' "$output"
}

test_profile_creator_requires_name_endpoint_key_and_interactive_terminal() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local outside="$TEST_TMP/outside"
  local input="$TEST_TMP/input"
  local output="$TEST_TMP/output"
  local errors="$TEST_TMP/errors"
  mkdir -p "$outside"
  prepare_fake_runtime "$TEST_TMP"

  printf '\n' >"$input"
  if run_profile_creator "$outside" "$input" "$output"; then
    fail "empty profile name unexpectedly succeeded"
  fi
  assert_contains "Profile name is required" "$output"

  printf 'missing-endpoint\n\n' >"$input"
  if run_profile_creator "$outside" "$input" "$output"; then
    fail "empty endpoint unexpectedly succeeded"
  fi
  assert_contains "API endpoint is required" "$output"

  printf 'missing-key\nhttps://example.invalid/anthropic\n\n' >"$input"
  if run_profile_creator "$outside" "$input" "$output"; then
    fail "empty API key unexpectedly succeeded"
  fi
  assert_contains "API key is required" "$output"

  if (
    cd "$outside"
    DOCKER_AGENT_CONFIG_HOME="$TEST_AGENT_CONFIG_HOME" \
      "$ROOT/docker-claude" --create-profile </dev/null
  ) >"$errors" 2>&1; then
    fail "non-interactive profile creation unexpectedly succeeded"
  fi
  assert_contains "interactive terminal" "$errors"

  printf '%s\n' \
    'bypass' \
    'https://example.invalid/anthropic' \
    'bypass-secret' >"$input"
  if (
    cd "$outside"
    exec 9<"$input"
    exec 8>"$output"
    DOCKER_AGENT_CONFIG_HOME="$TEST_AGENT_CONFIG_HOME" \
      DOCKER_AGENT_TEST_FORCE_TTY=1 \
      DOCKER_AGENT_PROFILE_INPUT_FD=9 \
      DOCKER_AGENT_PROFILE_OUTPUT_FD=8 \
      "$ROOT/docker-claude" --create-profile
  ) >"$errors" 2>&1; then
    fail "profile test variables unexpectedly bypassed the TTY requirement"
  fi
  assert_contains "interactive terminal" "$errors"
  [[ ! -e $TEST_AGENT_CONFIG_HOME/claude/profiles/bypass.env ]] ||
    fail "TTY bypass created a profile"
}

test_profile_creator_is_standalone_claude_action() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local outside="$TEST_TMP/outside"
  local input="$TEST_TMP/input"
  local output="$TEST_TMP/output"
  local help="$TEST_TMP/help"
  mkdir -p "$outside"
  prepare_fake_runtime "$TEST_TMP"
  printf '%s\n' \
    'deepseek' \
    'https://api.deepseek.com/anthropic' \
    'secret-key' >"$input"

  if "$ROOT/docker-claude" --create-profile --profile deepseek \
    >"$output" 2>&1; then
    fail "--create-profile unexpectedly accepted launch options"
  fi
  assert_contains "--create-profile must be used alone" "$output"

  "$ROOT/docker-claude" --help >"$help"
  assert_contains "--create-profile" "$help"

  if "$ROOT/docker-codex" --create-profile >"$output" 2>&1; then
    fail "Codex unexpectedly accepted --create-profile"
  fi
  assert_contains "--create-profile is only valid for Claude" "$output"
}

test_official_api_profile_is_mounted_without_secret_in_docker_args() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  write_profile official-api \
    'ANTHROPIC_API_KEY=test-official-secret' \
    'ANTHROPIC_MODEL=claude-opus-4-1'

  run_claude_launcher "$repo" --official-api -- --version

  assert_line "<type=bind,source=$PROFILE_PATH,target=/run/docker-agent/claude-profile.env,readonly>" \
    "$TEST_DOCKER_LOG"
  assert_line "<DOCKER_AGENT_CLAUDE_PROFILE_FILE=/run/docker-agent/claude-profile.env>" \
    "$TEST_DOCKER_LOG"
  assert_line "<DOCKER_AGENT_CLAUDE_CONNECTION=official-api>" \
    "$TEST_DOCKER_LOG"
  assert_not_contains "test-official-secret" "$TEST_DOCKER_LOG"
}

test_custom_profile_validates_endpoint_and_single_credential() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  write_profile deepseek \
    'ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=test-deepseek-secret' \
    'ANTHROPIC_MODEL=deepseek-v4-pro[1m]' \
    'ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-pro[1m]' \
    'ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-pro[1m]' \
    'ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash' \
    'CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-flash' \
    'CLAUDE_CODE_EFFORT_LEVEL=max'

  run_claude_launcher "$repo" --profile deepseek -- --version

  assert_line "<DOCKER_AGENT_CLAUDE_CONNECTION=profile:deepseek>" \
    "$TEST_DOCKER_LOG"
  assert_not_contains "test-deepseek-secret" "$TEST_DOCKER_LOG"

  : >"$TEST_DOCKER_LOG"
  write_profile api-compatible \
    'ANTHROPIC_BASE_URL=https://api-compatible.example.invalid/anthropic' \
    'ANTHROPIC_API_KEY=test-compatible-secret'
  run_claude_launcher "$repo" --profile api-compatible -- --version
  assert_line "<DOCKER_AGENT_CLAUDE_CONNECTION=profile:api-compatible>" \
    "$TEST_DOCKER_LOG"
  assert_not_contains "test-compatible-secret" "$TEST_DOCKER_LOG"

  : >"$TEST_DOCKER_LOG"
  write_profile deepseek \
    'ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=one' \
    'ANTHROPIC_API_KEY=two'
  if run_claude_launcher "$repo" --profile deepseek -- --version \
    >"$errors" 2>&1; then
    fail "conflicting custom profile unexpectedly succeeded"
  fi
  assert_contains "exactly one credential" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
}

test_profile_parser_rejects_unknown_duplicate_and_invalid_values() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  write_profile invalid \
    'ANTHROPIC_BASE_URL=https://example.invalid/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=secret' \
    'UNSUPPORTED_VALUE=one'
  if run_claude_launcher "$repo" --profile invalid -- >"$errors" 2>&1; then
    fail "unknown profile key unexpectedly succeeded"
  fi
  assert_contains "unsupported Claude profile key: UNSUPPORTED_VALUE" "$errors"

  write_profile invalid \
    'ANTHROPIC_BASE_URL=https://example.invalid/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=one' \
    'ANTHROPIC_AUTH_TOKEN=two'
  if run_claude_launcher "$repo" --profile invalid -- >"$errors" 2>&1; then
    fail "duplicate profile key unexpectedly succeeded"
  fi
  assert_contains "duplicate Claude profile key: ANTHROPIC_AUTH_TOKEN" "$errors"

  write_profile invalid \
    'ANTHROPIC_BASE_URL=https://example.invalid/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=secret' \
    'CLAUDE_CODE_EFFORT_LEVEL=extreme'
  if run_claude_launcher "$repo" --profile invalid -- >"$errors" 2>&1; then
    fail "invalid effort unexpectedly succeeded"
  fi
  assert_contains "invalid CLAUDE_CODE_EFFORT_LEVEL" "$errors"

  write_profile invalid \
    'ANTHROPIC_BASE_URL=' \
    'ANTHROPIC_AUTH_TOKEN=secret'
  if run_claude_launcher "$repo" --profile invalid -- >"$errors" 2>&1; then
    fail "empty endpoint unexpectedly succeeded"
  fi
  assert_contains "empty ANTHROPIC_BASE_URL" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
}

test_profile_name_and_selector_contracts_are_enforced() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  write_profile deepseek \
    'ANTHROPIC_BASE_URL=https://example.invalid/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=secret'

  if run_claude_launcher "$repo" --profile ../escape -- >"$errors" 2>&1; then
    fail "path-like profile name unexpectedly succeeded"
  fi
  assert_contains "invalid Claude profile name" "$errors"

  if run_claude_launcher "$repo" --profile official-api -- >"$errors" 2>&1; then
    fail "reserved profile name unexpectedly succeeded"
  fi
  assert_contains "reserved Claude profile name" "$errors"

  if run_claude_launcher "$repo" \
    --official-subscription --official-api -- >"$errors" 2>&1; then
    fail "multiple Claude selectors unexpectedly succeeded"
  fi
  assert_contains "mutually exclusive" "$errors"

  if run_claude_launcher "$repo" --profile >"$errors" 2>&1; then
    fail "missing profile name unexpectedly succeeded"
  fi
  assert_contains "--profile requires a name" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
}

test_profile_file_must_be_protected_regular_and_owned() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local errors="$TEST_TMP/errors"
  local target="$TEST_TMP/target.env"
  local fake_bin="$TEST_TMP/bin"
  local real_id
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  write_profile protected \
    'ANTHROPIC_BASE_URL=https://example.invalid/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=secret'
  chmod 640 "$PROFILE_PATH"
  if run_claude_launcher "$repo" --profile protected -- >"$errors" 2>&1; then
    fail "group-readable profile unexpectedly succeeded"
  fi
  assert_contains "must have mode 600" "$errors"

  printf '%s\n' \
    'ANTHROPIC_BASE_URL=https://example.invalid/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=secret' >"$target"
  chmod 600 "$target"
  PROFILE_PATH="$TEST_AGENT_CONFIG_HOME/claude/profiles/protected.env"
  ln -sf "$target" "$PROFILE_PATH"
  if run_claude_launcher "$repo" --profile protected -- >"$errors" 2>&1; then
    fail "symlink profile unexpectedly succeeded"
  fi
  assert_contains "must not be a symlink" "$errors"

  rm "$PROFILE_PATH"
  mkdir "$PROFILE_PATH"
  if run_claude_launcher "$repo" --profile protected -- >"$errors" 2>&1; then
    fail "directory profile unexpectedly succeeded"
  fi
  assert_contains "must be a regular file" "$errors"

  rmdir "$PROFILE_PATH"
  write_profile protected \
    'ANTHROPIC_BASE_URL=https://example.invalid/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=secret'
  install -d -m 755 "$fake_bin"
  real_id=$(command -v id)
  # shellcheck disable=SC2016 # ${1:-} expands when the generated fake runs.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ ${1:-} == -u ]]; then printf "99999\n"; exit 0; fi' \
    "exec \"$real_id\" \"\$@\"" >"$fake_bin/id"
  chmod 755 "$fake_bin/id"
  if PATH="$fake_bin:$PATH" \
    run_claude_launcher "$repo" --profile protected -- >"$errors" 2>&1; then
    fail "profile with unexpected owner identity unexpectedly succeeded"
  fi
  assert_contains "must be owned by the current user" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
}

test_profile_config_home_must_not_resolve_inside_checkout() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local config_home="$repo/.agent-config"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  install -d -m 700 "$config_home/claude/profiles"
  printf '%s\n' \
    'ANTHROPIC_BASE_URL=https://example.invalid/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=secret' \
    >"$config_home/claude/profiles/inside.env"
  chmod 600 "$config_home/claude/profiles/inside.env"

  if DOCKER_AGENT_CONFIG_HOME=$config_home \
    run_claude_launcher "$repo" --profile inside -- >"$errors" 2>&1; then
    fail "profile config inside checkout unexpectedly succeeded"
  fi

  assert_contains "config home must not be inside the checkout" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
}

test_official_api_contract_rejects_custom_endpoint_and_missing_profile() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  if run_claude_launcher "$repo" --official-api -- >"$errors" 2>&1; then
    fail "missing official API profile unexpectedly succeeded"
  fi
  assert_contains "Claude profile does not exist" "$errors"

  write_profile official-api \
    'ANTHROPIC_BASE_URL=https://example.invalid/anthropic' \
    'ANTHROPIC_API_KEY=secret'
  if run_claude_launcher "$repo" --official-api -- >"$errors" 2>&1; then
    fail "official API profile with custom endpoint unexpectedly succeeded"
  fi
  assert_contains "official API profile requires only ANTHROPIC_API_KEY" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
}

test_same_named_repositories_get_distinct_state() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo_a="$TEST_TMP/a/test"
  local repo_b="$TEST_TMP/b/test"
  local state_a state_b
  make_repo "$repo_a"
  make_repo "$repo_b"
  prepare_fake_runtime "$TEST_TMP"

  run_claude_launcher "$repo_a" --official-subscription -- --version
  state_a=$(state_mount_source "$TEST_DOCKER_LOG")

  : >"$TEST_DOCKER_LOG"
  run_claude_launcher "$repo_b" --official-subscription -- --version
  state_b=$(state_mount_source "$TEST_DOCKER_LOG")

  [[ $state_a != "$state_b" ]] ||
    fail "same-named repositories shared Claude state"
  [[ $state_a == "$TEST_AGENT_DATA_HOME/claude/repos/test-"* ]] ||
    fail "unexpected readable repository state path: $state_a"
  [[ $state_b == "$TEST_AGENT_DATA_HOME/claude/repos/test-"* ]] ||
    fail "unexpected readable repository state path: $state_b"
}

test_linked_worktrees_share_repo_identity_but_not_state() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local main="$TEST_TMP/main repo"
  local worktree="$TEST_TMP/linked tree"
  local state_main state_linked repo_state_main repo_state_linked
  make_repo "$main"
  git -C "$main" worktree add -qb linked "$worktree"
  prepare_fake_runtime "$TEST_TMP"

  run_claude_launcher "$main" --official-subscription -- --version
  state_main=$(state_mount_source "$TEST_DOCKER_LOG")

  : >"$TEST_DOCKER_LOG"
  run_claude_launcher "$worktree" --official-subscription -- --version
  state_linked=$(state_mount_source "$TEST_DOCKER_LOG")

  repo_state_main=${state_main%%/worktrees/*}
  repo_state_linked=${state_linked%%/worktrees/*}
  [[ $repo_state_main == "$repo_state_linked" ]] ||
    fail "linked worktrees did not share repository identity"
  [[ $state_main != "$state_linked" ]] ||
    fail "linked worktrees shared Claude state"
}

test_connections_get_distinct_state_and_profile_content_reuses_state() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local subscription_state api_state profile_state profile_state_after
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  write_profile official-api 'ANTHROPIC_API_KEY=official-secret'
  write_profile deepseek \
    'ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=deepseek-one'

  run_claude_launcher "$repo" --official-subscription -- --version
  subscription_state=$(state_mount_source "$TEST_DOCKER_LOG")

  : >"$TEST_DOCKER_LOG"
  run_claude_launcher "$repo" --official-api -- --version
  api_state=$(state_mount_source "$TEST_DOCKER_LOG")

  : >"$TEST_DOCKER_LOG"
  run_claude_launcher "$repo" --profile deepseek -- --version
  profile_state=$(state_mount_source "$TEST_DOCKER_LOG")

  [[ $subscription_state != "$api_state" &&
      $subscription_state != "$profile_state" &&
      $api_state != "$profile_state" ]] ||
    fail "Claude connections shared state"
  [[ $subscription_state == */official-subscription ]] ||
    fail "subscription state has unexpected path: $subscription_state"
  [[ $api_state == */official-api ]] ||
    fail "official API state has unexpected path: $api_state"
  [[ $profile_state == */profiles/deepseek ]] ||
    fail "custom profile state has unexpected path: $profile_state"

  write_profile deepseek \
    'ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=deepseek-two'
  : >"$TEST_DOCKER_LOG"
  run_claude_launcher "$repo" --profile deepseek -- --version
  profile_state_after=$(state_mount_source "$TEST_DOCKER_LOG")
  [[ $profile_state == "$profile_state_after" ]] ||
    fail "changing profile content changed its state identity"
}

test_state_identity_mismatch_fails_before_docker() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local state errors="$TEST_TMP/errors"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  run_claude_launcher "$repo" --official-subscription -- --version
  state=$(state_mount_source "$TEST_DOCKER_LOG")
  printf 'wrong identity\n' >"$state/.docker-agent-identity"
  chmod 600 "$state/.docker-agent-identity"
  : >"$TEST_DOCKER_LOG"

  if run_claude_launcher "$repo" --official-subscription -- --version \
    >"$errors" 2>&1; then
    fail "mismatched state identity unexpectedly succeeded"
  fi

  assert_contains "Claude state identity does not match" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
}

test_subscription_mounts_only_host_credential_file_readwrite() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local claude_home="$TEST_TMP/alternate claude"
  local state
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  install -d -m 700 "$claude_home"
  printf '%s\n' '{"test":"alternate"}' >"$claude_home/.credentials.json"
  chmod 600 "$claude_home/.credentials.json"

  CLAUDE_CONFIG_DIR=$claude_home \
    run_claude_launcher "$repo" --official-subscription -- --version

  state=$(state_mount_source "$TEST_DOCKER_LOG")
  assert_line "<type=bind,source=$claude_home/.credentials.json,target=/claude-state/.credentials.json>" \
    "$TEST_DOCKER_LOG"
  assert_not_contains "source=$claude_home,target=/claude-state" \
    "$TEST_DOCKER_LOG"
  assert_line "<CLAUDE_CONFIG_DIR=/claude-state>" "$TEST_DOCKER_LOG"
  [[ $(stat -c %a "$state") == 700 ]] ||
    fail "Claude state directory does not have mode 700"
  [[ $(stat -c %a "$state/.docker-agent-identity") == 600 ]] ||
    fail "Claude state identity does not have mode 600"
}

test_subscription_rejects_macos_and_invalid_credentials_before_state() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local claude_home="$TEST_TMP/invalid claude"
  local errors="$TEST_TMP/errors"
  local fake_bin="$TEST_TMP/bin"
  local real_id
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  if DOCKER_AGENT_HOST_OS=Darwin \
    run_claude_launcher "$repo" --official-subscription -- >"$errors" 2>&1; then
    fail "macOS subscription reuse unexpectedly succeeded"
  fi
  assert_contains "macOS Keychain" "$errors"

  install -d -m 700 "$claude_home"
  if CLAUDE_CONFIG_DIR=$claude_home \
    run_claude_launcher "$repo" --official-subscription -- >"$errors" 2>&1; then
    fail "missing OAuth credential unexpectedly succeeded"
  fi
  assert_contains "Claude OAuth credential does not exist" "$errors"

  printf '%s\n' '{"test":"credential"}' >"$claude_home/target.json"
  chmod 600 "$claude_home/target.json"
  ln -s "$claude_home/target.json" "$claude_home/.credentials.json"
  if CLAUDE_CONFIG_DIR=$claude_home \
    run_claude_launcher "$repo" --official-subscription -- >"$errors" 2>&1; then
    fail "symlink OAuth credential unexpectedly succeeded"
  fi
  assert_contains "must not be a symlink" "$errors"

  rm "$claude_home/.credentials.json"
  printf '%s\n' '{"test":"credential"}' >"$claude_home/.credentials.json"
  chmod 640 "$claude_home/.credentials.json"
  if CLAUDE_CONFIG_DIR=$claude_home \
    run_claude_launcher "$repo" --official-subscription -- >"$errors" 2>&1; then
    fail "group-readable OAuth credential unexpectedly succeeded"
  fi
  assert_contains "must have mode 600" "$errors"

  chmod 600 "$claude_home/.credentials.json"
  install -d -m 755 "$fake_bin"
  real_id=$(command -v id)
  # shellcheck disable=SC2016 # ${1:-} expands when the generated fake runs.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ ${1:-} == -u ]]; then printf "99999\n"; exit 0; fi' \
    "exec \"$real_id\" \"\$@\"" >"$fake_bin/id"
  chmod 755 "$fake_bin/id"
  if PATH="$fake_bin:$PATH" CLAUDE_CONFIG_DIR=$claude_home \
    run_claude_launcher "$repo" --official-subscription -- >"$errors" 2>&1; then
    fail "OAuth credential with unexpected owner identity unexpectedly succeeded"
  fi
  assert_contains "must be owned by the current user" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
  [[ ! -e $TEST_AGENT_DATA_HOME/claude ]] ||
    fail "invalid credential created Claude state"
}

test_menu_selects_sorted_custom_profile_and_hides_reserved_profile() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local keys="$TEST_TMP/keys"
  local menu_log="$TEST_TMP/menu.log"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  write_profile deepseek \
    'ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=deepseek-secret' \
    'ANTHROPIC_MODEL=deepseek-v4-pro[1m]'
  write_profile alpha \
    'ANTHROPIC_BASE_URL=https://alpha.example.invalid/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=alpha-secret' \
    'ANTHROPIC_DEFAULT_SONNET_MODEL=alpha-sonnet'
  write_profile unsafe \
    'ANTHROPIC_BASE_URL=https://unsafe.example.invalid/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=unsafe-secret' \
    $'ANTHROPIC_MODEL=unsafe\033[31m-model'
  write_profile very-long \
    'ANTHROPIC_BASE_URL=https://long.example.invalid/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=long-secret' \
    'ANTHROPIC_MODEL=1234567890123456789012345678901234567890123456789012345678901234567890'
  write_profile official-api \
    'ANTHROPIC_API_KEY=official-secret'
  printf '\033[B\033[B\n\033[B\n' >"$keys"

  run_claude_menu "$repo" "$keys" "$menu_log" -- --version

  assert_line "<DOCKER_AGENT_CLAUDE_CONNECTION=profile:deepseek>" \
    "$TEST_DOCKER_LOG"
  assert_contains "请选择 Claude Code 的连接方式" "$menu_log"
  assert_contains "请选择自定义 endpoint profile" "$menu_log"
  assert_contains \
    "alpha  [⚠ 主模型未配置：将使用 Claude 默认模型名]" "$menu_log"
  assert_contains \
    "deepseek  [主模型: deepseek-v4-pro[1m]]" "$menu_log"
  assert_contains \
    "unsafe  [主模型: unsafe[31m-model]" "$menu_log"
  assert_not_contains \
    $'unsafe  [主模型: unsafe\033[31m-model]' "$menu_log"
  assert_contains \
    "very-long  [主模型: 1234567890123456789012345678901234567890123456789012345678901...]" \
    "$menu_log"
  assert_not_contains "official-api" "$menu_log"
}

test_menu_supports_top_level_choices_and_jk_navigation() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local keys="$TEST_TMP/keys"
  local menu_log="$TEST_TMP/menu.log"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  write_profile official-api \
    'ANTHROPIC_API_KEY=official-secret'

  printf '\n' >"$keys"
  run_claude_menu "$repo" "$keys" "$menu_log" -- --version
  assert_line "<DOCKER_AGENT_CLAUDE_CONNECTION=official-subscription>" \
    "$TEST_DOCKER_LOG"

  : >"$TEST_DOCKER_LOG"
  printf '\033[B\n' >"$keys"
  run_claude_menu "$repo" "$keys" "$menu_log" -- --version
  assert_line "<DOCKER_AGENT_CLAUDE_CONNECTION=official-api>" \
    "$TEST_DOCKER_LOG"

  : >"$TEST_DOCKER_LOG"
  printf 'jk\n' >"$keys"
  run_claude_menu "$repo" "$keys" "$menu_log" -- --version
  assert_line "<DOCKER_AGENT_CLAUDE_CONNECTION=official-subscription>" \
    "$TEST_DOCKER_LOG"
}

test_menu_cancel_returns_130_without_creating_state_or_worktree() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local keys="$TEST_TMP/keys"
  local menu_log="$TEST_TMP/menu.log"
  local errors="$TEST_TMP/errors"
  local status
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  printf '\033' >"$keys"
  set +e
  run_claude_menu "$repo" "$keys" "$menu_log" \
    --isolated menu-cancel -- --version >"$errors" 2>&1
  status=$?
  set -e
  [[ $status == 130 ]] ||
    fail "Escape cancellation returned $status instead of 130"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
  if git -C "$repo" show-ref --verify --quiet refs/heads/codex/menu-cancel; then
    fail "Escape cancellation created an isolated worktree branch"
  fi
  [[ ! -e $TEST_AGENT_DATA_HOME/claude ]] ||
    fail "Escape cancellation created Claude state"

  printf '\003' >"$keys"
  set +e
  run_claude_menu "$repo" "$keys" "$menu_log" -- --version \
    >"$errors" 2>&1
  status=$?
  set -e
  [[ $status == 130 ]] ||
    fail "Ctrl-C cancellation returned $status instead of 130"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
  [[ ! -e $TEST_AGENT_DATA_HOME/claude ]] ||
    fail "Ctrl-C cancellation created Claude state"
}

test_menu_reports_empty_custom_profile_directory() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local keys="$TEST_TMP/keys"
  local menu_log="$TEST_TMP/menu.log"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  printf '\033[B\033[B\n' >"$keys"

  if run_claude_menu "$repo" "$keys" "$menu_log" -- --version \
    >"$errors" 2>&1; then
    fail "empty custom profile menu unexpectedly succeeded"
  fi

  assert_contains "$TEST_AGENT_CONFIG_HOME/claude/profiles" "$errors"
  assert_contains "install -m 600" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
  [[ ! -e $TEST_AGENT_DATA_HOME/claude ]] ||
    fail "empty custom profile menu created Claude state"
}

test_noninteractive_launch_requires_explicit_connection() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  if run_claude_launcher "$repo" -- --version >"$errors" 2>&1; then
    fail "non-interactive launch without a connection unexpectedly succeeded"
  fi

  assert_contains "non-interactive" "$errors"
  assert_contains "--official-subscription" "$errors"
  assert_contains "--official-api" "$errors"
  assert_contains "--profile NAME" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
  [[ ! -e $TEST_AGENT_DATA_HOME/claude ]] ||
    fail "non-interactive launch created Claude state"
}

init_tests
test_profile_creator_masks_key_and_writes_protected_profile_outside_git
test_profile_creator_backspace_removes_masked_character_and_secret_character
test_profile_creator_refuses_existing_profile_without_modifying_it
test_profile_creator_requires_name_endpoint_key_and_interactive_terminal
test_profile_creator_is_standalone_claude_action
test_official_api_profile_is_mounted_without_secret_in_docker_args
test_custom_profile_validates_endpoint_and_single_credential
test_profile_parser_rejects_unknown_duplicate_and_invalid_values
test_profile_name_and_selector_contracts_are_enforced
test_profile_file_must_be_protected_regular_and_owned
test_profile_config_home_must_not_resolve_inside_checkout
test_official_api_contract_rejects_custom_endpoint_and_missing_profile
test_same_named_repositories_get_distinct_state
test_linked_worktrees_share_repo_identity_but_not_state
test_connections_get_distinct_state_and_profile_content_reuses_state
test_state_identity_mismatch_fails_before_docker
test_subscription_mounts_only_host_credential_file_readwrite
test_subscription_rejects_macos_and_invalid_credentials_before_state
test_menu_selects_sorted_custom_profile_and_hides_reserved_profile
test_menu_supports_top_level_choices_and_jk_navigation
test_menu_cancel_returns_130_without_creating_state_or_worktree
test_menu_reports_empty_custom_profile_directory
test_noninteractive_launch_requires_explicit_connection
printf 'claude launcher tests: PASS\n'
