#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/testlib.bash
source "$ROOT/tests/testlib.bash"

DOCKER_BIN=${DOCKER_AGENT_DOCKER_BIN:-${DOCKER_CODEX_DOCKER_BIN:-docker}}
IMAGE=${DOCKER_AGENT_TEST_IMAGE:-${DOCKER_CODEX_TEST_IMAGE:-docker-agent:local}}

test_debian_and_official_node_runtime() {
  "$DOCKER_BIN" image inspect "$IMAGE" >/dev/null
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm --entrypoint bash "$IMAGE" -lc '
    set -euo pipefail
    source /etc/os-release
    [[ $ID == debian ]]
    [[ $VERSION_ID == 13 ]]
    [[ $(node --version) == v24.18.0 ]]
    if dpkg-query --show nodejs npm >/dev/null 2>&1; then
      printf "%s\n" "nodejs/npm unexpectedly installed through dpkg" >&2
      exit 1
    fi
  '
}

test_runtime_user_has_passwordless_sudo_without_root_group() {
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    "$IMAGE" \
    bash -lc '
      set -euo pipefail
      [[ $(id -u) == 12345 ]]
      [[ $(id -g) == 23456 ]]
      ! id -G | tr " " "\n" | grep -qx 0
      sudo -n true
    '
}

test_login_shell_keeps_toolchain_on_path() {
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    "$IMAGE" \
    bash -lc '
      set -euo pipefail
      [[ :$PATH: == *:/usr/local/cargo/bin:* ]]
      [[ :$PATH: == *:/codex-cache/pnpm:* ]]
      command -v cargo rustc rustfmt cargo-clippy pnpm >/dev/null
    '
}

test_python_and_archive_tools_are_available() {
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm --entrypoint bash "$IMAGE" -c '
    set -euo pipefail
    command -v python3 python pip3 unzip zip >/dev/null
    python3 -m venv --help >/dev/null
    [[ -r /usr/local/share/docker-agent/agent-notes.md ]]
  '
}

test_claude_code_and_locale_are_installed() {
  "$DOCKER_BIN" run --rm --entrypoint bash "$IMAGE" -lc '
    set -euo pipefail
    claude --version | grep -F "2.1.212" >/dev/null
    locale -a | grep -Fxi "en_US.utf8" >/dev/null
    LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 locale charmap |
      grep -Fx "UTF-8" >/dev/null
    TZ=Etc/UTC date "+%Z %z" | grep -Fx "UTC +0000" >/dev/null
  '
}

test_claude_runtime_is_non_root_utc_and_en_us() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local probe_dir="$TEST_TMP/probe"
  install -d -m 755 "$probe_dir"
  install -m 755 /dev/null "$probe_dir/claude"
  # shellcheck disable=SC2016 # Variables expand when the generated probe runs.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[[ $(id -u) == 12345 ]]' \
    '[[ $(id -g) == 23456 ]]' \
    '[[ $TZ == Etc/UTC ]]' \
    '[[ $LANG == en_US.UTF-8 ]]' \
    '[[ $LC_ALL == en_US.UTF-8 ]]' \
    '[[ $LANGUAGE == en_US:en ]]' \
    '[[ $DISABLE_AUTOUPDATER == 1 ]]' \
    '[[ $DISABLE_TELEMETRY == 1 ]]' \
    '[[ $DISABLE_ERROR_REPORTING == 1 ]]' \
    '[[ $DISABLE_FEEDBACK_COMMAND == 1 ]]' \
    '[[ $CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY == 1 ]]' \
    '[[ $(locale charmap) == UTF-8 ]]' \
    '[[ $(date "+%Z %z") == "UTC +0000" ]]' \
    '[[ ${1:-} == --dangerously-skip-permissions ]]' \
    '[[ ${2:-} == --append-system-prompt-file ]]' \
    '[[ ${3:-} == /usr/local/share/docker-agent/agent-notes.md ]]' \
    >"$probe_dir/claude"

  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    --env DOCKER_AGENT_CLAUDE_CONNECTION=official-subscription \
    --env CLAUDE_CONFIG_DIR=/tmp/claude-state \
    --env PATH=/probe:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    --mount "type=bind,source=$probe_dir,target=/probe,readonly" \
    "$IMAGE" claude
}

test_mold_is_default_linker_and_sccache_is_available() {
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    "$IMAGE" \
    bash -lc '
      set -euo pipefail
      command -v mold sccache >/dev/null
      [[ $RUSTFLAGS == *fuse-ld=mold* ]]
      work=$(mktemp -d)
      cd "$work"
      cargo init -q --vcs none --name mold-smoke
      cargo run -q
    '
}

test_powershell_shim_reads_wayland_clipboard_image() {
  # shellcheck disable=SC2016,SC2026 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    --env WSL_DISTRO_NAME=Ubuntu \
    "$IMAGE" \
    bash -lc '
      set -euo pipefail
      export WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/tmp
      work=$(mktemp -d)
      cd "$work"
      python3 -c "from PIL import Image; Image.new(\"RGB\", (2, 2), (255, 0, 0)).save(\"clip.bmp\", \"BMP\")"
      printf "#!/usr/bin/env bash\ncase \"\${1:-}\" in --list-types) printf \"image/bmp\\\\n\";; --type|-t) cat \"$work/clip.bmp\";; *) exit 1;; esac\n" > wl-paste
      chmod +x wl-paste
      # Use the exact PowerShell script Codex 0.145.0 sends, so the test
      # breaks if Codex changes the contract the shim emulates.
      PATH="$work:$PATH" out=$(powershell.exe -NoProfile -Command "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; \$img = Get-Clipboard -Format Image; if (\$img -ne \$null) { \$p=[System.IO.Path]::GetTempFileName(); \$p = [System.IO.Path]::ChangeExtension(\$p,'png'); \$img.Save(\$p,[System.Drawing.Imaging.ImageFormat]::Png); Write-Output \$p } else { exit 1 }")
      # Codex maps C:\x\y to /mnt/c/x/y before reading the file.
      [[ $out == C:*.png ]]
      name=${out##*\\}
      mapped=/mnt/c/codex-clipboard/$name
      [[ -f $mapped ]]
      python3 -c "import sys; from PIL import Image; assert Image.open(sys.argv[1]).format == \"PNG\"" "$mapped"
      if PATH="$work:$PATH" powershell.exe -NoProfile -Command "Get-ChildItem" 2>/dev/null; then
        printf "%s\n" "shim unexpectedly handled a non-clipboard call" >&2
        exit 1
      fi
    '
}

init_tests
test_debian_and_official_node_runtime
test_runtime_user_has_passwordless_sudo_without_root_group
test_login_shell_keeps_toolchain_on_path
test_claude_code_and_locale_are_installed
test_claude_runtime_is_non_root_utc_and_en_us
test_python_and_archive_tools_are_available
test_mold_is_default_linker_and_sccache_is_available
test_powershell_shim_reads_wayland_clipboard_image
printf 'image tests: PASS\n'
