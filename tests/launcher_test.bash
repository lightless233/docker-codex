#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/testlib.bash
source "$ROOT/tests/testlib.bash"

run_launcher_without_term() {
  local directory=$1
  shift
  (
    unset TERM COLORTERM
    export DOCKER_AGENT_TEST_FORCE_TTY=1
    run_launcher "$directory" "$ROOT" "$@"
  )
}

mount_source_for_target() {
  local log=$1 target=$2 line
  line=$(grep -F "target=$target>" "$log" | head -n 1)
  line=${line#*source=}
  printf '%s\n' "${line%%,target=*}"
}

make_unix_socket_file() {
  python3 - "$1" <<'PY'
import socket
import sys

sock = socket.socket(socket.AF_UNIX)
sock.bind(sys.argv[1])
sock.close()
PY
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

test_terminal_capability_is_forwarded_only_with_a_tty() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  # Docker only sets TERM=xterm on its own, which costs the agent TUIs their
  # color depth, so the host values have to be forwarded explicitly.
  DOCKER_AGENT_TEST_FORCE_TTY=1 TERM=xterm-256color COLORTERM=truecolor \
    run_launcher "$repo" "$ROOT" -- --version
  assert_line "<-it>" "$TEST_DOCKER_LOG"
  assert_line "<TERM=xterm-256color>" "$TEST_DOCKER_LOG"
  assert_line "<COLORTERM=truecolor>" "$TEST_DOCKER_LOG"

  # An explicit --env has to win over the forwarded value.
  : >"$TEST_DOCKER_LOG"
  DOCKER_AGENT_TEST_FORCE_TTY=1 TERM=xterm-256color \
    run_launcher "$repo" "$ROOT" --env TERM=dumb -- --version
  assert_ordered_lines "$TEST_DOCKER_LOG" "<TERM=xterm-256color>" "<TERM=dumb>"

  # Without a terminal there is nothing to describe and no -it.
  : >"$TEST_DOCKER_LOG"
  TERM=xterm-256color COLORTERM=truecolor \
    run_launcher "$repo" "$ROOT" -- --version
  assert_no_line "<-it>" "$TEST_DOCKER_LOG"
  assert_no_line "<TERM=xterm-256color>" "$TEST_DOCKER_LOG"
  assert_no_line "<COLORTERM=truecolor>" "$TEST_DOCKER_LOG"

  # An unset TERM must not produce an empty assignment.
  : >"$TEST_DOCKER_LOG"
  run_launcher_without_term "$repo" -- --version
  assert_line "<-it>" "$TEST_DOCKER_LOG"
  assert_no_line "<TERM=>" "$TEST_DOCKER_LOG"
  assert_no_line "<COLORTERM=>" "$TEST_DOCKER_LOG"
}

test_normal_checkout_preserves_paths_and_codex_arguments() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo with spaces"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  run_launcher "$repo" "$ROOT" -- review "prompt with spaces"

  assert_line "<type=bind,source=$repo,target=$repo>" "$TEST_DOCKER_LOG"
  assert_line "<CODEX_HOME=$TEST_CODEX_HOME>" "$TEST_DOCKER_LOG"
  assert_line "<type=bind,source=$TEST_CODEX_HOME,target=$TEST_CODEX_HOME>" "$TEST_DOCKER_LOG"
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

test_codex_home_symlink_preserves_logical_target_and_uses_physical_source() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local physical_home="$TEST_TMP/physical codex home"
  local logical_home="$TEST_TMP/logical codex home"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  mkdir -p "$physical_home"
  ln -s "$physical_home" "$logical_home"

  TEST_CODEX_HOME_OVERRIDE=$logical_home \
    run_launcher "$repo" "$ROOT" -- status

  assert_line "<CODEX_HOME=$logical_home>" "$TEST_DOCKER_LOG"
  assert_line "<type=bind,source=$physical_home,target=$logical_home>" \
    "$TEST_DOCKER_LOG"
  assert_line "<type=bind,source=$physical_home,target=/codex-home>" \
    "$TEST_DOCKER_LOG"
  assert_no_line "<CODEX_HOME=$physical_home>" "$TEST_DOCKER_LOG"
}

