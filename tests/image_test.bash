#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/testlib.bash
source "$ROOT/tests/testlib.bash"

DOCKER_BIN=${DOCKER_AGENT_DOCKER_BIN:-${DOCKER_CODEX_DOCKER_BIN:-docker}}
IMAGE=${DOCKER_AGENT_TEST_IMAGE:-${DOCKER_CODEX_TEST_IMAGE:-docker-agent:local}}

# Snapshot of the PowerShell script Codex sends to powershell.exe when it reads
# a clipboard image on WSL. The shim in container-powershell-shim emulates this
# call, so the contract test below compares this snapshot against the script
# embedded in the pinned Codex build. A mismatch means the upstream contract
# moved and the shim needs review before this value is updated.
# shellcheck disable=SC2016 # PowerShell variables must stay unexpanded.
CODEX_CLIPBOARD_PS_SCRIPT='[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $img = Get-Clipboard -Format Image; if ($img -ne $null) { $p=[System.IO.Path]::GetTempFileName(); $p = [System.IO.Path]::ChangeExtension($p,'\''png'\''); $img.Save($p,[System.Drawing.Imaging.ImageFormat]::Png); Write-Output $p } else { exit 1 }'
# Matches the script above inside the stripped binary, where string constants
# are concatenated without separators.
CODEX_CLIPBOARD_PS_PATTERN='\[Console\]::OutputEncoding.*?else \{ exit 1 \}'

test_debian_and_official_node_runtime() {
  "$DOCKER_BIN" image inspect "$IMAGE" >/dev/null
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm --entrypoint bash "$IMAGE" -lc '
    set -euo pipefail
    source /etc/os-release
    [[ $ID == debian ]]
    [[ $VERSION_ID == 13 ]]
    [[ $(node --version) == v24.19.0 ]]
    if dpkg-query --show nodejs npm >/dev/null 2>&1; then
      printf "%s\n" "nodejs/npm unexpectedly installed through dpkg" >&2
      exit 1
    fi
  '
}

test_docker_client_tools_are_available_without_a_daemon() {
  "$DOCKER_BIN" run --rm --entrypoint bash "$IMAGE" -lc '
    set -euo pipefail
    docker --version | grep -F "Docker version" >/dev/null
    docker buildx version | grep -F "github.com/docker/buildx" >/dev/null
    docker compose version | grep -F "Docker Compose version" >/dev/null
    ! command -v dockerd
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

test_runtime_user_keeps_host_docker_supplementary_group() {
  # This catches credential switches that preserve UID/GID but discard the
  # supplementary group needed to open the mounted Docker socket.
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    --env HOST_DOCKER_GID=34567 \
    "$IMAGE" \
    bash -lc '
      set -euo pipefail
      [[ $(id -u) == 12345 ]]
      [[ $(id -g) == 23456 ]]
      id -G | tr " " "\n" | grep -qx 34567
    '
}

test_agent_notes_are_readable_by_runtime_user() {
  # The entrypoint switches from root to the host UID before starting an agent.
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    "$IMAGE" \
    bash -c '
      set -euo pipefail
      [[ $(id -u) == 12345 ]]
      head -c 1 /usr/local/share/docker-agent/agent-notes.md >/dev/null
    '
}

test_claude_code_and_locale_are_installed() {
  "$DOCKER_BIN" run --rm --entrypoint bash "$IMAGE" -lc '
    set -euo pipefail
    codex --version | grep -Fx "codex-cli 0.147.0" >/dev/null
    claude --version | grep -F "2.1.229" >/dev/null
    kimi --version | grep -Fx "0.36.0" >/dev/null
    cursor-agent --version | grep -Fx "2026.08.11-e8db854" >/dev/null
    # The upstream installer exposes both names; keep the alias working.
    agent --version | grep -Fx "2026.08.11-e8db854" >/dev/null
    locale -a | grep -Fxi "en_US.utf8" >/dev/null
    LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 locale charmap |
      grep -Fx "UTF-8" >/dev/null
    TZ=Etc/UTC date "+%Z %z" | grep -Fx "UTC +0000" >/dev/null
  '
}

test_wl_paste_shim_converts_bmp_clipboard_to_png() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local backend="$TEST_TMP/wl-paste"
  install -m 755 /dev/null "$backend"
  # This is a hand-checked 2x2 RGB BMP fixture.
  # shellcheck disable=SC2016 # Variables expand when the fake backend runs.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'case ${1:-} in' \
    '  -l|--list-types) printf "image/bmp\n" ;;' \
    '  --type|-t)' \
    '    [[ ${2:-} == image/bmp ]] || exit 1' \
    '    printf %s Qk1GAAAAAAAAADYAAAAoAAAAAgAAAAIAAAABABgAAAAAABAAAADEDgAAxA4AAAAAAAAAAAAAAAD/AAD/AAAAAP8AAP8AAA== | base64 -d' \
    '    ;;' \
    '  *) exit 1 ;;' \
    'esac' >"$backend"

  # Mount a deterministic BMP-only clipboard backend beneath the image shim.
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm \
    --entrypoint bash \
    --mount "type=bind,source=$backend,target=/usr/bin/wl-paste,readonly" \
    "$IMAGE" -c '
      set -euo pipefail
      wl-paste -l | grep -Fx image/png >/dev/null
      out=$(mktemp)
      wl-paste --type image/png >"$out"
      python3 -c "import sys; from PIL import Image; image = Image.open(sys.argv[1]); assert image.format == \"PNG\"; assert image.size == (2, 2)" "$out"
    '
}

