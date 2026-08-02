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

record_claude_environment() {
  printf '<ENV_ANTHROPIC_BASE_URL:%s>\n' "${ANTHROPIC_BASE_URL:-}" >>"$log"
  printf '<ENV_AUTH_TOKEN_SET:%s>\n' \
    "$([[ -n ${ANTHROPIC_AUTH_TOKEN:-} ]] && printf 1 || printf 0)" >>"$log"
  printf '<ENV_API_KEY_SET:%s>\n' \
    "$([[ -n ${ANTHROPIC_API_KEY:-} ]] && printf 1 || printf 0)" >>"$log"
  printf '<ENV_ANTHROPIC_MODEL:%s>\n' "${ANTHROPIC_MODEL:-}" >>"$log"
  printf '<ENV_DEFAULT_OPUS:%s>\n' "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}" >>"$log"
  printf '<ENV_DEFAULT_SONNET:%s>\n' "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" >>"$log"
  printf '<ENV_DEFAULT_HAIKU:%s>\n' "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}" >>"$log"
  printf '<ENV_SUBAGENT_MODEL:%s>\n' "${CLAUDE_CODE_SUBAGENT_MODEL:-}" >>"$log"
  printf '<ENV_EFFORT_LEVEL:%s>\n' "${CLAUDE_CODE_EFFORT_LEVEL:-}" >>"$log"
  printf '<ENV_TZ:%s>\n' "${TZ:-}" >>"$log"
  printf '<ENV_LANG:%s>\n' "${LANG:-}" >>"$log"
  printf '<ENV_LC_ALL:%s>\n' "${LC_ALL:-}" >>"$log"
  printf '<ENV_LANGUAGE:%s>\n' "${LANGUAGE:-}" >>"$log"
  printf '<ENV_DISABLE_AUTOUPDATER:%s>\n' "${DISABLE_AUTOUPDATER:-}" >>"$log"
  printf '<ENV_DISABLE_TELEMETRY:%s>\n' "${DISABLE_TELEMETRY:-}" >>"$log"
  printf '<ENV_DISABLE_ERROR_REPORTING:%s>\n' "${DISABLE_ERROR_REPORTING:-}" >>"$log"
  printf '<ENV_DISABLE_FEEDBACK_COMMAND:%s>\n' "${DISABLE_FEEDBACK_COMMAND:-}" >>"$log"
  printf '<ENV_DISABLE_FEEDBACK_SURVEY:%s>\n' \
    "${CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY:-}" >>"$log"
  printf '<ENV_ATTRIBUTION_HEADER:%s>\n' \
    "${CLAUDE_CODE_ATTRIBUTION_HEADER:-}" >>"$log"
  printf '<ENV_MAX_OUTPUT_TOKENS:%s>\n' \
    "${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-}" >>"$log"
  printf '<ENV_LOWERCASE_VARIABLE:%s>\n' \
    "${lowercase_variable:-}" >>"$log"
}

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
  claude)
    record_claude_environment
    exit "${FAKE_FINAL_STATUS:-0}"
    ;;
  codex|custom-command)
    printf '<ENV_USER:%s>\n' "${USER:-}" >>"$log"
    printf '<ENV_CARGO_HOME:%s>\n' "${CARGO_HOME:-}" >>"$log"
    printf '<ENV_CARGO_TARGET_DIR:%s>\n' "${CARGO_TARGET_DIR:-}" >>"$log"
    printf '<ENV_XDG_DATA_HOME:%s>\n' "${XDG_DATA_HOME:-}" >>"$log"
    printf '<ENV_NPM_CONFIG_CACHE:%s>\n' "${NPM_CONFIG_CACHE:-}" >>"$log"
    printf '<ENV_PNPM_STORE_DIR:%s>\n' "${npm_config_store_dir:-}" >>"$log"
    record_claude_environment
    exit "${FAKE_FINAL_STATUS:-0}"
    ;;
esac
exit 2
EOF
  chmod +x "$fake_bin/fake-command"
  for command in getent groupadd useradd usermod mkdir chown gosu codex claude custom-command; do
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

  DOCKER_AGENT_AGENT_NOTES=$notes FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" codex --version

  assert_ordered_lines "$log" \
    "<codex>" \
    "<-c>" \
    "<user_instructions=test container notes>" \
    "<--version>"

  : >"$log"
  DOCKER_CODEX_AGENT_NOTES=$notes FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" codex --version

  assert_ordered_lines "$log" \
    "<codex>" \
    "<-c>" \
    "<user_instructions=test container notes>" \
    "<--version>"

  : >"$log"
  DOCKER_AGENT_AGENT_NOTES="$TEST_TMP/missing" \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" codex --version

  assert_no_line "<-c>" "$log"
  assert_ordered_lines "$log" "<codex>" "<--version>"
}