test_codex_home_must_be_an_absolute_directory() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  if TEST_CODEX_HOME_OVERRIDE="relative-codex-home" \
      run_launcher "$repo" "$ROOT" -- status >"$errors" 2>&1; then
    fail "relative CODEX_HOME unexpectedly launched Codex"
  fi

  assert_contains "Codex home must be an absolute path" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
}

test_codex_home_must_not_resolve_to_the_host_root() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local root_link="$TEST_TMP/root-link"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  ln -s / "$root_link"

  if TEST_CODEX_HOME_OVERRIDE=$root_link \
      run_launcher "$repo" "$ROOT" -- status >"$errors" 2>&1; then
    fail "root-resolving CODEX_HOME unexpectedly launched Codex"
  fi

  assert_contains "must not resolve to the host filesystem root" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
}

test_checkout_used_as_codex_home_does_not_duplicate_the_mount_target() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  TEST_CODEX_HOME_OVERRIDE=$repo \
    run_launcher "$repo" "$ROOT" -- status

  assert_line "<CODEX_HOME=$repo>" "$TEST_DOCKER_LOG"
  [[ $(grep -Fxc "<type=bind,source=$repo,target=$repo>" "$TEST_DOCKER_LOG") == 1 ]] ||
    fail "checkout/CODEX_HOME target was mounted more than once"
  assert_line "<type=bind,source=$repo,target=/codex-home>" "$TEST_DOCKER_LOG"
}

test_repair_sessions_uses_dedicated_noninteractive_runtime() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  DOCKER_AGENT_TEST_FORCE_TTY=1 \
    run_named_launcher "$repo" "$ROOT" docker-codex --repair-sessions

  assert_line "<CODEX_HOME=$TEST_CODEX_HOME>" "$TEST_DOCKER_LOG"
  assert_line "<type=bind,source=$TEST_CODEX_HOME,target=$TEST_CODEX_HOME>" \
    "$TEST_DOCKER_LOG"
  assert_line "<type=bind,source=$TEST_CODEX_HOME,target=/codex-home>" \
    "$TEST_DOCKER_LOG"
  assert_line "<container-codex-session-repair>" "$TEST_DOCKER_LOG"
  assert_no_line "<-it>" "$TEST_DOCKER_LOG"
  assert_no_line "<codex>" "$TEST_DOCKER_LOG"
  assert_no_line "<type=bind,source=$repo,target=$repo>" "$TEST_DOCKER_LOG"
  assert_not_contains "target=/codex-cache" "$TEST_DOCKER_LOG"
  assert_no_line "<--workdir>" "$TEST_DOCKER_LOG"
  assert_ordered_lines "$TEST_DOCKER_LOG" "<--network>" "<none>"
  assert_no_line "<docker-agent>" "$TEST_DOCKER_LOG"

  : >"$TEST_DOCKER_LOG"
  run_named_launcher "$repo" "$ROOT" docker-agent \
    codex --repair-sessions
  assert_line "<container-codex-session-repair>" "$TEST_DOCKER_LOG"

  : >"$TEST_DOCKER_LOG"
  DOCKER_AGENT_PAT_PATH="$TEST_TMP/default-pat-is-ignored" \
    run_launcher "$repo" "$ROOT" --repair-sessions
  assert_line "<container-codex-session-repair>" "$TEST_DOCKER_LOG"
  assert_not_contains "target=/codex-credentials/pat" "$TEST_DOCKER_LOG"
}

