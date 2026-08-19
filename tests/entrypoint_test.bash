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
  printf '<ENV_TERM:%s>\n' "${TERM:-}" >>"$log"
}

case $name in
  getent)
    if [[ $1 == group && -n ${HOST_DOCKER_GID:-} && $2 == "$HOST_DOCKER_GID" ]]; then
      if [[ ${FAKE_DOCKER_GROUP_EXISTS:-0} == 1 ]]; then
        printf 'docker-existing:x:%s:\n' "$2"
        exit 0
      fi
      exit 2
    fi
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
  groupadd|useradd|usermod|mkdir|chown|cp|ln)
    exit 0
    ;;
  gosu)
    shift
    if [[ ${1:-} == codex && ${2:-} == login && ${3:-} == status ]]; then
      exit "${FAKE_LOGIN_STATUS:-0}"
    fi
    exec "$@"
    ;;
  setpriv)
    shift 4
    exec "$@"
    ;;
  claude)
    record_claude_environment
    exit "${FAKE_FINAL_STATUS:-0}"
    ;;
  kimi)
    printf '<ENV_KIMI_CODE_HOME:%s>\n' "${KIMI_CODE_HOME:-}" >>"$log"
    printf '<ENV_HOME:%s>\n' "${HOME:-}" >>"$log"
    exit "${FAKE_FINAL_STATUS:-0}"
    ;;
  cursor-agent)
    printf '<ENV_CURSOR_API_KEY:%s>\n' "${CURSOR_API_KEY:-}" >>"$log"
    exit "${FAKE_FINAL_STATUS:-0}"
    ;;
  codex|custom-command)
    printf '<ENV_USER:%s>\n' "${USER:-}" >>"$log"
    printf '<ENV_CARGO_HOME:%s>\n' "${CARGO_HOME:-}" >>"$log"
    printf '<ENV_CARGO_TARGET_DIR:%s>\n' "${CARGO_TARGET_DIR:-}" >>"$log"
    printf '<ENV_GOPATH:%s>\n' "${GOPATH:-}" >>"$log"
    printf '<ENV_GOMODCACHE:%s>\n' "${GOMODCACHE:-}" >>"$log"
    printf '<ENV_GOCACHE:%s>\n' "${GOCACHE:-}" >>"$log"
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
  for command in getent groupadd useradd usermod mkdir chown cp ln gosu setpriv codex claude kimi cursor-agent custom-command; do
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
  assert_contiguous_lines "$log" \
    "<CALL:useradd>" "<-K>" "<UID_MIN=0>" "<--uid>" "<501>"
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

test_host_docker_gid_adds_runtime_user_to_socket_group() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  : >"$log"
  make_fake_system_commands "$fake_bin"

  HOST_UID=1000 HOST_GID=1000 HOST_DOCKER_GID=34567 \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    FAKE_DOCKER_GROUP_EXISTS=0 \
    run_entrypoint "$fake_bin" "$log" custom-command

  assert_contiguous_lines "$log" \
    "<CALL:groupadd>" "<--gid>" "<34567>" "<docker-host>"
  assert_contiguous_lines "$log" \
    "<CALL:usermod>" "<--append>" "<--groups>" "<docker-host>" "<existing>"

  : >"$log"
  HOST_UID=1000 HOST_GID=1000 HOST_DOCKER_GID=34567 \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    FAKE_DOCKER_GROUP_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" custom-command

  assert_no_contiguous_lines "$log" \
    "<CALL:groupadd>" "<--gid>" "<34567>" "<docker-host>"
  assert_contiguous_lines "$log" \
    "<CALL:usermod>" "<--append>" "<--groups>" "<docker-existing>" "<existing>"
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
  assert_line "<ENV_GOPATH:/codex-cache/go>" "$log"
  assert_line "<ENV_GOMODCACHE:/codex-cache/go/pkg/mod>" "$log"
  assert_line "<ENV_GOCACHE:/codex-cache/go-build>" "$log"
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
  expected="/codex-cache/cargo-targets/$(basename "$root")-$(printf '%s' "$root" | sha256_stdin | cut -c1-16)"
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
  expected="/codex-cache/cargo-targets/$(basename "$root")-$(printf '%s' "$root" | sha256_stdin | cut -c1-16)"
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
    "<developer_instructions=test container notes>" \
    "<--version>"

  : >"$log"
  DOCKER_CODEX_AGENT_NOTES=$notes FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" codex --version

  assert_ordered_lines "$log" \
    "<codex>" \
    "<-c>" \
    "<developer_instructions=test container notes>" \
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
  local profile_was_root_owned=0
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

  # The Bash 3.2 compatibility suite itself runs as root, which is now a valid
  # translated bind-mount owner. Give this negative case a third UID so it
  # remains neither HOST_UID nor the accepted root translation.
  if [[ $(id -u) == 0 ]]; then
    chown 12345 "$profile"
    profile_was_root_owned=1
  fi
  if DOCKER_AGENT_CLAUDE_CONNECTION=official-api \
    DOCKER_AGENT_CLAUDE_PROFILE_FILE=$profile \
    HOST_UID=99999 HOST_GID=$(id -g) \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
      run_entrypoint "$fake_bin" "$log" claude 2>"$errors"; then
    fail "Claude profile with an unexpected owner identity succeeded"
  fi
  assert_contains "Claude profile has unexpected owner" "$errors"
  ((profile_was_root_owned == 0)) || chown 0 "$profile"

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

