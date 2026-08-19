#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/testlib.bash
source "$ROOT/tests/testlib.bash"

write_codex_profile() {
  local name=$1
  shift
  install -d -m 700 "$TEST_AGENT_CONFIG_HOME/codex/profiles"
  CODEX_PROFILE_DIR="$TEST_AGENT_CONFIG_HOME/codex/profiles/$name"
  install -d -m 700 "$CODEX_PROFILE_DIR"
  CODEX_PROFILE_PATH="$CODEX_PROFILE_DIR/config.toml"
  printf '%s\n' "$@" >"$CODEX_PROFILE_PATH"
  chmod 600 "$CODEX_PROFILE_PATH"
  ln -s "$CODEX_PROFILE_PATH" \
    "$TEST_AGENT_CONFIG_HOME/codex/profiles/$name.config.toml"
}

run_codex_launcher() {
  local repo=$1
  shift
  run_named_launcher "$repo" "$ROOT" docker-agent codex "$@"
}

wait_for_profile_output() {
  local output=$1 expected=$2 done_file=$3
  local attempt
  for ((attempt = 0; attempt < 500; attempt++)); do
    grep -Fq -- "$expected" "$output" 2>/dev/null && return 0
    [[ ! -e $done_file ]] || return 1
    sleep 0.01
  done
  fail "timed out waiting for Codex profile creator output: $expected"
}

run_profile_creator() {
  local directory=$1 input=$2 output=$3
  local fifo="$directory/profile-input.fifo"
  local done_file="$directory/profile-done"
  local line pid result

  command -v script >/dev/null 2>&1 ||
    fail "script is required for Codex profile creator PTY tests"
  mkfifo "$fifo"
  exec 7<>"$fifo"
  # macOS script(1) takes the command after its output file and uses -F for
  # immediate flushing; util-linux script takes it through -c and uses -f.
  # shellcheck disable=SC2016 # Variables expand in script's child shell.
  if [[ $(uname -s) == Darwin ]]; then
    CODEX_HOME="$TEST_CODEX_HOME" \
      DOCKER_AGENT_CONFIG_HOME="$TEST_AGENT_CONFIG_HOME" \
      DOCKER_AGENT_DOCKER_BIN="$directory/does-not-exist-docker" \
      DOCKER_AGENT_TEST_LAUNCHER="$ROOT/docker-codex" \
      DOCKER_AGENT_TEST_DONE_FILE="$done_file" \
      script -qeF /dev/null /bin/bash -c \
        '"$DOCKER_AGENT_TEST_LAUNCHER" --create-profile; result=$?; printf "%s\n" "$result" >"$DOCKER_AGENT_TEST_DONE_FILE"; exit "$result"' \
        <&7 >"$output" 2>&1 &
  else
    CODEX_HOME="$TEST_CODEX_HOME" \
      DOCKER_AGENT_CONFIG_HOME="$TEST_AGENT_CONFIG_HOME" \
      DOCKER_AGENT_DOCKER_BIN="$directory/does-not-exist-docker" \
      DOCKER_AGENT_TEST_LAUNCHER="$ROOT/docker-codex" \
      DOCKER_AGENT_TEST_DONE_FILE="$done_file" \
      script -qfec \
        '"$DOCKER_AGENT_TEST_LAUNCHER" --create-profile; result=$?; printf "%s\n" "$result" >"$DOCKER_AGENT_TEST_DONE_FILE"; exit "$result"' \
        /dev/null <&7 >"$output" 2>&1 &
  fi
  pid=$!

  exec 9<"$input"
  for prompt in "Profile 名称:" "API endpoint:" "模型名称:" "API key:"; do
    if wait_for_profile_output "$output" "$prompt" "$done_file"; then
      IFS= read -r line <&9 || line=
      printf '%s\n' "$line" >&7
    fi
  done
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

test_profile_creator_writes_one_protected_managed_profile() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local outside="$TEST_TMP/not a repository"
  local input="$TEST_TMP/input"
  local output="$TEST_TMP/output"
  local profile profile_link compat_profile
  mkdir -p "$outside"
  prepare_fake_runtime "$TEST_TMP"
  profile="$TEST_AGENT_CONFIG_HOME/codex/profiles/deepseek/config.toml"
  profile_link="$TEST_AGENT_CONFIG_HOME/codex/profiles/deepseek.config.toml"
  compat_profile="$TEST_CODEX_HOME/deepseek.config.toml"
  printf '%s\n' \
    'deepseek' \
    'https://relay.example.invalid/v1' \
    'deepseek-chat' \
    'secret-key' >"$input"

  run_profile_creator "$outside" "$input" "$output"

  assert_contiguous_lines "$profile" \
    'model_provider = "docker-agent-deepseek"' \
    'model = "deepseek-chat"' \
    'review_model = "deepseek-chat"' \
    '' \
    '[model_providers."docker-agent-deepseek"]' \
    'name = "deepseek"' \
    'base_url = "https://relay.example.invalid/v1"' \
    'wire_api = "responses"' \
    'experimental_bearer_token = "secret-key"'
  [[ $(file_mode "$profile") == 600 ]] ||
    fail "created Codex profile does not have mode 600"
  [[ $(file_mode "$(dirname "$profile")") == 700 ]] ||
    fail "created per-profile Codex directory does not have mode 700"
  [[ $(file_mode "$TEST_AGENT_CONFIG_HOME/codex/profiles") == 700 ]] ||
    fail "created Codex profile directory does not have mode 700"
  [[ -L $profile_link && $(readlink "$profile_link") == "$profile" ]] ||
    fail "Codex creator did not create the managed profile link"
  [[ -L $compat_profile ]] ||
    fail "Codex creator did not create the native compatibility link"
  [[ $(readlink "$compat_profile") == "$profile" ]] ||
    fail "Codex native compatibility link has the wrong target"
  assert_contains 'API key: **********' "$output"
  assert_not_contains 'secret-key' "$output"
  assert_contains "Profile 已创建：$profile_link" "$output"
  assert_contains 'docker-codex --profile deepseek' "$output"
  [[ ! -e $TEST_CODEX_HOME/auth.json ]] ||
    fail "Codex profile creator unexpectedly created auth.json"
}