test_repair_sessions_is_codex_only_and_not_confused_with_agent_arguments() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  run_launcher "$repo" "$ROOT" -- --repair-sessions
  assert_ordered_lines "$TEST_DOCKER_LOG" \
    "<codex>" "<--yolo>" "<--disable>" "<apps>" "<--repair-sessions>"
  assert_no_line "<container-codex-session-repair>" "$TEST_DOCKER_LOG"

  : >"$TEST_DOCKER_LOG"
  if run_named_launcher "$repo" "$ROOT" docker-agent \
      claude --repair-sessions >"$errors" 2>&1; then
    fail "Claude unexpectedly accepted --repair-sessions"
  fi
  assert_contains "--repair-sessions is only valid for Codex" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"

  : >"$TEST_DOCKER_LOG"
  if run_launcher "$repo" "$ROOT" \
      --repair-sessions --isolated repair >"$errors" 2>&1; then
    fail "repair mode unexpectedly accepted --isolated"
  fi
  assert_contains "--repair-sessions cannot be combined" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
}

test_repair_sessions_checks_image_capability_before_mounting_state() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  if DOCKER_AGENT_TEST_REPAIR_CAPABILITY_STATUS=127 \
      run_launcher "$repo" "$ROOT" --repair-sessions \
      >"$errors" 2>&1; then
    fail "image without repair support unexpectedly mounted Codex state"
  fi

  assert_contains "image does not provide Codex session repair support" "$errors"
  assert_line "<--check-capability>" "$TEST_DOCKER_LOG"
  assert_not_contains "CODEX_HOME=" "$TEST_DOCKER_LOG"
  assert_not_contains "target=/codex-home" "$TEST_DOCKER_LOG"
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

test_source_launcher_checks_buildx_before_building() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  run_launcher "$repo" "$ROOT" --build -- --version

  assert_ordered_lines "$TEST_DOCKER_LOG" \
    '<buildx>' \
    '<version>' \
    '<build>' \
    '<--tag>' \
    '<docker-agent:local>' \
    "<$ROOT>"
}

test_source_launcher_reports_missing_buildx() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  if DOCKER_AGENT_TEST_BUILDX_STATUS=1 \
      run_launcher "$repo" "$ROOT" --build -- --version \
      >"$errors" 2>&1; then
    fail "source launcher without Buildx unexpectedly built the image"
  fi

  assert_contains "Docker Buildx is required" "$errors"
  assert_contains "brew install docker-buildx" "$errors"
  assert_line '<buildx>' "$TEST_DOCKER_LOG"
  assert_no_line '<build>' "$TEST_DOCKER_LOG"
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
  git_dir=$(git_metadata_dir "$submodule" --git-dir)
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

test_default_network_is_created_once_and_used_by_both_agents() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  run_named_launcher "$repo" "$ROOT" docker-codex -- status

  assert_contiguous_lines "$TEST_DOCKER_LOG" \
    "CALL" "<network>" "<inspect>" "<docker-agent>"
  assert_contiguous_lines "$TEST_DOCKER_LOG" \
    "CALL" "<network>" "<create>" "<--driver>" "<bridge>" \
    "<--label>" "<com.docker-agent.managed=true>" "<docker-agent>"
  assert_contiguous_lines "$TEST_DOCKER_LOG" \
    "<run>" "<--rm>" "<--network>" "<docker-agent>"

  : >"$TEST_DOCKER_LOG"
  run_named_launcher "$repo" "$ROOT" docker-claude \
    --official-subscription -- --version

  assert_contiguous_lines "$TEST_DOCKER_LOG" \
    "CALL" "<network>" "<inspect>" "<docker-agent>"
  assert_no_line "<create>" "$TEST_DOCKER_LOG"
  assert_contiguous_lines "$TEST_DOCKER_LOG" \
    "<run>" "<--rm>" "<--network>" "<docker-agent>"
}