test_kimi_data_root_and_notes_are_prepared() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  local notes="$TEST_TMP/agent-notes.md"
  : >"$log"
  make_fake_system_commands "$fake_bin"
  printf '%s\n' 'container notes' >"$notes"

  DOCKER_AGENT_AGENT_NOTES="$notes" \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" kimi --yolo

  assert_line "<ENV_KIMI_CODE_HOME:/kimi-home>" "$log"
  assert_line "<ENV_HOME:/home/codex>" "$log"
  # Kimi Code has no flag to append instructions, so the notes are placed at
  # the generic cross-tool path that os.homedir() resolves to.
  assert_contiguous_lines "$log" "<CALL:mkdir>" "<-p>" "</home/codex/.agents>"
  assert_contiguous_lines "$log" \
    "<CALL:cp>" "<$notes>" "</home/codex/.agents/AGENTS.md>"
  assert_contiguous_lines "$log" \
    "<CALL:chown>" "<12345:23456>" "</home/codex/.agents>" \
    "</home/codex/.agents/AGENTS.md>"
  # The notes must not be written into the shared host data root.
  assert_no_line "</kimi-home/AGENTS.md>" "$log"
  assert_line "<--yolo>" "$log"
}

test_kimi_keeps_an_explicit_data_root_and_skips_missing_notes() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  : >"$log"
  make_fake_system_commands "$fake_bin"

  KIMI_CODE_HOME=/custom-kimi \
    DOCKER_AGENT_AGENT_NOTES="$TEST_TMP/absent.md" \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" kimi

  assert_line "<ENV_KIMI_CODE_HOME:/custom-kimi>" "$log"
  assert_no_line "<CALL:cp>" "$log"
}

test_kimi_environment_policy_does_not_change_other_commands() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  local notes="$TEST_TMP/agent-notes.md"
  : >"$log"
  make_fake_system_commands "$fake_bin"
  printf '%s\n' 'container notes' >"$notes"

  DOCKER_AGENT_AGENT_NOTES="$notes" \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" custom-command

  assert_no_line "<CALL:cp>" "$log"
}

test_unknown_terminal_falls_back_without_losing_color_depth() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  local errors="$TEST_TMP/errors"
  : >"$log"
  make_fake_system_commands "$fake_bin"

  # A terminal the image knows: forwarded unchanged.
  TERM=xterm-256color FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" custom-command
  assert_line "<ENV_TERM:xterm-256color>" "$log"

  # A terminal it does not know would break curses, so fall back to a
  # 256-color entry rather than leaving it broken or dropping to 8 colors.
  : >"$log"
  TERM=xterm-nonexistent-terminal FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" custom-command 2>"$errors"
  assert_line "<ENV_TERM:xterm-256color>" "$log"
  assert_contains "no terminfo entry for xterm-nonexistent-terminal" "$errors"

  # bash substitutes dumb when TERM is absent, and dumb is a real terminfo
  # entry, so a non-interactive run must keep it instead of being upgraded.
  : >"$log"
  TERM=dumb FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" custom-command
  assert_line "<ENV_TERM:dumb>" "$log"
}