test_claude_profile_policy_locale_and_arguments_are_applied() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  local profile="$TEST_TMP/deepseek.env"
  local notes="$TEST_TMP/agent-notes.md"
  : >"$log"
  make_fake_system_commands "$fake_bin"
  printf '%s\n' \
    'ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic?mode=thinking"' \
    "ANTHROPIC_AUTH_TOKEN='entrypoint=secret'" \
    'ANTHROPIC_MODEL="deepseek-v4-pro[1m]"' \
    "ANTHROPIC_DEFAULT_OPUS_MODEL='deepseek-v4-pro[1m]'" \
    'ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-v4-pro[1m]"' \
    "ANTHROPIC_DEFAULT_HAIKU_MODEL='deepseek-v4-flash'" \
    "CLAUDE_CODE_SUBAGENT_MODEL='deepseek-v4-flash'" \
    'CLAUDE_CODE_EFFORT_LEVEL="extreme"' \
    'CLAUDE_CODE_MAX_OUTPUT_TOKENS=32000' \
    'lowercase_variable=from-profile' >"$profile"
  chmod 600 "$profile"
  printf 'container facts only\n' >"$notes"

  DOCKER_AGENT_CLAUDE_CONNECTION=profile:deepseek \
  DOCKER_AGENT_CLAUDE_PROFILE_FILE=$profile \
  DOCKER_AGENT_ENV_OVERRIDE_KEYS=CLAUDE_CODE_MAX_OUTPUT_TOKENS \
  CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000 \
  DOCKER_AGENT_AGENT_NOTES=$notes \
  HOST_UID=$(id -u) HOST_GID=$(id -g) \
  FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" claude --version

  assert_ordered_lines "$log" \
    "<claude>" \
    "<--dangerously-skip-permissions>" \
    "<--append-system-prompt-file>" \
    "<$notes>" \
    "<--version>"
  assert_line \
    "<ENV_ANTHROPIC_BASE_URL:https://api.deepseek.com/anthropic?mode=thinking>" \
    "$log"
  assert_line "<ENV_AUTH_TOKEN_SET:1>" "$log"
  assert_line "<ENV_API_KEY_SET:0>" "$log"
  assert_line "<ENV_ANTHROPIC_MODEL:deepseek-v4-pro[1m]>" "$log"
  assert_line "<ENV_DEFAULT_OPUS:deepseek-v4-pro[1m]>" "$log"
  assert_line "<ENV_DEFAULT_SONNET:deepseek-v4-pro[1m]>" "$log"
  assert_line "<ENV_DEFAULT_HAIKU:deepseek-v4-flash>" "$log"
  assert_line "<ENV_SUBAGENT_MODEL:deepseek-v4-flash>" "$log"
  assert_line "<ENV_EFFORT_LEVEL:extreme>" "$log"
  assert_line "<ENV_MAX_OUTPUT_TOKENS:64000>" "$log"
  assert_line "<ENV_LOWERCASE_VARIABLE:from-profile>" "$log"
  assert_line "<ENV_TZ:Etc/UTC>" "$log"
  assert_line "<ENV_LANG:en_US.UTF-8>" "$log"
  assert_line "<ENV_LC_ALL:en_US.UTF-8>" "$log"
  assert_line "<ENV_LANGUAGE:en_US:en>" "$log"
  assert_line "<ENV_DISABLE_AUTOUPDATER:1>" "$log"
  assert_line "<ENV_DISABLE_TELEMETRY:1>" "$log"
  assert_line "<ENV_DISABLE_ERROR_REPORTING:1>" "$log"
  assert_line "<ENV_DISABLE_FEEDBACK_COMMAND:1>" "$log"
  assert_line "<ENV_DISABLE_FEEDBACK_SURVEY:1>" "$log"
  assert_line "<ENV_ATTRIBUTION_HEADER:0>" "$log"
  assert_no_line "<entrypoint=secret>" "$log"
}