test_repeatable_networks_are_additive_and_default_can_be_disabled() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  run_named_launcher "$repo" "$ROOT" docker-codex \
    --network docker-agent --network AAA --network AAA --network BBB -- status

  assert_contiguous_lines "$TEST_DOCKER_LOG" \
    "<run>" "<--rm>" \
    "<--network>" "<docker-agent>" \
    "<--network>" "<AAA>" \
    "<--network>" "<BBB>"
  [[ $(grep -Fxc -- "<--network>" "$TEST_DOCKER_LOG") == 3 ]] ||
    fail "duplicate Docker network arguments were not removed"

  : >"$TEST_DOCKER_LOG"
  run_named_launcher "$repo" "$ROOT" docker-claude \
    --disable-default-network --network AAA \
    --official-subscription -- --version

  assert_no_contiguous_lines "$TEST_DOCKER_LOG" \
    "CALL" "<network>" "<inspect>" "<docker-agent>"
  assert_no_line "<docker-agent>" "$TEST_DOCKER_LOG"
  assert_contiguous_lines "$TEST_DOCKER_LOG" \
    "<run>" "<--rm>" "<--network>" "<AAA>"

  : >"$TEST_DOCKER_LOG"
  run_named_launcher "$repo" "$ROOT" docker-codex \
    --disable-default-network -- status

  assert_no_line "<--network>" "$TEST_DOCKER_LOG"
  assert_no_line "<docker-agent>" "$TEST_DOCKER_LOG"
}

test_special_network_modes_require_disabling_the_default_network() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local errors="$TEST_TMP/errors"
  local special_network
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  for special_network in host none; do
    if run_named_launcher "$repo" "$ROOT" docker-codex \
      --network "$special_network" -- status >"$errors" 2>&1; then
      fail "special network unexpectedly combined with default: $special_network"
    fi
    assert_contains \
      "--network $special_network requires --disable-default-network" \
      "$errors"
    assert_no_line "<run>" "$TEST_DOCKER_LOG"
    : >"$TEST_DOCKER_LOG"
  done

  run_named_launcher "$repo" "$ROOT" docker-codex \
    --disable-default-network --network host -- status

  assert_contiguous_lines "$TEST_DOCKER_LOG" \
    "<run>" "<--rm>" "<--network>" "<host>"
}

test_host_docker_is_opt_in_warns_and_mounts_the_daemon_socket() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local socket="$TEST_TMP/docker.sock"
  local errors="$TEST_TMP/errors"
  local socket_gid
  make_repo "$repo"
  make_unix_socket_file "$socket"
  socket_gid=$(file_gid "$socket")
  prepare_fake_runtime "$TEST_TMP"

  DOCKER_AGENT_DOCKER_SOCKET=$socket \
    run_named_launcher "$repo" "$ROOT" docker-codex -- status 2>"$errors"

  assert_no_line "<type=bind,source=$socket,target=/var/run/docker.sock>" \
    "$TEST_DOCKER_LOG"
  assert_no_line "<HOST_DOCKER_GID=$socket_gid>" "$TEST_DOCKER_LOG"
  assert_not_contains "HOST DOCKER ACCESS ENABLED" "$errors"

  : >"$TEST_DOCKER_LOG"
  : >"$errors"
  DOCKER_AGENT_DOCKER_SOCKET=$socket \
    run_named_launcher "$repo" "$ROOT" docker-claude \
      --host-docker --official-subscription -- --version 2>"$errors"

  assert_line "<type=bind,source=$socket,target=/var/run/docker.sock>" \
    "$TEST_DOCKER_LOG"
  assert_line "<HOST_DOCKER_GID=$socket_gid>" "$TEST_DOCKER_LOG"
  assert_line "<DOCKER_HOST=unix:///var/run/docker.sock>" "$TEST_DOCKER_LOG"
  assert_contains "HOST DOCKER ACCESS ENABLED" "$errors"
  assert_contains "root-level control of the Docker host" "$errors"
  assert_contains "mount arbitrary host paths" "$errors"
}

test_host_docker_rejects_a_missing_or_non_socket_path_before_run() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local regular_file="$TEST_TMP/not-a-socket"
  local errors="$TEST_TMP/errors"
  make_repo "$repo"
  : >"$regular_file"
  prepare_fake_runtime "$TEST_TMP"

  if DOCKER_AGENT_DOCKER_SOCKET="$TEST_TMP/missing.sock" \
    run_named_launcher "$repo" "$ROOT" docker-codex \
      --host-docker -- status >"$errors" 2>&1; then
    fail "missing Docker socket unexpectedly accepted"
  fi
  assert_contains "Docker socket does not exist" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"

  : >"$TEST_DOCKER_LOG"
  if DOCKER_AGENT_DOCKER_SOCKET=$regular_file \
    run_named_launcher "$repo" "$ROOT" docker-codex \
      --host-docker -- status >"$errors" 2>&1; then
    fail "regular file unexpectedly accepted as Docker socket"
  fi
  assert_contains "Docker socket path is not a Unix socket" "$errors"
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
  perms=$(file_mode "$stored")
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

