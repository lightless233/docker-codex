#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/testlib.bash
source "$ROOT/tests/testlib.bash"

test_normal_checkout_preserves_paths_and_codex_arguments() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo with spaces"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  run_launcher "$repo" "$ROOT" -- review "prompt with spaces"

  assert_line "<type=bind,source=$repo,target=$repo>" "$TEST_DOCKER_LOG"
  assert_line "<type=bind,source=$TEST_CODEX_HOME,target=/codex-home>" "$TEST_DOCKER_LOG"
  assert_line "<--workdir>" "$TEST_DOCKER_LOG"
  assert_line "<$repo>" "$TEST_DOCKER_LOG"
  assert_line "<codex>" "$TEST_DOCKER_LOG"
  assert_line "<review>" "$TEST_DOCKER_LOG"
  assert_line "<prompt with spaces>" "$TEST_DOCKER_LOG"
  assert_ordered_lines "$TEST_DOCKER_LOG" \
    "<codex>" \
    "<--yolo>" \
    "<--disable>" \
    "<apps>" \
    "<review>" \
    "<prompt with spaces>"
  assert_no_line "<type=bind,source=$repo/.git,target=$repo/.git>" "$TEST_DOCKER_LOG"
}

test_linked_worktree_mounts_external_git_metadata_and_readonly_bind() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local main="$TEST_TMP/main repo"
  local worktree="$TEST_TMP/linked worktree"
  local fixture="$TEST_TMP/fixture data"
  local common_dir
  make_repo "$main"
  git -C "$main" worktree add -qb linked "$worktree"
  mkdir -p "$worktree/sub dir" "$fixture"
  common_dir=$(cd "$main/.git" && pwd -P)
  prepare_fake_runtime "$TEST_TMP"

  run_launcher "$worktree/sub dir" "$ROOT" --bind "$fixture:ro" -- status

  assert_line "<type=bind,source=$worktree,target=$worktree>" "$TEST_DOCKER_LOG"
  assert_line "<type=bind,source=$common_dir,target=$common_dir>" "$TEST_DOCKER_LOG"
  assert_line "<type=bind,source=$fixture,target=$fixture,readonly>" "$TEST_DOCKER_LOG"
  assert_line "<$worktree/sub dir>" "$TEST_DOCKER_LOG"
}

test_submodule_mounts_external_git_metadata() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local child="$TEST_TMP/child source"
  local parent="$TEST_TMP/parent repo"
  local submodule
  local git_dir
  make_repo "$child"
  make_repo "$parent"
  git -c protocol.file.allow=always -C "$parent" submodule add -q "$child" "modules/child"
  git -C "$parent" commit -qam submodule
  submodule="$parent/modules/child"
  git_dir=$(git -C "$submodule" rev-parse --path-format=absolute --git-dir)
  git_dir=$(cd "$git_dir" && pwd -P)
  prepare_fake_runtime "$TEST_TMP"

  run_launcher "$submodule" "$ROOT" -- status

  assert_line "<type=bind,source=$submodule,target=$submodule>" "$TEST_DOCKER_LOG"
  assert_line "<type=bind,source=$git_dir,target=$git_dir>" "$TEST_DOCKER_LOG"
}

test_darwin_does_not_add_linux_host_gateway() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  (
    export DOCKER_CODEX_HOST_OS=Darwin
    run_launcher "$repo" "$ROOT" -- status
  )

  assert_no_line "<host.docker.internal:host-gateway>" "$TEST_DOCKER_LOG"
}

test_bad_bind_paths_fail_before_docker_run() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local comma_path="$TEST_TMP/fixture,comma"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  mkdir -p "$comma_path"
  prepare_fake_runtime "$TEST_TMP"

  if run_launcher "$repo" "$ROOT" --bind "$TEST_TMP/missing" -- >"$errors" 2>&1; then
    fail "missing bind source unexpectedly succeeded"
  fi
  assert_contains "bind source does not exist" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"

  : >"$TEST_DOCKER_LOG"
  if run_launcher "$repo" "$ROOT" --bind "$comma_path" -- >"$errors" 2>&1; then
    fail "comma bind source unexpectedly succeeded"
  fi
  assert_contains "containing commas are unsupported" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
}

test_isolated_mode_creates_and_preserves_worktree() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local data_home="$TEST_TMP/docker codex data"
  local common_dir
  local repo_id
  local worktree
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  common_dir=$(cd "$repo/.git" && pwd -P)
  repo_id=$(printf '%s' "$common_dir" | git hash-object --stdin | cut -c1-16)
  worktree="$data_home/worktrees/$repo_id/feature-one"
  prepare_fake_runtime "$TEST_TMP"

  DOCKER_CODEX_DATA_HOME=$data_home \
    run_launcher "$repo" "$ROOT" --isolated feature-one -- status

  git -C "$repo" show-ref --verify --quiet refs/heads/codex/feature-one ||
    fail "isolated branch was not created"
  [[ -f "$worktree/seed.txt" ]] ||
    fail "isolated worktree was not created at $worktree"
  assert_line "<type=bind,source=$worktree,target=$worktree>" "$TEST_DOCKER_LOG"
  assert_line "<$worktree>" "$TEST_DOCKER_LOG"

  if DOCKER_CODEX_DATA_HOME=$data_home \
    run_launcher "$repo" "$ROOT" --isolated feature-one -- status \
    >"$errors" 2>&1; then
    fail "duplicate isolated worktree unexpectedly succeeded"
  fi
  assert_contains "already exists" "$errors"
  [[ -f "$worktree/seed.txt" ]] ||
    fail "duplicate launch removed the existing worktree"
}

test_isolated_mode_rejects_unsafe_names() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local errors="$TEST_TMP/errors"
  local name
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  for name in "../escape" "/absolute" "name with spaces" "codex/already-prefixed"; do
    if run_launcher "$repo" "$ROOT" --isolated "$name" -- status >"$errors" 2>&1; then
      fail "unsafe isolated name unexpectedly succeeded: $name"
    fi
    assert_contains "invalid isolated worktree name" "$errors"
  done
}

test_isolated_mode_rejects_detached_head() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  git -C "$repo" checkout --detach -q
  prepare_fake_runtime "$TEST_TMP"

  if run_launcher "$repo" "$ROOT" --isolated detached-test -- status >"$errors" 2>&1; then
    fail "isolated worktree from detached HEAD unexpectedly succeeded"
  fi
  assert_contains "requires the current checkout to be on a branch" "$errors"
}

test_help_documents_public_interface_and_retained_worktrees() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local output="$TEST_TMP/help"

  "$ROOT/docker-codex" --help >"$output"

  assert_contains "--build" "$output"
  assert_contains "--image IMAGE" "$output"
  assert_contains "--isolated NAME" "$output"
  assert_contains "--bind PATH[:ro]" "$output"
  assert_contains "--help" "$output"
  assert_contains "docker-codex:local" "$output"
  assert_contains "retained" "$output"
}

init_tests
test_normal_checkout_preserves_paths_and_codex_arguments
test_linked_worktree_mounts_external_git_metadata_and_readonly_bind
test_submodule_mounts_external_git_metadata
test_darwin_does_not_add_linux_host_gateway
test_bad_bind_paths_fail_before_docker_run
test_isolated_mode_creates_and_preserves_worktree
test_isolated_mode_rejects_unsafe_names
test_isolated_mode_rejects_detached_head
test_help_documents_public_interface_and_retained_worktrees
printf 'launcher tests: PASS\n'
