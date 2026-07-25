#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
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
log=${DOCKER_CODEX_TEST_DOCKER_LOG:?}
printf 'CALL\n' >>"$log"
printf '<%s>\n' "$@" >>"$log"
case ${1:-} in
  info|image|build|run) exit 0 ;;
esac
exit 2
EOF
  chmod +x "$path"
}

prepare_fake_runtime() {
  local base=$1
  TEST_CODEX_HOME="$base/codex home"
  TEST_DOCKER="$base/docker"
  TEST_DOCKER_LOG="$base/docker.log"
  mkdir -p "$TEST_CODEX_HOME"
  : >"$TEST_DOCKER_LOG"
  make_fake_docker "$TEST_DOCKER"
}

run_launcher() {
  local directory=$1 project_root=$2
  shift 2
  (
    cd "$directory"
    CODEX_HOME="$TEST_CODEX_HOME" \
      DOCKER_CODEX_DOCKER_BIN="$TEST_DOCKER" \
      DOCKER_CODEX_TEST_DOCKER_LOG="$TEST_DOCKER_LOG" \
      "$project_root/docker-codex" "$@"
  )
}