test_macos_clipboard_bridge_is_forwarded_and_cleaned_up() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local fake_osascript="$TEST_TMP/osascript"
  local osascript_log="$TEST_TMP/osascript.log"
  local mount_line bridge_dir
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  # shellcheck disable=SC2016 # Variables expand when the generated fake runs.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "<%s>\\n" "$@" >>"$DOCKER_AGENT_TEST_OSASCRIPT_LOG"' \
    'output_dir=${!#}' \
    ': >"$output_dir/.ready"' \
    'printf PNG >"$output_dir/latest.png"' \
    'trap "exit 0" HUP INT TERM' \
    'while :; do sleep 1; done' \
    >"$fake_osascript"
  chmod +x "$fake_osascript"
  : >"$osascript_log"

  DOCKER_AGENT_HOST_OS=Darwin \
  DOCKER_AGENT_OSASCRIPT_BIN="$fake_osascript" \
  DOCKER_AGENT_TEST_OSASCRIPT_LOG="$osascript_log" \
    run_launcher "$repo" "$ROOT" -- status

  assert_line "<-l>" "$osascript_log"
  assert_line "<JavaScript>" "$osascript_log"
  assert_line "<DOCKER_AGENT_CLIPBOARD_BACKEND=macos>" "$TEST_DOCKER_LOG"
  assert_line "<WSL_INTEROP=/run/docker-agent/macos-clipboard>" "$TEST_DOCKER_LOG"
  mount_line=$(grep -F 'target=/run/docker-agent/macos-clipboard,readonly' "$TEST_DOCKER_LOG")
  bridge_dir=${mount_line#<type=bind,source=}
  bridge_dir=${bridge_dir%%,target=*}
  [[ ! -e $bridge_dir ]] ||
    fail "macOS clipboard session directory survived launcher exit: $bridge_dir"
}

test_macos_clipboard_bridge_is_forwarded_to_claude() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local fake_osascript="$TEST_TMP/osascript"
  local osascript_log="$TEST_TMP/osascript.log"
  local profile mount_line bridge_dir
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  profile="$TEST_AGENT_CONFIG_HOME/claude/profiles/official-api.env"
  printf '%s\n' 'ANTHROPIC_API_KEY=test-secret' >"$profile"
  chmod 600 "$profile"

  # shellcheck disable=SC2016 # Variables expand when the generated fake runs.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "<%s>\\n" "$@" >>"$DOCKER_AGENT_TEST_OSASCRIPT_LOG"' \
    'output_dir=${!#}' \
    ': >"$output_dir/.ready"' \
    'printf PNG >"$output_dir/latest.png"' \
    'trap "exit 0" HUP INT TERM' \
    'while :; do sleep 1; done' \
    >"$fake_osascript"
  chmod +x "$fake_osascript"
  : >"$osascript_log"

  DOCKER_AGENT_HOST_OS=Darwin \
  DOCKER_AGENT_OSASCRIPT_BIN="$fake_osascript" \
  DOCKER_AGENT_TEST_OSASCRIPT_LOG="$osascript_log" \
    run_named_launcher "$repo" "$ROOT" docker-claude \
      --official-api -- --version

  assert_line "<-l>" "$osascript_log"
  assert_line "<JavaScript>" "$osascript_log"
  assert_line "<DOCKER_AGENT_CLIPBOARD_BACKEND=macos>" "$TEST_DOCKER_LOG"
  assert_no_line "<WSL_INTEROP=/run/docker-agent/macos-clipboard>" \
    "$TEST_DOCKER_LOG"
  mount_line=$(grep -F 'target=/run/docker-agent/macos-clipboard,readonly' \
    "$TEST_DOCKER_LOG")
  bridge_dir=${mount_line#<type=bind,source=}
  bridge_dir=${bridge_dir%%,target=*}
  [[ ! -e $bridge_dir ]] ||
    fail "macOS clipboard session directory survived Claude launcher exit: $bridge_dir"
}

