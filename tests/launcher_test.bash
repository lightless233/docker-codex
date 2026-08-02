#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/testlib.bash
source "$ROOT/tests/testlib.bash"

mount_source_for_target() {
  local log=$1 target=$2 line
  line=$(grep -F "target=$target>" "$log" | head -n 1)
  line=${line#*source=}
  printf '%s\n' "${line%%,target=*}"
}

test_canonical_and_compatibility_entrypoints_dispatch_agents() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  run_named_launcher "$repo" "$ROOT" docker-agent codex -- --version
  assert_ordered_lines "$TEST_DOCKER_LOG" \
    "<codex>" "<--yolo>" "<--disable>" "<apps>" "<--version>"

  : >"$TEST_DOCKER_LOG"
  run_named_launcher "$repo" "$ROOT" docker-codex -- --version
  assert_ordered_lines "$TEST_DOCKER_LOG" \
    "<codex>" "<--yolo>" "<--disable>" "<apps>" "<--version>"

  : >"$TEST_DOCKER_LOG"
  run_named_launcher "$repo" "$ROOT" docker-agent \
    claude --official-subscription -- --version
  assert_ordered_lines "$TEST_DOCKER_LOG" \
    "<claude>" "<--version>"

  : >"$TEST_DOCKER_LOG"
  run_named_launcher "$repo" "$ROOT" docker-claude \
    --official-subscription -- --version
  assert_ordered_lines "$TEST_DOCKER_LOG" \
    "<claude>" "<--version>"
}

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

test_non_git_directory_launches_codex_and_claude() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local workspace="$TEST_TMP/plain workspace"
  mkdir -p "$workspace"
  printf 'plain\n' >"$workspace/notes.txt"
  prepare_fake_runtime "$TEST_TMP"

  run_named_launcher "$workspace" "$ROOT" docker-codex -- status

  assert_line "<type=bind,source=$workspace,target=$workspace>" \
    "$TEST_DOCKER_LOG"
  assert_line "<$workspace>" "$TEST_DOCKER_LOG"
  assert_line "<codex>" "$TEST_DOCKER_LOG"
  assert_line "<status>" "$TEST_DOCKER_LOG"
  assert_not_contains "source=$workspace/.git" "$TEST_DOCKER_LOG"

  : >"$TEST_DOCKER_LOG"
  run_named_launcher "$workspace" "$ROOT" docker-claude \
    --official-subscription -- --version

  assert_line "<type=bind,source=$workspace,target=$workspace>" \
    "$TEST_DOCKER_LOG"
  assert_line "<$workspace>" "$TEST_DOCKER_LOG"
  assert_line "<claude>" "$TEST_DOCKER_LOG"
  assert_line "<--version>" "$TEST_DOCKER_LOG"
  assert_not_contains "source=$workspace/.git" "$TEST_DOCKER_LOG"
}

test_git_init_preserves_non_git_cache_and_claude_state_identity() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local workspace="$TEST_TMP/future repo"
  local cache_before cache_after state_before state_after
  mkdir -p "$workspace"
  printf 'seed\n' >"$workspace/seed.txt"
  prepare_fake_runtime "$TEST_TMP"

  run_named_launcher "$workspace" "$ROOT" docker-codex -- status
  cache_before=$(mount_source_for_target "$TEST_DOCKER_LOG" /codex-cache)

  : >"$TEST_DOCKER_LOG"
  run_named_launcher "$workspace" "$ROOT" docker-claude \
    --official-subscription -- --version
  state_before=$(mount_source_for_target "$TEST_DOCKER_LOG" /claude-state)

  git init -q "$workspace"
  git -C "$workspace" config user.name Test
  git -C "$workspace" config user.email test@example.invalid
  git -C "$workspace" add seed.txt
  git -C "$workspace" commit -qm seed

  : >"$TEST_DOCKER_LOG"
  run_named_launcher "$workspace" "$ROOT" docker-codex -- status
  cache_after=$(mount_source_for_target "$TEST_DOCKER_LOG" /codex-cache)

  : >"$TEST_DOCKER_LOG"
  run_named_launcher "$workspace" "$ROOT" docker-claude \
    --official-subscription -- --version
  state_after=$(mount_source_for_target "$TEST_DOCKER_LOG" /claude-state)

  [[ $cache_before == "$cache_after" ]] ||
    fail "git init changed cache identity: $cache_before -> $cache_after"
  [[ $state_before == "$state_after" ]] ||
    fail "git init changed Claude state identity: $state_before -> $state_after"
}