test_wl_paste_shim_delegates_other_requests() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local backend="$TEST_TMP/wl-paste"
  install -m 755 /dev/null "$backend"
  # shellcheck disable=SC2016 # Variables expand when the fake backend runs.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case ${1:-} in' \
    '  -l|--list-types) printf "image/png\n" ;;' \
    '  --type|-t)' \
    '    [[ ${2:-} == image/png ]] || exit 23' \
    '    printf PNG-PASSTHROUGH' \
    '    ;;' \
    '  "") printf DEFAULT-PASSTHROUGH ;;' \
    '  --version) printf "backend-version\n" ;;' \
    '  *) exit 23 ;;' \
    'esac' >"$backend"

  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm \
    --entrypoint bash \
    --mount "type=bind,source=$backend,target=/usr/bin/wl-paste,readonly" \
    "$IMAGE" -c '
      set -euo pipefail
      [[ $(wl-paste -l) == image/png ]]
      [[ $(wl-paste --type image/png) == PNG-PASSTHROUGH ]]
      [[ $(wl-paste) == DEFAULT-PASSTHROUGH ]]
      [[ $(wl-paste --version) == backend-version ]]
      set +e
      wl-paste --type image/jpeg >/dev/null
      status=$?
      set -e
      [[ $status == 23 ]]
  '
}

test_claude_tui_pastes_bmp_clipboard_with_ctrl_v() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local claude_home="$TEST_TMP/home"
  local backend="$TEST_TMP/wl-paste"
  install -d -m 755 "$claude_home/.claude"
  printf '%s\n' \
    '{"hasCompletedOnboarding":true,"theme":"dark","projects":{"/workspace":{"hasTrustDialogAccepted":true}}}' \
    >"$claude_home/.claude.json"
  printf '%s\n' '{}' >"$claude_home/.claude/settings.json"
  install -m 755 /dev/null "$backend"
  # shellcheck disable=SC2016 # Variables expand when the fake backend runs.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'case ${1:-} in' \
    '  -l|--list-types) printf "image/bmp\n" ;;' \
    '  --type|-t)' \
    '    [[ ${2:-} == image/bmp ]] || exit 1' \
    '    printf %s Qk1GAAAAAAAAADYAAAAoAAAAAgAAAAIAAAABABgAAAAAABAAAADEDgAAxA4AAAAAAAAAAAAAAAD/AAD/AAAAAP8AAP8AAA== | base64 -d' \
    '    ;;' \
    '  *) exit 1 ;;' \
    'esac' >"$backend"

  python3 - \
    "$DOCKER_BIN" "$IMAGE" "$claude_home" "$backend" \
    "$(id -u)" "$(id -g)" <<'PY'
import os
import pty
import re
import select
import subprocess
import sys
import time

docker, image, home, backend, uid, gid = sys.argv[1:]
container_name = f"docker-agent-claude-clipboard-{os.getpid()}-{time.time_ns()}"
command = [
    docker,
    "run",
    "--rm",
    "-it",
    "--name",
    container_name,
    "--user",
    f"{uid}:{gid}",
    "--entrypoint",
    "bash",
    "--env",
    "TERM=xterm-256color",
    "--env",
    "HOME=/tmp/claude-home",
    "--env",
    "ANTHROPIC_AUTH_TOKEN=test",
    "--env",
    "ANTHROPIC_BASE_URL=http://127.0.0.1:9",
    "--env",
    "DISABLE_AUTOUPDATER=1",
    "--env",
    "DISABLE_TELEMETRY=1",
    "--env",
    "DISABLE_ERROR_REPORTING=1",
    "--env",
    "DISABLE_FEEDBACK_COMMAND=1",
    "--env",
    "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1",
    "--mount",
    f"type=bind,source={home},target=/tmp/claude-home",
    "--mount",
    f"type=bind,source={backend},target=/usr/bin/wl-paste,readonly",
    "--workdir",
    "/workspace",
    image,
    "-lc",
    "claude",
]