test_disable_clipboard_skips_macos_bridge() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local fake_osascript="$TEST_TMP/osascript"
  local osascript_log="$TEST_TMP/osascript.log"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"

  # shellcheck disable=SC2016 # Variables expand when the generated fake runs.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf invoked >>"$DOCKER_AGENT_TEST_OSASCRIPT_LOG"' \
    >"$fake_osascript"
  chmod +x "$fake_osascript"
  : >"$osascript_log"

  DOCKER_AGENT_HOST_OS=Darwin \
  DOCKER_AGENT_OSASCRIPT_BIN="$fake_osascript" \
  DOCKER_AGENT_TEST_OSASCRIPT_LOG="$osascript_log" \
    run_launcher "$repo" "$ROOT" --disable-clipboard -- status

  [[ ! -s $osascript_log ]] || fail "disabled macOS clipboard started osascript"
  assert_no_line "<DOCKER_AGENT_CLIPBOARD_BACKEND=macos>" "$TEST_DOCKER_LOG"
  assert_no_line "<WSL_INTEROP=/run/docker-agent/macos-clipboard>" "$TEST_DOCKER_LOG"
  assert_not_contains "target=/run/docker-agent/macos-clipboard" "$TEST_DOCKER_LOG"
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
  assert_contains "--network NETWORK" "$output"
  assert_contains "--disable-default-network" "$output"
  assert_contains "--host-docker" "$output"
  assert_contains "--pat TOKEN" "$output"
  assert_contains "--pat-path FILE" "$output"
  assert_contains "--disable-clipboard" "$output"
  assert_contains "--repair-sessions" "$output"
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
test_terminal_capability_is_forwarded_only_with_a_tty
test_normal_checkout_preserves_paths_and_codex_arguments
test_codex_home_symlink_preserves_logical_target_and_uses_physical_source
test_codex_home_must_be_an_absolute_directory
test_codex_home_must_not_resolve_to_the_host_root
test_checkout_used_as_codex_home_does_not_duplicate_the_mount_target
test_repair_sessions_uses_dedicated_noninteractive_runtime
test_repair_sessions_is_codex_only_and_not_confused_with_agent_arguments
test_repair_sessions_checks_image_capability_before_mounting_state
test_non_git_directory_launches_codex_and_claude
test_git_init_preserves_non_git_cache_and_claude_state_identity
test_same_named_non_git_directories_are_isolated
test_non_git_directory_rejects_isolated_worktree_mode
test_installed_launcher_runs_without_source_checkout
test_installed_launcher_rejects_build_without_source_checkout
test_source_launcher_checks_buildx_before_building
test_source_launcher_reports_missing_buildx
test_linked_worktree_mounts_external_git_metadata_and_readonly_bind
test_submodule_mounts_external_git_metadata
test_darwin_does_not_add_linux_host_gateway
test_neutral_host_os_override_does_not_add_linux_host_gateway
test_bad_bind_paths_fail_before_docker_run
test_repeatable_env_options_forward_values_and_host_variables
test_env_option_rejects_invalid_or_unset_variables_before_docker
test_default_network_is_created_once_and_used_by_both_agents
test_repeatable_networks_are_additive_and_default_can_be_disabled
test_special_network_modes_require_disabling_the_default_network
test_host_docker_is_opt_in_warns_and_mounts_the_daemon_socket
test_host_docker_rejects_a_missing_or_non_socket_path_before_run
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
test_macos_clipboard_bridge_is_forwarded_and_cleaned_up
test_macos_clipboard_bridge_is_forwarded_to_claude
test_disable_clipboard_skips_macos_bridge
test_disable_clipboard_skips_all_display_forwarding
test_help_documents_public_interface_and_retained_worktrees
test_help_documents_agent_and_claude_interfaces
printf 'launcher tests: PASS\n'
