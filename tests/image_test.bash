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
      [[ :$PATH: == *:/usr/local/go/bin:* ]]
      [[ :$PATH: == *:/codex-cache/go/bin:* ]]
      [[ :$PATH: == *:/codex-cache/pnpm:* ]]
      command -v cargo rustc rustfmt cargo-clippy go gofmt pnpm >/dev/null
    '
}

test_go_toolchain_and_cache_are_available() {
  # This catches a missing/wrong Go archive, lost cache configuration, and a
  # toolchain that is present on PATH but cannot build a real module.
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    "$IMAGE" \
    bash -lc '
      set -euo pipefail
      [[ $(go version) == "go version go1.26.6 linux/$(go env GOARCH)" ]]
      [[ $(go env GOROOT) == /usr/local/go ]]
      [[ $GOPATH == /codex-cache/go ]]
      [[ $GOMODCACHE == /codex-cache/go/pkg/mod ]]
      [[ $GOCACHE == /codex-cache/go-build ]]
      if dpkg-query --show golang-go >/dev/null 2>&1; then
        printf "%s\n" "golang-go unexpectedly installed through dpkg" >&2
        exit 1
      fi
      work=$(mktemp -d)
      cd "$work"
      go mod init example.com/docker-agent-smoke >/dev/null 2>&1
      printf "%s\n" \
        "package main" \
        "import \"fmt\"" \
        "func main() { fmt.Println(\"Hello from Go!\") }" \
        > main.go
      [[ $(go run .) == "Hello from Go!" ]]
    '
}

test_python_and_archive_tools_are_available() {
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm --entrypoint bash "$IMAGE" -c '
    set -euo pipefail
    command -v python3 python pip3 unzip zip container-codex-session-repair >/dev/null
    python3 -m venv --help >/dev/null
    [[ -r /usr/local/share/docker-agent/agent-notes.md ]]
    [[ -x /usr/local/bin/container-codex-session-repair ]]
  '
}

test_session_repair_runs_as_host_user_and_persists_to_host() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local codex_home="$TEST_TMP/codex home"
  local output="$TEST_TMP/output"
  mkdir -p "$codex_home/sessions/2026/08/19"

  python3 - "$codex_home" <<'PY'
import json
import sqlite3
import sys
from pathlib import Path

home = Path(sys.argv[1])
session_id = "image-session"
relative = Path("2026/08/19/image-session.jsonl")
rollout = home / "sessions" / relative
rollout.write_text(
    json.dumps({"type": "session_meta", "payload": {"id": session_id}}) + "\n",
    encoding="utf-8",
)
with sqlite3.connect(home / "state_5.sqlite") as database:
    database.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT)")
    database.execute(
        "INSERT INTO threads VALUES (?, ?)",
        (session_id, "/codex-home/sessions/" + str(relative)),
    )
PY

  "$DOCKER_BIN" run --rm \
    --network none \
    --env "HOST_UID=$(id -u)" \
    --env "HOST_GID=$(id -g)" \
    --env "CODEX_HOME=$codex_home" \
    --mount "type=bind,source=$codex_home,target=$codex_home" \
    --mount "type=bind,source=$codex_home,target=/codex-home" \
    "$IMAGE" container-codex-session-repair >"$output"

  assert_contains "updated: 1" "$output"
  assert_contains "skipped: 0" "$output"
  python3 - "$codex_home" "$(id -u)" "$(id -g)" <<'PY'
import os
import sqlite3
import sys
from pathlib import Path

home = Path(sys.argv[1])
uid = int(sys.argv[2])
gid = int(sys.argv[3])
with sqlite3.connect(home / "state_5.sqlite") as database:
    path = database.execute(
        "SELECT rollout_path FROM threads WHERE id = 'image-session'"
    ).fetchone()[0]
assert path == str(home / "sessions/2026/08/19/image-session.jsonl"), path
backups = list((home / "session-repair-backups").glob("*.bak"))
assert len(backups) == 1, backups
assert backups[0].stat().st_uid == uid
assert backups[0].stat().st_gid == gid
assert os.stat(backups[0]).st_mode & 0o777 == 0o600
PY

  "$DOCKER_BIN" run --rm \
    --network none \
    --env "HOST_UID=$(id -u)" \
    --env "HOST_GID=$(id -g)" \
    --env "CODEX_HOME=$codex_home" \
    --mount "type=bind,source=$codex_home,target=$codex_home" \
    --mount "type=bind,source=$codex_home,target=/codex-home" \
    "$IMAGE" container-codex-session-repair >"$output"
  assert_contains "updated: 0" "$output"
}

test_macos_uid_is_created_without_range_warning() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local output="$TEST_TMP/output"

  "$DOCKER_BIN" run --rm \
    --env HOST_UID=502 \
    --env HOST_GID=20 \
    "$IMAGE" true >"$output" 2>&1

  assert_not_contains "outside of the UID_MIN" "$output"
}