master, slave = pty.openpty()
process = subprocess.Popen(
    command,
    stdin=slave,
    stdout=slave,
    stderr=slave,
    close_fds=True,
)
os.close(slave)
output = bytearray()
sent_paste = False
pasted = False
deadline = time.monotonic() + 30

try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                chunk = b""
            if chunk:
                output.extend(chunk)

        if not sent_paste and b"shortcuts" in output:
            os.write(master, b"\x16")
            sent_paste = True

        image_at = output.rfind(b"Image")
        attachment_at = output.find(b"#1]", image_at)
        if image_at >= 0 and 0 <= attachment_at - image_at < 100:
            pasted = True
            break

        if b"No image found in clipboard" in output or process.poll() is not None:
            break
finally:
    if process.poll() is None:
        try:
            os.write(master, b"\x03\x03")
        except OSError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    os.close(master)
    subprocess.run(
        [docker, "rm", "--force", container_name],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )

if not pasted:
    clean = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", bytes(output))
    clean = clean.replace(b"\r", b"\n")
    sys.stderr.write(
        "Claude TUI did not accept the BMP clipboard after Ctrl+V:\n"
        + clean[-4000:].decode("utf-8", errors="replace")
        + "\n"
    )
    raise SystemExit(1)
PY
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
    '[[ $CLAUDE_CODE_ATTRIBUTION_HEADER == 0 ]]' \
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