test_claude_profile_parser_accepts_arbitrary_literal_values() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  local profile="$TEST_TMP/profile.env"
  local errors="$TEST_TMP/errors"
  local marker="$TEST_TMP/command-was-executed"
  : >"$log"
  make_fake_system_commands "$fake_bin"

  printf '%s\n' \
    'ANTHROPIC_BASE_URL=https://example.invalid/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=one' \
    'ANTHROPIC_AUTH_TOKEN=two' >"$profile"
  chmod 600 "$profile"
  if DOCKER_AGENT_CLAUDE_CONNECTION=profile:invalid \
    DOCKER_AGENT_CLAUDE_PROFILE_FILE=$profile \
    HOST_UID=$(id -u) HOST_GID=$(id -g) \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
      run_entrypoint "$fake_bin" "$log" claude 2>"$errors"; then
    fail "duplicate Claude profile key unexpectedly succeeded"
  fi
  assert_contains "duplicate Claude profile key: ANTHROPIC_AUTH_TOKEN" "$errors"

  printf '%s\n' \
    'ANTHROPIC_BASE_URL=https://example.invalid/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=one' \
    'ANTHROPIC_API_KEY=two' >"$profile"
  if DOCKER_AGENT_CLAUDE_CONNECTION=profile:invalid \
    DOCKER_AGENT_CLAUDE_PROFILE_FILE=$profile \
    HOST_UID=$(id -u) HOST_GID=$(id -g) \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
      run_entrypoint "$fake_bin" "$log" claude 2>"$errors"; then
    fail "conflicting Claude credentials unexpectedly succeeded"
  fi
  assert_contains "exactly one credential" "$errors"

  printf '%s\n' \
    'ANTHROPIC_BASE_URL=https://example.invalid/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=literal-secret' \
    "ANTHROPIC_MODEL=\"\$(touch $marker)\"" >"$profile"
  : >"$log"
  DOCKER_AGENT_CLAUDE_CONNECTION=profile:literal \
  DOCKER_AGENT_CLAUDE_PROFILE_FILE=$profile \
  HOST_UID=$(id -u) HOST_GID=$(id -g) \
  FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" claude
  [[ ! -e $marker ]] || fail "literal profile command substitution was executed"
  assert_line "<ENV_ANTHROPIC_MODEL:\$(touch $marker)>" "$log"

  printf '%s\n' \
    'ANTHROPIC_BASE_URL=https://example.invalid/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=literal-secret' \
    "ANTHROPIC_MODEL='\$(touch $marker)\"" >"$profile"
  if DOCKER_AGENT_CLAUDE_CONNECTION=profile:invalid \
    DOCKER_AGENT_CLAUDE_PROFILE_FILE=$profile \
    HOST_UID=$(id -u) HOST_GID=$(id -g) \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
      run_entrypoint "$fake_bin" "$log" claude 2>"$errors"; then
    fail "mismatched profile quotes unexpectedly succeeded"
  fi
  [[ ! -e $marker ]] || fail "mismatched profile quote executed a command"
  assert_contains "unmatched quote in Claude profile value" "$errors"
}

test_claude_profile_connection_contract_and_file_metadata_are_enforced() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  local profile="$TEST_TMP/official-api.env"
  local link="$TEST_TMP/profile-link.env"
  local errors="$TEST_TMP/errors"
  : >"$log"
  make_fake_system_commands "$fake_bin"

  printf '%s\n' \
    'ANTHROPIC_BASE_URL=https://api.anthropic.com' \
    'ANTHROPIC_API_KEY=official-secret' >"$profile"
  chmod 600 "$profile"
  if DOCKER_AGENT_CLAUDE_CONNECTION=official-api \
    DOCKER_AGENT_CLAUDE_PROFILE_FILE=$profile \
    HOST_UID=$(id -u) HOST_GID=$(id -g) \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
      run_entrypoint "$fake_bin" "$log" claude 2>"$errors"; then
    fail "official API profile with a custom endpoint unexpectedly succeeded"
  fi
  assert_contains "official API profile requires only ANTHROPIC_API_KEY" "$errors"

  printf '%s\n' 'ANTHROPIC_API_KEY=official-secret' >"$profile"
  : >"$log"
  DOCKER_AGENT_CLAUDE_CONNECTION=official-api \
  DOCKER_AGENT_CLAUDE_PROFILE_FILE=$profile \
  HOST_UID=$(id -u) HOST_GID=$(id -g) \
  FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" claude
  assert_line "<ENV_API_KEY_SET:1>" "$log"
  assert_line "<ENV_AUTH_TOKEN_SET:0>" "$log"
  assert_not_contains "official-secret" "$log"

  if DOCKER_AGENT_CLAUDE_CONNECTION=profile:missing \
    DOCKER_AGENT_CLAUDE_PROFILE_FILE="$TEST_TMP/missing.env" \
    HOST_UID=$(id -u) HOST_GID=$(id -g) \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
      run_entrypoint "$fake_bin" "$log" claude 2>"$errors"; then
    fail "missing Claude profile unexpectedly succeeded"
  fi
  assert_contains "Claude profile does not exist" "$errors"

  if DOCKER_AGENT_CLAUDE_CONNECTION=profile:missing \
    HOST_UID=$(id -u) HOST_GID=$(id -g) \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
      run_entrypoint "$fake_bin" "$log" claude 2>"$errors"; then
    fail "custom connection without a profile unexpectedly succeeded"
  fi
  assert_contains "requires a profile file" "$errors"

  if DOCKER_AGENT_CLAUDE_CONNECTION=official-subscription \
    DOCKER_AGENT_CLAUDE_PROFILE_FILE=$profile \
    HOST_UID=$(id -u) HOST_GID=$(id -g) \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
      run_entrypoint "$fake_bin" "$log" claude 2>"$errors"; then
    fail "subscription connection with a profile unexpectedly succeeded"
  fi
  assert_contains "must not use a profile file" "$errors"

  if DOCKER_AGENT_CLAUDE_CONNECTION=official-api \
    DOCKER_AGENT_CLAUDE_PROFILE_FILE=$profile \
    HOST_UID=99999 HOST_GID=$(id -g) \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
      run_entrypoint "$fake_bin" "$log" claude 2>"$errors"; then
    fail "Claude profile with an unexpected owner identity succeeded"
  fi
  assert_contains "Claude profile has unexpected owner" "$errors"

  chmod 640 "$profile"
  if DOCKER_AGENT_CLAUDE_CONNECTION=official-api \
    DOCKER_AGENT_CLAUDE_PROFILE_FILE=$profile \
    HOST_UID=$(id -u) HOST_GID=$(id -g) \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
      run_entrypoint "$fake_bin" "$log" claude 2>"$errors"; then
    fail "group-readable Claude profile unexpectedly succeeded"
  fi
  assert_contains "must have mode 600" "$errors"

  chmod 600 "$profile"
  ln -s "$profile" "$link"
  if DOCKER_AGENT_CLAUDE_CONNECTION=official-api \
    DOCKER_AGENT_CLAUDE_PROFILE_FILE=$link \
    HOST_UID=$(id -u) HOST_GID=$(id -g) \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
      run_entrypoint "$fake_bin" "$log" claude 2>"$errors"; then
    fail "symlink Claude profile unexpectedly succeeded"
  fi
  assert_contains "regular non-symlink file" "$errors"
}