test_same_named_non_git_directories_are_isolated() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local workspace_a="$TEST_TMP/a/test"
  local workspace_b="$TEST_TMP/b/test"
  local cache_a cache_b state_a state_b
  mkdir -p "$workspace_a" "$workspace_b"
  prepare_fake_runtime "$TEST_TMP"

  run_named_launcher "$workspace_a" "$ROOT" docker-claude \
    --official-subscription -- --version
  cache_a=$(mount_source_for_target "$TEST_DOCKER_LOG" /codex-cache)
  state_a=$(mount_source_for_target "$TEST_DOCKER_LOG" /claude-state)

  : >"$TEST_DOCKER_LOG"
  run_named_launcher "$workspace_b" "$ROOT" docker-claude \
    --official-subscription -- --version
  cache_b=$(mount_source_for_target "$TEST_DOCKER_LOG" /codex-cache)
  state_b=$(mount_source_for_target "$TEST_DOCKER_LOG" /claude-state)

  [[ $cache_a != "$cache_b" ]] ||
    fail "same-named non-Git directories shared a cache"
  [[ $state_a != "$state_b" ]] ||
    fail "same-named non-Git directories shared Claude state"
}

test_non_git_directory_rejects_isolated_worktree_mode() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local workspace="$TEST_TMP/plain"
  local errors="$TEST_TMP/errors"
  mkdir -p "$workspace"
  prepare_fake_runtime "$TEST_TMP"

  if run_named_launcher "$workspace" "$ROOT" docker-codex \
    --isolated feature -- status >"$errors" 2>&1; then
    fail "non-Git directory unexpectedly accepted --isolated"
  fi

  assert_contains "--isolated requires a Git checkout" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
}

test_installed_launcher_runs_without_source_checkout() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local installed="$TEST_TMP/bin/docker-codex"
  make_repo "$repo"
  mkdir -p "$(dirname "$installed")"
  install -m 0755 "$ROOT/docker-codex" "$installed"
  prepare_fake_runtime "$TEST_TMP"

  (
    cd "$repo"
    CODEX_HOME="$TEST_CODEX_HOME" \
      DOCKER_CODEX_DOCKER_BIN="$TEST_DOCKER" \
      DOCKER_CODEX_TEST_DOCKER_LOG="$TEST_DOCKER_LOG" \
      "$installed" -- status
  )

  [[ ! -e "$(dirname "$installed")/Dockerfile" ]] ||
    fail "installed launcher unexpectedly has source files beside it"
  assert_line "<codex>" "$TEST_DOCKER_LOG"
  assert_line "<status>" "$TEST_DOCKER_LOG"
}

test_installed_launcher_rejects_build_without_source_checkout() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local installed="$TEST_TMP/bin/docker-codex"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  mkdir -p "$(dirname "$installed")"
  install -m 0755 "$ROOT/docker-codex" "$installed"
  prepare_fake_runtime "$TEST_TMP"

  if (
    cd "$repo"
    CODEX_HOME="$TEST_CODEX_HOME" \
      DOCKER_CODEX_DOCKER_BIN="$TEST_DOCKER" \
      DOCKER_CODEX_TEST_DOCKER_LOG="$TEST_DOCKER_LOG" \
      "$installed" --build -- --version
  ) >"$errors" 2>&1; then
    fail "installed launcher unexpectedly built without source files"
  fi

  assert_contains "--build requires the docker-agent source checkout" "$errors"
  assert_no_line "<build>" "$TEST_DOCKER_LOG"
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

test_neutral_host_os_override_does_not_add_linux_host_gateway() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  DOCKER_AGENT_HOST_OS=Darwin \
    run_launcher "$repo" "$ROOT" -- status

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

test_repeatable_env_options_forward_values_and_host_variables() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  DOCKER_AGENT_TEST_INHERITED_ENV='from host' \
    run_launcher "$repo" "$ROOT" \
      --env 'DIRECT_VALUE=one=two' \
      --env DOCKER_AGENT_TEST_INHERITED_ENV \
      -- status

  assert_line "<DIRECT_VALUE=one=two>" "$TEST_DOCKER_LOG"
  assert_line "<DOCKER_AGENT_TEST_INHERITED_ENV>" "$TEST_DOCKER_LOG"
  assert_line \
    "<DOCKER_AGENT_ENV_OVERRIDE_KEYS=DIRECT_VALUE,DOCKER_AGENT_TEST_INHERITED_ENV>" \
    "$TEST_DOCKER_LOG"
}