test_profile_creator_escapes_toml_strings_and_refuses_overwrite() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local outside="$TEST_TMP/outside"
  local input="$TEST_TMP/input"
  local output="$TEST_TMP/output"
  local profile profile_link expected
  mkdir -p "$outside"
  prepare_fake_runtime "$TEST_TMP"
  profile="$TEST_AGENT_CONFIG_HOME/codex/profiles/quoted/config.toml"
  profile_link="$TEST_AGENT_CONFIG_HOME/codex/profiles/quoted.config.toml"
  printf '%s\n' \
    'quoted' \
    'https://relay.example.invalid/v1?label="test"' \
    'provider\model' \
    'secret"key\value' >"$input"

  run_profile_creator "$outside" "$input" "$output"

  assert_line 'base_url = "https://relay.example.invalid/v1?label=\"test\""' \
    "$profile"
  assert_line 'model = "provider\\model"' "$profile"
  assert_line 'experimental_bearer_token = "secret\"key\\value"' "$profile"
  cp "$profile" "$TEST_TMP/expected"
  expected="$TEST_TMP/expected"
  printf 'quoted\n' >"$input"

  if run_profile_creator "$outside" "$input" "$output"; then
    fail "Codex profile creator unexpectedly overwrote an existing profile"
  fi
  assert_contains "Codex profile already exists: $profile_link" "$output"
  cmp -s "$expected" "$profile" ||
    fail "existing Codex profile content was modified"
}