test_kimi_notes_reach_the_path_kimi_reads() {
  # Kimi Code has no flag that appends to the system prompt; it merges the
  # generic cross-tool instruction file resolved through os.homedir(). The
  # probe asserts the notes land exactly where that resolves for the runtime
  # user, and that the shared data root is left alone.
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local probe_dir="$TEST_TMP/probe"
  install -d -m 755 "$probe_dir"
  # shellcheck disable=SC2016 # Variables expand when the generated probe runs.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[[ $(id -u) == 12345 ]]' \
    '[[ $(id -g) == 23456 ]]' \
    '[[ $KIMI_CODE_HOME == /tmp/kimi-home ]]' \
    'resolved=$(node -e "
       const os = require(\"os\");
       const path = require(\"path\");
       process.stdout.write(path.join(os.homedir(), \".agents\", \"AGENTS.md\"));
     ")' \
    '[[ $resolved == "$HOME/.agents/AGENTS.md" ]]' \
    '[[ -r $resolved ]]' \
    'cmp -s /usr/local/share/docker-agent/agent-notes.md "$resolved"' \
    '[[ $(stat -c %u "$resolved") == 12345 ]]' \
    '[[ ! -e /tmp/kimi-home/AGENTS.md ]]' \
    '[[ ${1:-} == --yolo ]]' \
    >"$probe_dir/kimi"
  chmod 0755 "$probe_dir/kimi"

  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    --env KIMI_CODE_HOME=/tmp/kimi-home \
    --env PATH=/probe:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    --mount "type=bind,source=$probe_dir,target=/probe,readonly" \
    "$IMAGE" kimi --yolo
}

test_cursor_agent_receives_the_key_without_it_reaching_the_command_line() {
  # The entrypoint must turn the read-only key mount into CURSOR_API_KEY. The
  # probe stands in for the real CLI so no request is billed.
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local probe_dir="$TEST_TMP/probe"
  local key_file="$TEST_TMP/cursor-api-key"
  install -d -m 755 "$probe_dir"
  install -m 600 /dev/null "$key_file"
  printf '%s\n' 'image-test-key' >"$key_file"
  # shellcheck disable=SC2016 # Variables expand when the generated probe runs.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[[ $(id -u) == 12345 ]]' \
    '[[ $CURSOR_API_KEY == image-test-key ]]' \
    '[[ ${1:-} == --disable-auto-update ]]' \
    '[[ ${2:-} == --force ]]' \
    >"$probe_dir/cursor-agent"
  chmod 0755 "$probe_dir/cursor-agent"

  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    --env PATH=/probe:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    --mount "type=bind,source=$probe_dir,target=/probe,readonly" \
    --mount "type=bind,source=$key_file,target=/run/docker-agent/cursor-api-key,readonly" \
    "$IMAGE" cursor-agent --disable-auto-update --force
}

test_cursor_agent_runs_from_its_own_bundled_runtime() {
  # The archive ships its own Node; the CLI must not depend on the image one.
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm --entrypoint bash "$IMAGE" -lc '
    set -euo pipefail
    [[ -x /opt/cursor-agent/node ]]
    [[ $(readlink -f "$(command -v cursor-agent)") == /opt/cursor-agent/cursor-agent ]]
    [[ $(readlink -f "$(command -v agent)") == /opt/cursor-agent/cursor-agent ]]
    /opt/cursor-agent/node --version | grep -E "^v[0-9]+" >/dev/null
    # /usr/local/bin holds the image Node; the CLI must work without it.
    PATH=/usr/bin:/bin /opt/cursor-agent/cursor-agent --version >/dev/null
  '
}

test_codex_still_sends_the_clipboard_script_the_shim_emulates() {
  # The shim is coupled to Codex internals, so a Codex upgrade can silently
  # break clipboard paste. Read the script out of the pinned build instead of
  # trusting the snapshot to still describe it.
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm \
    --env CODEX_CLIPBOARD_PS_SCRIPT="$CODEX_CLIPBOARD_PS_SCRIPT" \
    --env CODEX_CLIPBOARD_PS_PATTERN="$CODEX_CLIPBOARD_PS_PATTERN" \
    --entrypoint bash \
    "$IMAGE" \
    -lc '
      set -euo pipefail
      shopt -s nullglob
      binaries=(/usr/local/lib/node_modules/@openai/codex/node_modules/@openai/codex-*/vendor/*/bin/codex)
      if (( ${#binaries[@]} != 1 )); then
        printf "%s\n" "expected one codex native binary, found ${#binaries[@]}" >&2
        exit 1
      fi
      # Codex spawns powershell.exe first among its candidate names; the shim
      # only intercepts the call while that name is still in the binary.
      grep -aFq "powershell.exe" "${binaries[0]}" || {
        printf "%s\n" "codex no longer references powershell.exe" >&2
        exit 1
      }
      actual=$(grep -aoPm1 "$CODEX_CLIPBOARD_PS_PATTERN" "${binaries[0]}") || {
        printf "%s\n" "no clipboard script found in the codex binary" >&2
        exit 1
      }
      if [[ $actual != "$CODEX_CLIPBOARD_PS_SCRIPT" ]]; then
        printf "%s\n" "codex clipboard contract drifted; review the shim" >&2
        printf "expected: %s\n" "$CODEX_CLIPBOARD_PS_SCRIPT" >&2
        printf "actual:   %s\n" "$actual" >&2
        exit 1
      fi
    '
}

test_powershell_shim_reads_wayland_clipboard_image() {
  # shellcheck disable=SC2016,SC2026 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    --env WSL_DISTRO_NAME=Ubuntu \
    --env CODEX_CLIPBOARD_PS_SCRIPT="$CODEX_CLIPBOARD_PS_SCRIPT" \
    "$IMAGE" \
    bash -lc '
      set -euo pipefail
      export WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/tmp
      work=$(mktemp -d)
      cd "$work"
      python3 -c "from PIL import Image; Image.new(\"RGB\", (2, 2), (255, 0, 0)).save(\"clip.bmp\", \"BMP\")"
      printf "#!/usr/bin/env bash\ncase \"\${1:-}\" in --list-types) printf \"image/bmp\\\\n\";; --type|-t) cat \"$work/clip.bmp\";; *) exit 1;; esac\n" > wl-paste
      chmod +x wl-paste
      PATH="$work:$PATH" out=$(powershell.exe -NoProfile -Command "$CODEX_CLIPBOARD_PS_SCRIPT")
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
test_docker_client_tools_are_available_without_a_daemon
test_runtime_user_has_passwordless_sudo_without_root_group
test_runtime_user_keeps_host_docker_supplementary_group
test_login_shell_keeps_toolchain_on_path
test_claude_code_and_locale_are_installed
test_wl_paste_shim_converts_bmp_clipboard_to_png
test_wl_paste_shim_delegates_other_requests
test_claude_tui_pastes_bmp_clipboard_with_ctrl_v
test_claude_runtime_is_non_root_utc_and_en_us
test_python_and_archive_tools_are_available
test_agent_notes_are_readable_by_runtime_user
test_mold_is_default_linker_and_sccache_is_available
test_kimi_notes_reach_the_path_kimi_reads
test_cursor_agent_receives_the_key_without_it_reaching_the_command_line
test_cursor_agent_runs_from_its_own_bundled_runtime
test_codex_still_sends_the_clipboard_script_the_shim_emulates
test_powershell_shim_reads_wayland_clipboard_image
printf 'image tests: PASS\n'