test_env_option_rejects_invalid_or_unset_variables_before_docker() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  if run_launcher "$repo" "$ROOT" --env 'BAD-NAME=value' -- status \
    >"$errors" 2>&1; then
    fail "invalid environment variable name unexpectedly succeeded"
  fi
  assert_contains "invalid environment variable name" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"

  : >"$TEST_DOCKER_LOG"
  if run_launcher "$repo" "$ROOT" \
    --env DOCKER_AGENT_TEST_ENV_THAT_IS_NOT_SET -- status \
    >"$errors" 2>&1; then
    fail "unset inherited environment variable unexpectedly succeeded"
  fi
  assert_contains "host environment variable is not set" "$errors"
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

test_pat_path_mounts_file_and_injects_git_credential_config() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local pat_file="$TEST_TMP/pat dir/github-arbor"
  make_repo "$repo"
  git -C "$repo" remote add origin git@github.com:CashFlowStudio/arbor.git
  mkdir -p "$(dirname "$pat_file")"
  printf 'token-123\n' >"$pat_file"
  prepare_fake_runtime "$TEST_TMP"

  run_launcher "$repo" "$ROOT" --pat-path "$pat_file" -- status

  assert_line "<type=bind,source=$pat_file,target=/codex-credentials/pat,readonly>" "$TEST_DOCKER_LOG"
  assert_line "<GIT_CONFIG_COUNT=3>" "$TEST_DOCKER_LOG"
  assert_line "<GIT_CONFIG_KEY_0=credential.https://github.com.helper>" "$TEST_DOCKER_LOG"
  assert_contains "password=\$(cat /codex-credentials/pat)" "$TEST_DOCKER_LOG"
  assert_line "<GIT_CONFIG_KEY_1=url.https://github.com/.insteadOf>" "$TEST_DOCKER_LOG"
  assert_line "<GIT_CONFIG_VALUE_1=git@github.com:>" "$TEST_DOCKER_LOG"
  assert_line "<GIT_CONFIG_KEY_2=url.https://github.com/.insteadOf>" "$TEST_DOCKER_LOG"
  assert_line "<GIT_CONFIG_VALUE_2=ssh://git@github.com/>" "$TEST_DOCKER_LOG"
  assert_no_line "<token-123>" "$TEST_DOCKER_LOG"
}

test_pat_value_is_stored_under_data_home_and_never_passed_as_argument() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local data_home="$TEST_TMP/data home"
  local common_dir repo_id stored perms
  make_repo "$repo"
  common_dir=$(cd "$repo/.git" && pwd -P)
  repo_id=$(printf '%s' "$common_dir" | git hash-object --stdin | cut -c1-16)
  prepare_fake_runtime "$TEST_TMP"

  DOCKER_CODEX_DATA_HOME=$data_home \
    run_launcher "$repo" "$ROOT" --pat token-xyz -- status

  stored="$data_home/pat/$repo_id"
  [[ -f $stored ]] || fail "--pat token was not stored at $stored"
  [[ $(cat "$stored") == token-xyz ]] ||
    fail "stored --pat token has unexpected content: $(cat "$stored")"
  perms=$(stat -c %a "$stored")
  [[ $perms == 600 ]] ||
    fail "stored --pat token has mode $perms instead of 600"
  assert_line "<type=bind,source=$stored,target=/codex-credentials/pat,readonly>" "$TEST_DOCKER_LOG"
  assert_no_line "<token-xyz>" "$TEST_DOCKER_LOG"
  assert_no_line "<--pat>" "$TEST_DOCKER_LOG"
  assert_line "<GIT_CONFIG_COUNT=1>" "$TEST_DOCKER_LOG"
  assert_line "<GIT_CONFIG_KEY_0=credential.helper>" "$TEST_DOCKER_LOG"
}