test_root_mapped_claude_profile_is_accepted() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local probe_dir="$TEST_TMP/probe"
  install -d -m 755 "$probe_dir"

  # shellcheck disable=SC2016 # Variables expand when the container runs the probe.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[[ $(id -u) == 502 ]]' \
    '[[ $(id -g) == 20 ]]' \
    '[[ $ANTHROPIC_BASE_URL == https://example.invalid/anthropic ]]' \
    '[[ $ANTHROPIC_AUTH_TOKEN == root-mapped-test-token ]]' \
    >"$probe_dir/claude"
  chmod 0755 "$probe_dir/claude"

  # OrbStack and other macOS Docker backends can expose a host-owned bind
  # mount as root:root inside their Linux VM. Create the same metadata in the
  # container while keeping the profile mode locked to 0600.
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm \
    --entrypoint bash \
    --mount "type=bind,source=$probe_dir,target=/probe,readonly" \
    "$IMAGE" -lc '
      set -euo pipefail
      profile=/tmp/root-mapped-profile.env
      printf "%s\n" \
        "ANTHROPIC_BASE_URL=https://example.invalid/anthropic" \
        "ANTHROPIC_AUTH_TOKEN=root-mapped-test-token" >"$profile"
      chmod 0600 "$profile"
      [[ $(stat -c %u "$profile") == 0 ]]
      HOST_UID=502 \
      HOST_GID=20 \
      DOCKER_AGENT_CLAUDE_CONNECTION=profile:root-mapped \
      DOCKER_AGENT_CLAUDE_PROFILE_FILE="$profile" \
      PATH=/probe:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        exec /usr/local/bin/container-entrypoint claude
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
    codex --version | grep -Fx "codex-cli 0.148.0" >/dev/null
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

test_codex_accepts_one_file_native_provider_profile() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local codex_home="$TEST_TMP/codex-home"
  local profile_dir="$TEST_TMP/agent-config/codex/profiles"
  local profile="$profile_dir/relay.config.toml"
  local other_profile="$profile_dir/other.config.toml"
  local output="$TEST_TMP/output"
  install -d -m 700 "$codex_home"
  install -d -m 700 "$profile_dir"
  install -m 600 /dev/null "$profile"
  printf '%s\n' \
    'model_provider = "docker-agent-relay"' \
    'model = "gpt-5.4"' \
    'review_model = "gpt-5.4"' \
    '' \
    '[model_providers."docker-agent-relay"]' \
    'name = "relay"' \
    'base_url = "https://relay.example.invalid/v1"' \
    'wire_api = "responses"' \
    'experimental_bearer_token = "fixture-secret"' \
    >"$profile"
  install -m 600 /dev/null "$other_profile"
  printf '%s\n' \
    'model = "other-model"' \
    'experimental_bearer_token = "other-secret"' \
    >"$other_profile"
  ln -s "$profile" "$codex_home/relay.config.toml"
  ln -s "$other_profile" "$codex_home/other.config.toml"

  "$DOCKER_BIN" run --rm --network none \
    --user "$(id -u):$(id -g)" \
    --mount "type=bind,source=$codex_home,target=/codex-profile-test" \
    --mount "type=bind,source=$profile,target=$profile,readonly" \
    --entrypoint bash \
    "$IMAGE" -lc \
    '[[ -r /codex-profile-test/relay.config.toml ]] &&
     [[ ! -e /codex-profile-test/other.config.toml ]]'

  if "$DOCKER_BIN" run --rm --network none \
      --user "$(id -u):$(id -g)" \
      --env CODEX_HOME=/codex-profile-test \
      --mount "type=bind,source=$codex_home,target=/codex-profile-test" \
      --mount "type=bind,source=$profile,target=$profile,readonly" \
      --entrypoint codex \
      "$IMAGE" \
      --strict-config --profile relay \
      archive no-such-session-for-config-test >"$output" 2>&1; then
    fail "Codex unexpectedly found the profile validation session"
  fi
  assert_contains \
    "No active session found matching 'no-such-session-for-config-test'." \
    "$output"
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