test_cursor_api_key_is_read_from_the_mounted_file() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  local key_file="$TEST_TMP/cursor-api-key"
  : >"$log"
  make_fake_system_commands "$fake_bin"
  # A trailing newline is normal in a file written by an editor.
  printf '%s\n' 'key-from-file' >"$key_file"

  DOCKER_AGENT_CURSOR_API_KEY_FILE="$key_file" \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" cursor-agent --force

  assert_line "<ENV_CURSOR_API_KEY:key-from-file>" "$log"
  assert_line "<--force>" "$log"
}

test_cursor_shared_data_root_is_linked_into_the_container_home() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  local key_file="$TEST_TMP/cursor-api-key"
  local mount_dir="$TEST_TMP/cursor-home"
  : >"$log"
  make_fake_system_commands "$fake_bin"
  printf '%s\n' 'key-from-file' >"$key_file"
  mkdir -p "$mount_dir"

  DOCKER_AGENT_CURSOR_API_KEY_FILE="$key_file" \
    DOCKER_AGENT_CURSOR_HOME_MOUNT="$mount_dir" \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" cursor-agent

  # Without this link the workspace-trust marker and session history under
  # .cursor/projects would be recreated on every launch.
  assert_contiguous_lines "$log" \
    "<CALL:ln>" "<-s>" "<$mount_dir>" "</home/codex/.cursor>"
  assert_contiguous_lines "$log" \
    "<CALL:chown>" "<-h>" "<12345:23456>" "</home/codex/.cursor>"
}

test_cursor_link_is_skipped_when_the_mount_is_absent() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  local key_file="$TEST_TMP/cursor-api-key"
  : >"$log"
  make_fake_system_commands "$fake_bin"
  printf '%s\n' 'key-from-file' >"$key_file"

  DOCKER_AGENT_CURSOR_API_KEY_FILE="$key_file" \
    DOCKER_AGENT_CURSOR_HOME_MOUNT="$TEST_TMP/absent" \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" cursor-agent

  assert_no_line "<CALL:ln>" "$log"
  assert_line "<ENV_CURSOR_API_KEY:key-from-file>" "$log"
}

test_cursor_missing_or_empty_key_fails_before_launching() {
  local TEST_TMP status
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  local errors="$TEST_TMP/errors"
  local key_file="$TEST_TMP/cursor-api-key"
  : >"$log"
  make_fake_system_commands "$fake_bin"

  status=0
  DOCKER_AGENT_CURSOR_API_KEY_FILE="$TEST_TMP/absent" \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" cursor-agent >"$errors" 2>&1 || status=$?
  ((status != 0)) || fail "a missing key file unexpectedly succeeded"
  assert_contains "Cursor API key is not readable" "$errors"
  assert_no_line "<CALL:cursor-agent>" "$log"

  : >"$key_file"
  status=0
  DOCKER_AGENT_CURSOR_API_KEY_FILE="$key_file" \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" cursor-agent >"$errors" 2>&1 || status=$?
  ((status != 0)) || fail "an empty key file unexpectedly succeeded"
  assert_contains "Cursor API key file is empty" "$errors"
}

test_cursor_key_is_not_exported_for_other_agents() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin"
  local log="$TEST_TMP/system.log"
  local key_file="$TEST_TMP/cursor-api-key"
  : >"$log"
  make_fake_system_commands "$fake_bin"
  printf '%s\n' 'key-from-file' >"$key_file"

  DOCKER_AGENT_CURSOR_API_KEY_FILE="$key_file" \
    FAKE_GROUP_EXISTS=1 FAKE_PASSWD_EXISTS=1 \
    run_entrypoint "$fake_bin" "$log" custom-command

  assert_no_line "<ENV_CURSOR_API_KEY:key-from-file>" "$log"
}

init_tests
test_missing_uid_and_gid_are_created_without_touching_shared_mounts
test_existing_gid_is_reused_and_existing_uid_skips_user_creation
test_host_docker_gid_adds_runtime_user_to_socket_group
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
test_kimi_data_root_and_notes_are_prepared
test_kimi_keeps_an_explicit_data_root_and_skips_missing_notes
test_kimi_environment_policy_does_not_change_other_commands
test_cursor_api_key_is_read_from_the_mounted_file
test_cursor_shared_data_root_is_linked_into_the_container_home
test_cursor_link_is_skipped_when_the_mount_is_absent
test_cursor_missing_or_empty_key_fails_before_launching
test_cursor_key_is_not_exported_for_other_agents
test_unknown_terminal_falls_back_without_losing_color_depth
printf 'entrypoint tests: PASS\n'
