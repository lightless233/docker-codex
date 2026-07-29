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

init_tests
test_official_api_profile_is_mounted_without_secret_in_docker_args
test_custom_profile_validates_endpoint_and_single_credential
test_profile_parser_rejects_unknown_duplicate_and_invalid_values
test_profile_name_and_selector_contracts_are_enforced
test_profile_file_must_be_protected_regular_and_owned
test_profile_config_home_must_not_resolve_inside_checkout
test_official_api_contract_rejects_custom_endpoint_and_missing_profile
printf 'claude launcher tests: PASS\n'