test_profile_creator_requires_all_fields_and_a_real_tty() {
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
    fail "empty Codex profile name unexpectedly succeeded"
  fi
  assert_contains "Profile name is required" "$output"

  printf 'missing-endpoint\n\n' >"$input"
  if run_profile_creator "$outside" "$input" "$output"; then
    fail "empty Codex endpoint unexpectedly succeeded"
  fi
  assert_contains "API endpoint is required" "$output"

  printf 'missing-model\nhttps://relay.example.invalid/v1\n\n' >"$input"
  if run_profile_creator "$outside" "$input" "$output"; then
    fail "empty Codex model unexpectedly succeeded"
  fi
  assert_contains "Model name is required" "$output"

  printf '%s\n' \
    'missing-key' \
    'https://relay.example.invalid/v1' \
    'deepseek-chat' \
    '' >"$input"
  if run_profile_creator "$outside" "$input" "$output"; then
    fail "empty Codex API key unexpectedly succeeded"
  fi
  assert_contains "API key is required" "$output"

  if (
    cd "$outside"
    CODEX_HOME="$TEST_CODEX_HOME" \
      DOCKER_AGENT_CONFIG_HOME="$TEST_AGENT_CONFIG_HOME" \
      "$ROOT/docker-codex" --create-profile </dev/null
  ) >"$errors" 2>&1; then
    fail "non-interactive Codex profile creation unexpectedly succeeded"
  fi
  assert_contains "interactive terminal" "$errors"
}

test_selected_profile_is_validated_and_forwarded_without_secret_in_args() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local selected_profile selected_profile_dir other_profile compat_profile
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  write_codex_profile relay \
    'model = "gpt-5.4"' \
    'model_provider = "relay"' \
    '[model_providers.relay]' \
    'base_url = "https://relay.example.invalid/v1"' \
    'wire_api = "responses"' \
    'experimental_bearer_token = "profile-secret"'
  selected_profile=$CODEX_PROFILE_PATH
  selected_profile_dir=$CODEX_PROFILE_DIR
  compat_profile="$TEST_CODEX_HOME/relay.config.toml"
  write_codex_profile other \
    'model = "other-model"' \
    'experimental_bearer_token = "other-profile-secret"'
  other_profile=$CODEX_PROFILE_PATH

  run_codex_launcher "$repo" --profile relay -- --version

  [[ -L $compat_profile ]] ||
    fail "Codex launcher did not create the native compatibility link"
  [[ $(readlink "$compat_profile") == "$selected_profile" ]] ||
    fail "Codex launcher created a compatibility link to the wrong profile"
  assert_line '<DOCKER_AGENT_CODEX_PROFILE=relay>' "$TEST_DOCKER_LOG"
  assert_line \
    "<type=bind,source=$selected_profile_dir,target=$selected_profile_dir>" \
    "$TEST_DOCKER_LOG"
  assert_not_contains "$other_profile" "$TEST_DOCKER_LOG"
  assert_ordered_lines "$TEST_DOCKER_LOG" \
    '<docker-agent:local>' \
    '<codex>' \
    '<--yolo>' \
    '<--disable>' \
    '<apps>' \
    '<--profile>' \
    '<relay>' \
    '<--version>'
  assert_not_contains 'profile-secret' "$TEST_DOCKER_LOG"
  assert_not_contains 'other-profile-secret' "$TEST_DOCKER_LOG"
}

test_selected_managed_profile_migrates_deprecated_hooks_feature() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local flat_profile profile profile_dir compat_profile complex_profile errors
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  install -d -m 700 "$TEST_AGENT_CONFIG_HOME/codex/profiles"
  flat_profile="$TEST_AGENT_CONFIG_HOME/codex/profiles/legacy-hooks.config.toml"
  profile_dir="$TEST_AGENT_CONFIG_HOME/codex/profiles/legacy-hooks"
  profile="$profile_dir/config.toml"
  compat_profile="$TEST_CODEX_HOME/legacy-hooks.config.toml"
  printf '%s\n' \
    'model = "gpt-5.4"' \
    '' \
    '[features]' \
    'codex_hooks = true' >"$flat_profile"
  chmod 600 "$flat_profile"
  ln -s "$flat_profile" "$compat_profile"

  run_codex_launcher "$repo" --profile legacy-hooks -- --version

  [[ -d $profile_dir ]] || fail "flat managed Codex profile was not migrated"
  [[ -L $flat_profile && $(readlink "$flat_profile") == "$profile" ]] ||
    fail "flat managed Codex profile did not become a compatibility link"
  [[ -L $compat_profile && $(readlink "$compat_profile") == "$profile" ]] ||
    fail "native Codex profile link was not normalized after migration"
  assert_line 'hooks = true' "$profile"
  assert_not_contains 'codex_hooks' "$profile"
  [[ $(file_mode "$profile") == 600 ]] ||
    fail "migrated Codex profile does not have mode 600"

  write_codex_profile complex \
    'model = "gpt-5.4"' \
    'developer_instructions = """' \
    '[features]' \
    'codex_hooks = true' \
    '"""'
  complex_profile=$CODEX_PROFILE_PATH
  errors="$TEST_TMP/complex-errors"
  run_codex_launcher "$repo" --profile complex -- --version \
    >"$errors" 2>&1

  assert_contains 'codex_hooks = true' "$complex_profile"
  assert_contains 'replace features.codex_hooks with features.hooks manually' \
    "$errors"
}