test_neutral_data_home_and_pat_path_overrides_are_used() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local data_home="$TEST_TMP/agent data"
  local pat_file="$TEST_TMP/pat/token"
  local common_dir repo_id stored
  make_repo "$repo"
  mkdir -p "$(dirname "$pat_file")"
  printf 'token-from-file\n' >"$pat_file"
  common_dir=$(cd "$repo/.git" && pwd -P)
  repo_id=$(printf '%s' "$common_dir" | git hash-object --stdin | cut -c1-16)
  stored="$data_home/pat/$repo_id"
  prepare_fake_runtime "$TEST_TMP"

  DOCKER_AGENT_DATA_HOME=$data_home \
    run_launcher "$repo" "$ROOT" --pat token-neutral -- status

  [[ -f $stored ]] ||
    fail "neutral data home did not contain stored PAT: $stored"
  assert_line "<type=bind,source=$stored,target=/codex-credentials/pat,readonly>" \
    "$TEST_DOCKER_LOG"

  : >"$TEST_DOCKER_LOG"
  DOCKER_AGENT_PAT_PATH=$pat_file \
    run_launcher "$repo" "$ROOT" -- status

  assert_line "<type=bind,source=$pat_file,target=/codex-credentials/pat,readonly>" \
    "$TEST_DOCKER_LOG"
}

test_pat_options_reject_invalid_input() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local pat_file="$TEST_TMP/pat/token"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  mkdir -p "$(dirname "$pat_file")"
  printf 'token-123\n' >"$pat_file"
  prepare_fake_runtime "$TEST_TMP"

  if run_launcher "$repo" "$ROOT" --pat-path "$TEST_TMP/missing" -- >"$errors" 2>&1; then
    fail "missing PAT file unexpectedly succeeded"
  fi
  assert_contains "PAT file does not exist" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"

  : >"$TEST_DOCKER_LOG"
  if run_launcher "$repo" "$ROOT" --pat-path "$(dirname "$pat_file")" -- >"$errors" 2>&1; then
    fail "directory PAT path unexpectedly succeeded"
  fi
  assert_contains "PAT path must be a regular file" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"

  : >"$TEST_DOCKER_LOG"
  if run_launcher "$repo" "$ROOT" --pat token-xyz --pat-path "$pat_file" -- >"$errors" 2>&1; then
    fail "combined --pat and --pat-path unexpectedly succeeded"
  fi
  assert_contains "mutually exclusive" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
}

test_display_sockets_are_forwarded_when_present() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local wayland_dir="$TEST_TMP/wayland runtime"
  make_repo "$repo"
  mkdir -p "$wayland_dir"
  : >"$wayland_dir/wayland-0"
  prepare_fake_runtime "$TEST_TMP"

  DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 WSL_DISTRO_NAME=Ubuntu \
  DOCKER_AGENT_WAYLAND_DIR=$wayland_dir \
    run_launcher "$repo" "$ROOT" -- status

  assert_line "<type=bind,source=$wayland_dir/wayland-0,target=/run/docker-codex/wayland-0,readonly>" "$TEST_DOCKER_LOG"
  assert_line "<WAYLAND_DISPLAY=wayland-0>" "$TEST_DOCKER_LOG"
  assert_line "<XDG_RUNTIME_DIR=/run/docker-codex>" "$TEST_DOCKER_LOG"
  assert_line "<WSL_DISTRO_NAME=Ubuntu>" "$TEST_DOCKER_LOG"
  # WSLg does not need X11: the shim reads images through wl-paste.
  assert_no_line "<DISPLAY=:0>" "$TEST_DOCKER_LOG"
}

test_native_linux_x11_socket_is_forwarded_readonly() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local x11_dir="$TEST_TMP/x11"
  make_repo "$repo"
  mkdir -p "$x11_dir"
  : >"$x11_dir/X0"
  prepare_fake_runtime "$TEST_TMP"

  DISPLAY=:0 WAYLAND_DISPLAY='' WSL_DISTRO_NAME='' \
  DOCKER_AGENT_X11_DIR=$x11_dir \
    run_launcher "$repo" "$ROOT" -- status

  assert_line "<type=bind,source=$x11_dir/X0,target=$x11_dir/X0,readonly>" "$TEST_DOCKER_LOG"
  assert_line "<DISPLAY=:0>" "$TEST_DOCKER_LOG"
}

