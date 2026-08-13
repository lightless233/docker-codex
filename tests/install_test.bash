#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/testlib.bash
source "$ROOT/tests/testlib.bash"

test_installer_copies_all_launchers_from_any_working_directory() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local prefix="$TEST_TMP/install prefix"
  local elsewhere="$TEST_TMP/elsewhere"
  local name installed mode
  mkdir -p "$elsewhere"

  (
    cd "$elsewhere"
    "$ROOT/install.sh" --prefix "$prefix"
  )

  for name in docker-agent docker-codex docker-claude docker-kimi docker-cursor-agent; do
    installed="$prefix/bin/$name"
    [[ -f $installed && ! -L $installed ]] ||
      fail "$name was not installed as a regular file"
    [[ -x $installed ]] || fail "$name is not executable"
    if stat -c %a "$installed" >/dev/null 2>&1; then
      mode=$(stat -c %a "$installed")
    else
      mode=$(stat -f %Lp "$installed")
    fi
    [[ $mode == 755 ]] ||
      fail "$name does not have mode 755"
    cmp -s "$ROOT/docker-agent" "$installed" ||
      fail "$name does not match docker-agent"
  done

  assert_contains "Usage: docker-agent" \
    <("$prefix/bin/docker-agent" --help)
  assert_contains "Usage: docker-codex" \
    <("$prefix/bin/docker-codex" --help)
  assert_contains "Usage: docker-claude" \
    <("$prefix/bin/docker-claude" --help)
  assert_contains "Usage: docker-kimi" \
    <("$prefix/bin/docker-kimi" --help)
  assert_contains "Usage: docker-cursor-agent" \
    <("$prefix/bin/docker-cursor-agent" --help)
}

test_installer_rejects_invalid_arguments_without_installing() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local prefix="$TEST_TMP/prefix"
  local errors="$TEST_TMP/errors"

  if "$ROOT/install.sh" --unknown >"$errors" 2>&1; then
    fail "unknown installer option unexpectedly succeeded"
  fi
  assert_contains "unknown option: --unknown" "$errors"

  if "$ROOT/install.sh" --prefix >"$errors" 2>&1; then
    fail "missing prefix value unexpectedly succeeded"
  fi
  assert_contains "--prefix requires a value" "$errors"
  [[ ! -e $prefix ]] || fail "invalid invocation created an install prefix"
}

test_installer_help_documents_system_and_user_prefixes() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local output="$TEST_TMP/help"

  "$ROOT/install.sh" --help >"$output"

  assert_contains "Usage: install.sh [--prefix PREFIX]" "$output"
  assert_contains "Default: /usr/local" "$output"
  assert_contains "--prefix \"\$HOME/.local\"" "$output"
}

init_tests
test_installer_copies_all_launchers_from_any_working_directory
test_installer_rejects_invalid_arguments_without_installing
test_installer_help_documents_system_and_user_prefixes
printf 'install tests: ok\n'