test_forwarded_terminal_keeps_its_color_depth() {
  # Docker sets a bare TERM=xterm, capping the container at 8 colors and
  # costing agent TUIs the background rendering of their input box.
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    --env TERM=xterm-256color \
    "$IMAGE" \
    bash -lc '
      set -euo pipefail
      [[ $TERM == xterm-256color ]]
      [[ $(tput colors) == 256 ]]
    '

  # A terminal with no entry in the image must degrade to a 256-color one
  # rather than break curses or fall back to the 8-color default.
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    --env TERM=xterm-nonexistent-terminal \
    "$IMAGE" \
    bash -lc '
      set -euo pipefail
      [[ $TERM == xterm-256color ]]
      [[ $(tput colors) == 256 ]]
    '
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

test_cursor_shared_data_root_persists_writes_to_the_host() {
  # Cursor records workspace trust and session history under
  # $HOME/.cursor/projects, and has no environment variable that relocates
  # that directory. If the link is wrong the trust prompt returns on every
  # launch, so verify a container-side write reaches the host directory.
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local probe_dir="$TEST_TMP/probe"
  local key_file="$TEST_TMP/cursor-api-key"
  local cursor_home="$TEST_TMP/cursor-home"
  install -d -m 755 "$probe_dir"
  install -d -m 700 "$cursor_home"
  install -m 600 /dev/null "$key_file"
  printf '%s\n' 'image-test-key' >"$key_file"
  # shellcheck disable=SC2016 # Variables expand when the generated probe runs.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[[ -L $HOME/.cursor ]]' \
    '[[ $(readlink "$HOME/.cursor") == /cursor-home ]]' \
    'mkdir -p "$HOME/.cursor/projects/probe-project"' \
    ': > "$HOME/.cursor/projects/probe-project/.workspace-trusted"' \
    >"$probe_dir/cursor-agent"
  chmod 0755 "$probe_dir/cursor-agent"

  "$DOCKER_BIN" run --rm \
    --env HOST_UID="$(id -u)" \
    --env HOST_GID="$(id -g)" \
    --env PATH=/probe:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    --mount "type=bind,source=$probe_dir,target=/probe,readonly" \
    --mount "type=bind,source=$key_file,target=/run/docker-agent/cursor-api-key,readonly" \
    --mount "type=bind,source=$cursor_home,target=/cursor-home" \
    "$IMAGE" cursor-agent

  [[ -f $cursor_home/projects/probe-project/.workspace-trusted ]] ||
    fail "the container write did not reach the host Cursor data directory"
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

test_every_agent_still_accepts_the_instruction_channel_we_use() {
  # Injecting the shared notes couples us to each upstream CLI. Codex silently
  # ignores unknown -c keys, so when user_instructions was removed in 0.147.0
  # the notes stopped arriving with no error anywhere. Assert each channel
  # against the pinned builds so the next rename fails here instead.
  # shellcheck disable=SC2016 # Variables expand inside the container.
  "$DOCKER_BIN" run --rm --entrypoint bash "$IMAGE" -lc '
    set -euo pipefail

    codex_bin=$(ls /usr/local/lib/node_modules/@openai/codex/node_modules/@openai/codex-*/vendor/*/bin/codex)
    grep -aFq "developer_instructions" "$codex_bin" || {
      printf "%s\n" "codex no longer knows developer_instructions; the notes are silently dropped" >&2
      exit 1
    }

    grep -rqa -- "append-system-prompt-file" \
      /usr/local/lib/node_modules/@anthropic-ai/claude-code/ || {
      printf "%s\n" "claude no longer accepts --append-system-prompt-file" >&2
      exit 1
    }

    kimi_bundle=/usr/local/lib/node_modules/@moonshot-ai/kimi-code/dist/main.mjs
    grep -aFq ".agents" "$kimi_bundle" || {
      printf "%s\n" "kimi no longer reads the generic ~/.agents instruction path" >&2
      exit 1
    }
    grep -aFq "AGENTS.md" "$kimi_bundle" || {
      printf "%s\n" "kimi no longer reads AGENTS.md" >&2
      exit 1
    }

    # Cursor Agent has no flag that appends to the system prompt, which is why
    # the notes are not injected for it. If upstream adds one, wire it up.
    if cursor-agent --help 2>&1 |
      grep -qiE -- "--append-system-prompt|--system-prompt-file"; then
      printf "%s\n" "cursor-agent gained a system-prompt flag; the notes can now be injected" >&2
      exit 1
    fi
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
      if [[ ${binaries[0]+set} == set ]]; then
        binary_count=${#binaries[@]}
      else
        binary_count=0
      fi
      if (( binary_count != 1 )); then
        printf "%s\n" "expected one codex native binary, found $binary_count" >&2
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
test_macos_uid_is_created_without_range_warning
test_root_mapped_claude_profile_is_accepted
test_runtime_user_keeps_host_docker_supplementary_group
test_login_shell_keeps_toolchain_on_path
test_go_toolchain_and_cache_are_available
test_claude_code_and_locale_are_installed
test_codex_accepts_one_file_native_provider_profile
test_wl_paste_shim_converts_bmp_clipboard_to_png
test_wl_paste_shim_delegates_other_requests
test_claude_tui_pastes_bmp_clipboard_with_ctrl_v
test_claude_runtime_is_non_root_utc_and_en_us
test_python_and_archive_tools_are_available
test_session_repair_runs_as_host_user_and_persists_to_host
test_agent_notes_are_readable_by_runtime_user
test_mold_is_default_linker_and_sccache_is_available
test_kimi_notes_reach_the_path_kimi_reads
test_forwarded_terminal_keeps_its_color_depth
test_every_agent_still_accepts_the_instruction_channel_we_use
test_cursor_agent_receives_the_key_without_it_reaching_the_command_line
test_cursor_shared_data_root_persists_writes_to_the_host
test_cursor_agent_runs_from_its_own_bundled_runtime
test_codex_still_sends_the_clipboard_script_the_shim_emulates
test_powershell_shim_reads_wayland_clipboard_image
printf 'image tests: PASS\n'
