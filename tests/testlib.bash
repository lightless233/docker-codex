#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

file_gid() {
  if stat -c %g "$1" >/dev/null 2>&1; then
    stat -c %g "$1"
  else
    stat -f %g "$1"
  fi
}

file_mode() {
  if stat -c %a "$1" >/dev/null 2>&1; then
    stat -c %a "$1"
  else
    stat -f %Lp "$1"
  fi
}

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    shasum -a 256
  fi
}

git_metadata_dir() {
  local checkout=$1 option=$2 path
  path=$(git -C "$checkout" rev-parse "$option")
  if [[ $path != /* ]]; then
    path="$checkout/$path"
  fi
  (cd "$path" && pwd -P)
}

assert_line() {
  local expected=$1 file=$2
  grep -Fqx -- "$expected" "$file" ||
    fail "missing line <$expected> in $file"
}

assert_no_line() {
  local unexpected=$1 file=$2
  if grep -Fqx -- "$unexpected" "$file"; then
    fail "unexpected line <$unexpected> in $file"
  fi
}

assert_contains() {
  local expected=$1 file=$2
  grep -Fq -- "$expected" "$file" ||
    fail "missing text <$expected> in $file"
}

assert_not_contains() {
  local unexpected=$1 file=$2
  if grep -Fq -- "$unexpected" "$file"; then
    fail "unexpected text <$unexpected> in $file"
  fi
}

contains_contiguous_lines() {
  local file=$1
  shift
  (($# > 0)) || return 0
  local expected=("$@")
  local matched=0 line

  while IFS= read -r line; do
    if [[ $line == "${expected[$matched]}" ]]; then
      matched=$((matched + 1))
      ((matched == ${#expected[@]})) && return 0
    elif [[ $line == "${expected[0]}" ]]; then
      matched=1
    else
      matched=0
    fi
  done <"$file"
  return 1
}

assert_contiguous_lines() {
  local file=$1
  shift
  contains_contiguous_lines "$file" "$@" ||
    fail "missing contiguous lines <$*> in $file"
}

assert_no_contiguous_lines() {
  local file=$1
  shift
  if contains_contiguous_lines "$file" "$@"; then
    fail "unexpected contiguous lines <$*> in $file"
  fi
}

assert_ordered_lines() {
  local file=$1
  shift
  local expected line_number last_line=0
  for expected in "$@"; do
    line_number=$(awk -v target="$expected" '$0 == target { print NR; exit }' "$file")
    [[ -n $line_number ]] ||
      fail "missing ordered line <$expected> in $file"
    ((line_number > last_line)) ||
      fail "line <$expected> is out of order in $file"
    last_line=$line_number
  done
}

init_tests() {
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/docker-codex-test.XXXXXX")
  trap 'rm -rf "$TEST_ROOT"' EXIT
}

new_tmp() {
  mktemp -d "$TEST_ROOT/case.XXXXXX"
}

make_repo() {
  local path=$1
  mkdir -p "$path"
  git init -q "$path"
  git -C "$path" config user.name Test
  git -C "$path" config user.email test@example.invalid
  printf 'seed\n' >"$path/seed.txt"
  git -C "$path" add seed.txt
  git -C "$path" commit -qm seed
}

make_fake_docker() {
  local path=$1
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log=${DOCKER_AGENT_TEST_DOCKER_LOG:-${DOCKER_CODEX_TEST_DOCKER_LOG:?}}
printf 'CALL\n' >>"$log"
printf '<%s>\n' "$@" >>"$log"
case ${1:-} in
  buildx)
    [[ ${2:-} == version ]] || exit 2
    exit "${DOCKER_AGENT_TEST_BUILDX_STATUS:-0}"
    ;;
  network)
    network_state="${log}.networks"
    case ${2:-} in
      inspect)
        grep -Fqx -- "${3:-}" "$network_state" 2>/dev/null
        ;;
      create)
        network_name=${!#}
        printf '%s\n' "$network_name" >>"$network_state"
        ;;
      *) exit 2 ;;
    esac
    exit 0
    ;;
  info) exit "${DOCKER_AGENT_TEST_INFO_STATUS:-0}" ;;
  image|build|run) exit 0 ;;
esac
exit 2
EOF
  chmod +x "$path"
}

prepare_fake_runtime() {
  local base=$1
  TEST_CODEX_HOME="$base/codex home"
  TEST_AGENT_CONFIG_HOME="$base/agent config"
  TEST_AGENT_DATA_HOME="$base/agent data"
  TEST_CLAUDE_HOME="$base/host claude"
  # Left uncreated on purpose: the launcher is expected to create the Kimi
  # Code data directory when the host does not have one yet.
  TEST_KIMI_HOME="$base/host kimi"
  # Same for Cursor Agent, and pointing it here keeps tests away from the
  # real ~/.cursor on the machine running them.
  TEST_CURSOR_HOME="$base/host cursor"
  TEST_DOCKER="$base/docker"
  TEST_DOCKER_LOG="$base/docker.log"
  mkdir -p "$TEST_CODEX_HOME"
  install -d -m 700 "$TEST_AGENT_CONFIG_HOME/claude/profiles"
  install -d -m 700 "$TEST_AGENT_DATA_HOME"
  install -d -m 700 "$TEST_CLAUDE_HOME"
  printf '%s\n' '{"test":"credential"}' \
    >"$TEST_CLAUDE_HOME/.credentials.json"
  chmod 600 "$TEST_CLAUDE_HOME/.credentials.json"
  : >"$TEST_DOCKER_LOG"
  make_fake_docker "$TEST_DOCKER"
}

run_named_launcher() {
  local directory=$1 project_root=$2 launcher_name=$3
  local agent_config_home=${DOCKER_AGENT_CONFIG_HOME:-$TEST_AGENT_CONFIG_HOME}
  local agent_data_home
  local host_claude_home=${CLAUDE_CONFIG_DIR:-$TEST_CLAUDE_HOME}
  local host_kimi_home=${KIMI_CODE_HOME:-$TEST_KIMI_HOME}
  local host_cursor_home=${DOCKER_AGENT_CURSOR_HOME:-$TEST_CURSOR_HOME}
  if [[ -n ${DOCKER_AGENT_DATA_HOME+x} ]]; then
    agent_data_home=$DOCKER_AGENT_DATA_HOME
  elif [[ -n ${DOCKER_CODEX_DATA_HOME+x} ]]; then
    agent_data_home=
  else
    agent_data_home=$TEST_AGENT_DATA_HOME
  fi
  shift 3
  (
    cd "$directory"
    CODEX_HOME="$TEST_CODEX_HOME" \
      DOCKER_AGENT_CONFIG_HOME="$agent_config_home" \
      DOCKER_AGENT_DATA_HOME="$agent_data_home" \
      CLAUDE_CONFIG_DIR="$host_claude_home" \
      KIMI_CODE_HOME="$host_kimi_home" \
      DOCKER_AGENT_CURSOR_HOME="$host_cursor_home" \
      DOCKER_AGENT_DOCKER_BIN="$TEST_DOCKER" \
      DOCKER_AGENT_TEST_DOCKER_LOG="$TEST_DOCKER_LOG" \
      "$project_root/$launcher_name" "$@"
  )
}

run_launcher() {
  local directory=$1 project_root=$2
  shift 2
  run_named_launcher "$directory" "$project_root" docker-codex "$@"
}