test_selected_profile_rejects_unsafe_names_files_and_checkout_location() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local errors="$TEST_TMP/errors"
  local real_profile inside_config nested_config native_profile
  local escaped_config escaped_profiles
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  if run_codex_launcher "$repo" --profile ../escape >"$errors" 2>&1; then
    fail "unsafe Codex profile name unexpectedly succeeded"
  fi
  assert_contains "invalid Codex profile name" "$errors"

  if run_codex_launcher "$repo" --profile missing >"$errors" 2>&1; then
    fail "missing Codex profile unexpectedly succeeded"
  fi
  assert_contains "Codex profile does not exist" "$errors"

  write_codex_profile loose \
    'model = "gpt-5.4"' \
    'experimental_bearer_token = "secret"'
  chmod 640 "$CODEX_PROFILE_PATH"
  if run_codex_launcher "$repo" --profile loose >"$errors" 2>&1; then
    fail "group-readable Codex profile unexpectedly succeeded"
  fi
  assert_contains "Codex profile must have mode 600" "$errors"

  rm -f "$CODEX_PROFILE_PATH"
  write_codex_profile real \
    'model = "gpt-5.4"' \
    'experimental_bearer_token = "secret"'
  real_profile=$CODEX_PROFILE_PATH
  install -d -m 700 "$TEST_AGENT_CONFIG_HOME/codex/profiles/link"
  ln -s "$real_profile" \
    "$TEST_AGENT_CONFIG_HOME/codex/profiles/link/config.toml"
  ln -s "$TEST_AGENT_CONFIG_HOME/codex/profiles/link/config.toml" \
    "$TEST_AGENT_CONFIG_HOME/codex/profiles/link.config.toml"
  if run_codex_launcher "$repo" --profile link >"$errors" 2>&1; then
    fail "symlink Codex profile unexpectedly succeeded"
  fi
  assert_contains "Codex profile must not be a symlink" "$errors"

  write_codex_profile conflict \
    'model = "gpt-5.4"' \
    'experimental_bearer_token = "secret"'
  native_profile="$TEST_CODEX_HOME/conflict.config.toml"
  printf '%s\n' \
    'model = "gpt-5.4"' \
    'experimental_bearer_token = "secret"' \
    >"$native_profile"
  chmod 600 "$native_profile"
  if run_codex_launcher "$repo" --profile conflict >"$errors" 2>&1; then
    fail "regular file at the native Codex profile path unexpectedly succeeded"
  fi
  assert_contains "native Codex profile path conflicts with managed profile" \
    "$errors"

  write_codex_profile wrong \
    'model = "gpt-5.4"' \
    'experimental_bearer_token = "secret"'
  ln -s "$real_profile" "$TEST_CODEX_HOME/wrong.config.toml"
  if run_codex_launcher "$repo" --profile wrong >"$errors" 2>&1; then
    fail "wrong native Codex compatibility link unexpectedly succeeded"
  fi
  assert_contains "native Codex profile link points to a different file" \
    "$errors"

  inside_config="$repo/agent-config"
  install -d -m 700 "$inside_config/codex/profiles"
  install -m 600 /dev/null \
    "$inside_config/codex/profiles/inside.config.toml"
  if DOCKER_AGENT_CONFIG_HOME="$inside_config" \
      run_codex_launcher "$repo" --profile inside >"$errors" 2>&1; then
    fail "Codex config root inside checkout unexpectedly succeeded"
  fi
  assert_contains "docker-agent config home must not be inside the checkout" \
    "$errors"

  nested_config="$TEST_CODEX_HOME/agent-config"
  install -d -m 700 "$nested_config/codex/profiles"
  install -m 600 /dev/null \
    "$nested_config/codex/profiles/nested.config.toml"
  if DOCKER_AGENT_CONFIG_HOME="$nested_config" \
      run_codex_launcher "$repo" --profile nested >"$errors" 2>&1; then
    fail "managed Codex profiles inside CODEX_HOME unexpectedly succeeded"
  fi
  assert_contains "Codex profile directory must not be inside CODEX_HOME" \
    "$errors"

  escaped_config="$TEST_TMP/escaped-config"
  escaped_profiles="$TEST_TMP/escaped-profiles"
  install -d -m 700 "$escaped_config/codex" "$escaped_profiles"
  install -m 600 /dev/null \
    "$escaped_profiles/escaped.config.toml"
  ln -s "$escaped_profiles" "$escaped_config/codex/profiles"
  if DOCKER_AGENT_CONFIG_HOME="$escaped_config" \
      run_codex_launcher "$repo" --profile escaped >"$errors" 2>&1; then
    fail "Codex profile directory symlink outside config root unexpectedly succeeded"
  fi
  assert_contains "Codex profile directory resolves outside docker-agent config home" \
    "$errors"

  native_profile="$repo/codex-home/inside.config.toml"
  install -d -m 700 "$(dirname "$native_profile")"
  install -m 600 /dev/null "$native_profile"
  if TEST_CODEX_HOME_OVERRIDE="$(dirname "$native_profile")" \
      run_codex_launcher "$repo" --profile inside >"$errors" 2>&1; then
    fail "legacy Codex profile inside checkout unexpectedly succeeded"
  fi
  assert_contains "Codex profile must not be inside the checkout" "$errors"
}