test_display_sockets_are_not_forwarded_when_absent() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 WSL_DISTRO_NAME='' \
  DOCKER_CODEX_X11_DIR="$TEST_TMP/missing-x11" \
  DOCKER_CODEX_WAYLAND_DIR="$TEST_TMP/missing-wayland" \
    run_launcher "$repo" "$ROOT" -- status

  assert_no_line "<DISPLAY=:0>" "$TEST_DOCKER_LOG"
  assert_no_line "<WAYLAND_DISPLAY=wayland-0>" "$TEST_DOCKER_LOG"
  assert_no_line "<WSL_DISTRO_NAME=>" "$TEST_DOCKER_LOG"
}

test_disable_clipboard_skips_all_display_forwarding() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local x11_dir="$TEST_TMP/x11"
  local wayland_dir="$TEST_TMP/wayland runtime"
  make_repo "$repo"
  mkdir -p "$x11_dir" "$wayland_dir"
  : >"$x11_dir/X0"
  : >"$wayland_dir/wayland-0"
  prepare_fake_runtime "$TEST_TMP"

  DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 WSL_DISTRO_NAME=Ubuntu \
  DOCKER_CODEX_X11_DIR=$x11_dir DOCKER_CODEX_WAYLAND_DIR=$wayland_dir \
    run_launcher "$repo" "$ROOT" --disable-clipboard -- status

  assert_no_line "<DISPLAY=:0>" "$TEST_DOCKER_LOG"
  assert_no_line "<WAYLAND_DISPLAY=wayland-0>" "$TEST_DOCKER_LOG"
  assert_no_line "<WSL_DISTRO_NAME=Ubuntu>" "$TEST_DOCKER_LOG"
  assert_no_line "<XDG_RUNTIME_DIR=/run/docker-codex>" "$TEST_DOCKER_LOG"
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
  assert_contains "--env NAME[=VALUE]" "$output"
  assert_contains "--pat TOKEN" "$output"
  assert_contains "--pat-path FILE" "$output"
  assert_contains "--disable-clipboard" "$output"
  assert_contains "--help" "$output"
  assert_contains "docker-agent:local" "$output"
  assert_contains "retained" "$output"
}

test_help_documents_agent_and_claude_interfaces() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local agent_help="$TEST_TMP/agent-help"
  local claude_help="$TEST_TMP/claude-help"

  "$ROOT/docker-agent" --help >"$agent_help"
  "$ROOT/docker-agent" claude --help >"$claude_help"

  assert_contains "docker-agent codex" "$agent_help"
  assert_contains "docker-agent claude" "$agent_help"
  assert_contains "--official-subscription" "$claude_help"
  assert_contains "--official-api" "$claude_help"
  assert_contains "--profile NAME" "$claude_help"
  assert_contains "docker-agent:local" "$claude_help"
  assert_contains "interactive terminal" "$claude_help"
}

init_tests
test_canonical_and_compatibility_entrypoints_dispatch_agents
test_normal_checkout_preserves_paths_and_codex_arguments
test_non_git_directory_launches_codex_and_claude
test_git_init_preserves_non_git_cache_and_claude_state_identity
test_same_named_non_git_directories_are_isolated
test_non_git_directory_rejects_isolated_worktree_mode
test_installed_launcher_runs_without_source_checkout
test_installed_launcher_rejects_build_without_source_checkout
test_linked_worktree_mounts_external_git_metadata_and_readonly_bind
test_submodule_mounts_external_git_metadata
test_darwin_does_not_add_linux_host_gateway
test_neutral_host_os_override_does_not_add_linux_host_gateway
test_bad_bind_paths_fail_before_docker_run
test_repeatable_env_options_forward_values_and_host_variables
test_env_option_rejects_invalid_or_unset_variables_before_docker
test_isolated_mode_creates_and_preserves_worktree
test_isolated_mode_rejects_unsafe_names
test_isolated_mode_rejects_detached_head
test_pat_path_mounts_file_and_injects_git_credential_config
test_pat_value_is_stored_under_data_home_and_never_passed_as_argument
test_neutral_data_home_and_pat_path_overrides_are_used
test_pat_options_reject_invalid_input
test_display_sockets_are_forwarded_when_present
test_native_linux_x11_socket_is_forwarded_readonly
test_display_sockets_are_not_forwarded_when_absent
test_disable_clipboard_skips_all_display_forwarding
test_help_documents_public_interface_and_retained_worktrees
test_help_documents_agent_and_claude_interfaces
printf 'launcher tests: PASS\n'