test_claude_missing_notes_and_exit_status_are_preserved() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  local status
  : >"$log"
  make_fake_system_commands "$fake_bin"

  set +e
  DOCKER_AGENT_CLAUDE_CONNECTION=official-subscription \
  DOCKER_AGENT_AGENT_NOTES="$TEST_TMP/missing-notes.md" \
  FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 FAKE_FINAL_STATUS=23 \
    run_entrypoint "$fake_bin" "$log" claude --version
  status=$?
  set -e

  [[ $status == 23 ]] ||
    fail "expected Claude status 23, got $status"
  assert_no_line "<--append-system-prompt-file>" "$log"
  assert_ordered_lines "$log" \
    "<claude>" \
    "<--dangerously-skip-permissions>" \
    "<--version>"
}

test_claude_environment_policy_does_not_change_other_commands() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  : >"$log"
  make_fake_system_commands "$fake_bin"

  TZ=Asia/Shanghai LANG=C LC_ALL=C LANGUAGE=host-language \
  DISABLE_AUTOUPDATER=host-autoupdater \
  DISABLE_TELEMETRY=host-telemetry \
  DISABLE_ERROR_REPORTING=host-errors \
  DISABLE_FEEDBACK_COMMAND=host-feedback \
  CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=host-survey \
  CLAUDE_CODE_ATTRIBUTION_HEADER=host-attribution \
  FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" custom-command

  assert_line "<ENV_TZ:Asia/Shanghai>" "$log"
  assert_line "<ENV_LANG:C>" "$log"
  assert_line "<ENV_LC_ALL:C>" "$log"
  assert_line "<ENV_LANGUAGE:host-language>" "$log"
  assert_line "<ENV_DISABLE_AUTOUPDATER:host-autoupdater>" "$log"
  assert_line "<ENV_DISABLE_TELEMETRY:host-telemetry>" "$log"
  assert_line "<ENV_DISABLE_ERROR_REPORTING:host-errors>" "$log"
  assert_line "<ENV_DISABLE_FEEDBACK_COMMAND:host-feedback>" "$log"
  assert_line "<ENV_DISABLE_FEEDBACK_SURVEY:host-survey>" "$log"
  assert_line "<ENV_ATTRIBUTION_HEADER:host-attribution>" "$log"
}

init_tests
test_missing_uid_and_gid_are_created_without_touching_shared_mounts
test_existing_gid_is_reused_and_existing_uid_skips_user_creation
test_login_failure_warns_but_still_runs_codex
test_final_command_exit_status_is_preserved
test_existing_user_and_package_caches_are_exported_consistently
test_cargo_target_dir_is_scoped_per_worktree
test_agent_notes_are_injected_into_codex_invocation
test_claude_profile_policy_locale_and_arguments_are_applied
test_claude_profile_parser_accepts_arbitrary_literal_values
test_claude_profile_connection_contract_and_file_metadata_are_enforced
test_claude_missing_notes_and_exit_status_are_preserved
test_claude_environment_policy_does_not_change_other_commands
printf 'entrypoint tests: PASS\n'