test_legacy_native_profile_remains_supported_without_managed_mount() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local native_profile managed_profile
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  native_profile="$TEST_CODEX_HOME/legacy.config.toml"
  managed_profile="$TEST_AGENT_CONFIG_HOME/codex/profiles/legacy.config.toml"
  printf '%s\n' \
    'model = "gpt-5.4"' \
    'experimental_bearer_token = "legacy-secret"' \
    >"$native_profile"
  chmod 600 "$native_profile"

  run_codex_launcher "$repo" --profile legacy -- --version

  [[ -f $native_profile && ! -L $native_profile ]] ||
    fail "legacy native Codex profile was unexpectedly replaced"
  assert_not_contains "$managed_profile" "$TEST_DOCKER_LOG"
  assert_ordered_lines "$TEST_DOCKER_LOG" \
    '<--profile>' '<legacy>' '<--version>'
  assert_not_contains 'legacy-secret' "$TEST_DOCKER_LOG"
}

test_codex_profile_options_are_documented_and_create_is_standalone() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local output="$TEST_TMP/output"
  local help="$TEST_TMP/help"

  "$ROOT/docker-codex" --help >"$help"
  assert_contains "--profile NAME" "$help"
  assert_contains "--create-profile" "$help"

  if "$ROOT/docker-codex" --create-profile --profile relay \
      >"$output" 2>&1; then
    fail "Codex --create-profile unexpectedly accepted launch options"
  fi
  assert_contains "--create-profile must be used alone" "$output"
}

init_tests
test_profile_creator_writes_one_protected_managed_profile
test_profile_creator_escapes_toml_strings_and_refuses_overwrite
test_profile_creator_requires_all_fields_and_a_real_tty
test_selected_profile_is_validated_and_forwarded_without_secret_in_args
test_selected_managed_profile_migrates_deprecated_hooks_feature
test_selected_profile_rejects_unsafe_names_files_and_checkout_location
test_legacy_native_profile_remains_supported_without_managed_mount
test_codex_profile_options_are_documented_and_create_is_standalone
printf 'codex profile tests: PASS\n'
