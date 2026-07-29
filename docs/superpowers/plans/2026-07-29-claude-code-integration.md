# Claude Code 集成实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不破坏现有 Codex 工作流的前提下，用同一个镜像和统一的 `docker-agent` 启动器支持 Claude Code、三种认证方式、交互菜单及隔离状态。

**Architecture:** 将现有 `docker-codex` 重构为按调用名称和 agent 子命令分发的单文件 Bash 启动器，继续复用 checkout、Git metadata、cache、PAT、worktree 和剪贴板逻辑。Claude 专用 profile 在宿主和入口脚本两侧按白名单验证，session 状态按仓库、worktree 和连接身份存放在独立 data home；镜像固定安装 Codex 与 Claude Code，并只为 Claude 进程设置 UTC、`en_US.UTF-8`、关闭自动更新和四个独立遥测/反馈变量。

**Tech Stack:** Bash 3.2+、Docker、Debian 13、Git、npm、`@openai/codex`、`@anthropic-ai/claude-code`、现有无框架 shell 测试。

## Global Constraints

- 使用一个 `docker-agent:local` 镜像，不拆分 Codex/Claude 镜像。
- 保持 `CODEX_VERSION=0.145.0`；新增并固定 `CLAUDE_CODE_VERSION=2.1.212`，该版本是 2026-07-29 的 npm `stable` dist-tag。
- 启动器必须兼容 Bash 3.2，不得使用 associative array、`mapfile` 或 Bash 4+ 特性。
- 标准入口为 `docker-agent codex` 和 `docker-agent claude`；`docker-codex`、`docker-claude` 必须继续作为单文件兼容入口工作。
- `docker-codex` 的现有参数、Codex home、cache volume、PAT、worktree、clipboard 和 `--yolo --disable apps` 行为不得回归。
- Claude 的连接参数固定为 `--official-subscription`、`--official-api`、`--profile NAME`，三者互斥。
- 未指定 Claude 连接方式时，仅在 stdin/stdout 都是 TTY 的情况下显示两级菜单；非 TTY 必须报错。
- profile 根目录固定为 `${DOCKER_AGENT_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent}/claude/profiles`。
- profile 必须是调用用户拥有的非符号链接普通文件，权限精确为 `0600`；不得位于 checkout 内。
- profile parser 只能接受 spec 中列出的九个变量，绝不能 `source`、`eval` 或 wildcard-forward。
- Claude 状态必须按 canonical Git common directory、canonical checkout 和连接身份隔离，并验证 identity metadata。
- 订阅模式只读写挂载 `.credentials.json`，绝不完整挂载宿主 `~/.claude`。
- 每个 Claude 进程固定设置 `TZ=Etc/UTC`、`LANG=en_US.UTF-8`、`LC_ALL=en_US.UTF-8`、`LANGUAGE=en_US:en`。
- 每个 Claude 进程分别设置 `DISABLE_AUTOUPDATER=1`、`DISABLE_TELEMETRY=1`、`DISABLE_ERROR_REPORTING=1`、`DISABLE_FEEDBACK_COMMAND=1`、`CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1`；不得使用合并变量。
- Claude 使用 `--dangerously-skip-permissions`，但不得注入回答语言、人格或风格指令。
- 所有实现提交都使用 `Co-Authored-By: Codex GPT-5.6-Sol <noreply@openai.com>`。

---

### Task 1: 建立统一 dispatcher 和兼容入口

**Files:**
- Create: `docker-agent`
- Replace with symlink: `docker-codex`
- Create symlink: `docker-claude`
- Modify: `tests/testlib.bash:64-100`
- Modify: `tests/launcher_test.bash:8-433`

**Interfaces:**
- Consumes: 现有 `docker-codex [options] -- [codex args]` 公开接口。
- Produces: `docker-agent {codex|claude}` dispatch、basename dispatch，以及测试 helper `run_named_launcher DIRECTORY PROJECT_ROOT LAUNCHER_NAME [ARGS...]`。

- [ ] **Step 1: 为标准入口和兼容入口写失败测试**

在 `tests/testlib.bash` 中增加按文件名运行启动器的 helper，并保留现有
`run_launcher` 作为 Codex 兼容包装：

```bash
run_named_launcher() {
  local directory=$1 project_root=$2 launcher_name=$3
  shift 3
  (
    cd "$directory"
    CODEX_HOME="$TEST_CODEX_HOME" \
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
```

让 fake Docker 优先读取新测试变量并兼容旧变量：

```bash
log=${DOCKER_AGENT_TEST_DOCKER_LOG:-${DOCKER_CODEX_TEST_DOCKER_LOG:?}}
```

在 `tests/launcher_test.bash` 增加：

```bash
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
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```bash
tests/launcher_test.bash
```

Expected: FAIL，因为 `docker-agent` 和 `docker-claude` 尚不存在。

- [ ] **Step 3: 将现有脚本移动为统一 dispatcher**

执行：

```bash
git mv docker-codex docker-agent
ln -s docker-agent docker-codex
ln -s docker-agent docker-claude
```

在 `docker-agent` 顶部根据 basename 选择 agent：

```bash
PROGRAM_NAME=$(basename "$0")
case $PROGRAM_NAME in
  docker-codex)
    AGENT=codex
    ;;
  docker-claude)
    AGENT=claude
    ;;
  docker-agent)
    case ${1:-} in
      -h|--help)
        usage_agent
        exit 0
        ;;
    esac
    (($# >= 1)) || die "expected agent: codex or claude"
    AGENT=$1
    shift
    [[ $AGENT == codex || $AGENT == claude ]] ||
      die "unsupported agent: $AGENT"
    ;;
  *)
    die "unsupported launcher name: $PROGRAM_NAME"
    ;;
esac
```

将错误前缀从固定 `docker-codex` 改为 `$PROGRAM_NAME`：

```bash
die() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}
```

公共环境变量使用新名称并回退到旧名称：

```bash
DOCKER_BIN=${DOCKER_AGENT_DOCKER_BIN:-${DOCKER_CODEX_DOCKER_BIN:-docker}}
IMAGE=${DOCKER_AGENT_IMAGE:-${DOCKER_CODEX_IMAGE:-docker-agent:local}}
HOST_OS=${DOCKER_AGENT_HOST_OS:-${DOCKER_CODEX_HOST_OS:-$(uname -s)}}
DATA_HOME=${DOCKER_AGENT_DATA_HOME:-${DOCKER_CODEX_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/docker-agent}}
PAT_PATH=${DOCKER_AGENT_PAT_PATH:-${DOCKER_CODEX_PAT_PATH:-}}
WAYLAND_DIR_OVERRIDE=${DOCKER_AGENT_WAYLAND_DIR:-${DOCKER_CODEX_WAYLAND_DIR:-}}
X11_DIR_OVERRIDE=${DOCKER_AGENT_X11_DIR:-${DOCKER_CODEX_X11_DIR:-}}
```

`create_isolated_worktree` 和 `--pat` 都使用统一的 `DATA_HOME`；
clipboard 分支分别使用 `WAYLAND_DIR_OVERRIDE` 和 `X11_DIR_OVERRIDE`。
保留现有 `docker-codex-cache-$REPO_ID` volume 名称和容器内
`/codex-cache`，不因入口重命名而冷启动依赖缓存。

只有 Codex 模式检查并挂载 Codex home：

```bash
if [[ $AGENT == codex ]]; then
  CODEX_HOME_SOURCE=${CODEX_HOME:-$HOME/.codex}
  [[ -d $CODEX_HOME_SOURCE ]] ||
    die "Codex home does not exist: $CODEX_HOME_SOURCE"
  CODEX_HOME_SOURCE=$(cd "$CODEX_HOME_SOURCE" && pwd -P)
  reject_mount_comma "$CODEX_HOME_SOURCE"
  DOCKER_ARGS+=(--env "CODEX_HOME=/codex-home")
  DOCKER_ARGS+=(--mount "type=bind,source=$CODEX_HOME_SOURCE,target=/codex-home")
fi
```

为第一阶段的 Claude 直连解析 `--official-subscription`：

```bash
select_claude_connection() {
  local selected=$1
  [[ $AGENT == claude ]] ||
    die "$selected is only valid for Claude"
  [[ -z $CLAUDE_CONNECTION ]] ||
    die "Claude connection selectors are mutually exclusive"
  CLAUDE_CONNECTION=${selected#--}
}

# 加入现有参数解析 case：
--official-subscription)
  select_claude_connection "$1"
  shift
  ;;
```

最终命令按 agent 分发。Launcher 只传递 `claude` 及用户参数；
`--dangerously-skip-permissions` 由 Task 6 的 entrypoint 唯一注入：

```bash
case $AGENT in
  codex)
    FINAL_ARGS=(codex --yolo --disable apps "${AGENT_ARGS[@]}")
    ;;
  claude)
    FINAL_ARGS=(claude "${AGENT_ARGS[@]}")
    ;;
esac

exec "$DOCKER_BIN" "${DOCKER_ARGS[@]}" "$IMAGE" "${FINAL_ARGS[@]}"
```

- [ ] **Step 4: 更新 usage 并验证旧接口**

实现 `usage_agent` 和 `usage_codex`/`usage_claude`，确保：

```text
docker-agent --help
docker-agent codex --help
docker-agent claude --help
docker-codex --help
docker-claude --help
```

分别显示正确入口；Claude 原生 `--help` 必须通过 `-- --help` 传递。

Run:

```bash
tests/launcher_test.bash
```

Expected: `launcher tests: PASS`。

- [ ] **Step 5: 执行语法和静态检查**

Run:

```bash
for script in docker-agent docker-codex docker-claude tests/testlib.bash tests/launcher_test.bash; do
  bash -n "$script"
done
shellcheck -x -P . docker-agent tests/testlib.bash tests/launcher_test.bash
```

Expected: 两个命令均以状态码 0 退出。

- [ ] **Step 6: 提交 dispatcher 重构**

```bash
git add docker-agent docker-codex docker-claude tests/testlib.bash tests/launcher_test.bash
git commit -m "feat: add multi-agent launcher dispatch" \
  -m "Co-Authored-By: Codex GPT-5.6-Sol <noreply@openai.com>"
```

---

### Task 2: 在共享镜像中安装固定版本 Claude Code 和 en_US locale

**Files:**
- Modify: `Dockerfile:1-105`
- Modify: `tests/image_test.bash:8-121`

**Interfaces:**
- Consumes: Task 1 的默认镜像名 `docker-agent:local`。
- Produces: Docker build argument `CLAUDE_CODE_VERSION=2.1.212`、镜像内 `claude` 二进制、`en_US.utf8` locale 和 UTC zoneinfo。

- [ ] **Step 1: 写镜像失败测试**

将 `tests/image_test.bash` 的默认镜像变量改为新名称并兼容旧测试变量：

```bash
DOCKER_BIN=${DOCKER_AGENT_DOCKER_BIN:-${DOCKER_CODEX_DOCKER_BIN:-docker}}
IMAGE=${DOCKER_AGENT_TEST_IMAGE:-${DOCKER_CODEX_TEST_IMAGE:-docker-agent:local}}
```

增加：

```bash
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
```

同时将现有 agent notes 断言改为：

```bash
[[ -r /usr/local/share/docker-agent/agent-notes.md ]]
```

在测试列表中调用该函数。

- [ ] **Step 2: 运行测试确认旧镜像失败**

Run:

```bash
DOCKER_AGENT_TEST_IMAGE=docker-codex:local tests/image_test.bash
```

Expected: FAIL，`claude` 不存在或 `en_US.utf8` 未生成。

- [ ] **Step 3: 修改 Dockerfile**

新增固定版本：

```dockerfile
ARG CLAUDE_CODE_VERSION=2.1.212
```

在 apt 安装列表加入：

```text
locales
tzdata
```

apt 安装命令使用非交互模式：

```dockerfile
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
```

生成 locale，但不要设置全局 `ENV LANG`：

```dockerfile
RUN sed -i 's/^# *\(en_US.UTF-8 UTF-8\)$/\1/' /etc/locale.gen \
    && locale-gen en_US.UTF-8 \
    && locale -a | grep -Fxi en_US.utf8
```

固定安装两个 agent：

```dockerfile
RUN npm install --global \
        "@openai/codex@${CODEX_VERSION}" \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "pnpm@${PNPM_VERSION}" \
    && codex --version \
    && claude --version \
    && pnpm --version
```

将 agent notes 的镜像路径中立化，同时保留同一源文件：

```dockerfile
COPY --chmod=0644 agent-notes.md /usr/local/share/docker-agent/agent-notes.md
```

- [ ] **Step 4: 检查并构建全新镜像**

Run:

```bash
docker build --check .
docker build --tag docker-agent:local .
```

Expected: build check 无 warning，镜像构建成功并打印 Codex、Claude、pnpm
版本。

- [ ] **Step 5: 运行镜像测试**

Run:

```bash
DOCKER_AGENT_TEST_IMAGE=docker-agent:local tests/image_test.bash
```

Expected: `image tests: PASS`。

- [ ] **Step 6: 提交镜像变更**

```bash
git add Dockerfile tests/image_test.bash
git commit -m "feat: install Claude Code in shared image" \
  -m "Co-Authored-By: Codex GPT-5.6-Sol <noreply@openai.com>"
```

---

### Task 3: 实现 Claude profile 和直接连接参数

**Files:**
- Create: `tests/claude_launcher_test.bash`
- Modify: `tests/run.bash:1-7`
- Modify: `tests/testlib.bash:80-100`
- Modify: `docker-agent:9-338`

**Interfaces:**
- Consumes: Task 1 的 `AGENT=claude` dispatch。
- Produces:
  - `validate_claude_profile FILE KIND`
  - `resolve_claude_connection`
  - globals `CLAUDE_CONNECTION`, `CLAUDE_PROFILE_NAME`, `CLAUDE_PROFILE_PATH`
  - 容器 mount `/run/docker-agent/claude-profile.env`
  - 环境 `DOCKER_AGENT_CLAUDE_CONNECTION` 和 `DOCKER_AGENT_CLAUDE_PROFILE_FILE`。

- [ ] **Step 1: 建立独立 Claude launcher 测试文件**

在 `tests/run.bash` 中按顺序调用：

```bash
"$ROOT/tests/launcher_test.bash"
"$ROOT/tests/claude_launcher_test.bash"
"$ROOT/tests/entrypoint_test.bash"
```

在 `tests/testlib.bash::prepare_fake_runtime` 创建受保护配置目录：

```bash
TEST_AGENT_CONFIG_HOME="$base/agent config"
TEST_AGENT_DATA_HOME="$base/agent data"
install -d -m 700 "$TEST_AGENT_CONFIG_HOME/claude/profiles"
install -d -m 700 "$TEST_AGENT_DATA_HOME"
```

`run_named_launcher` 传入：

```bash
DOCKER_AGENT_CONFIG_HOME="$TEST_AGENT_CONFIG_HOME"
DOCKER_AGENT_DATA_HOME="$TEST_AGENT_DATA_HOME"
```

创建 `tests/claude_launcher_test.bash`，加入：

```bash
test_official_api_profile_is_mounted_without_secret_in_docker_args() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local profile
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  profile="$TEST_AGENT_CONFIG_HOME/claude/profiles/official-api.env"
  printf '%s\n' 'ANTHROPIC_API_KEY=test-official-secret' >"$profile"
  chmod 600 "$profile"

  run_named_launcher "$repo" "$ROOT" docker-agent \
    claude --official-api -- --version

  assert_line "<type=bind,source=$profile,target=/run/docker-agent/claude-profile.env,readonly>" \
    "$TEST_DOCKER_LOG"
  assert_line "<DOCKER_AGENT_CLAUDE_CONNECTION=official-api>" "$TEST_DOCKER_LOG"
  assert_no_line "<test-official-secret>" "$TEST_DOCKER_LOG"
}

test_custom_profile_validates_endpoint_and_single_credential() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local profile errors="$TEST_TMP/errors"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  profile="$TEST_AGENT_CONFIG_HOME/claude/profiles/deepseek.env"
  printf '%s\n' \
    'ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=test-deepseek-secret' \
    'ANTHROPIC_MODEL=deepseek-v4-pro[1m]' \
    'ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-pro[1m]' \
    'ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-pro[1m]' \
    'ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash' \
    'CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-flash' \
    'CLAUDE_CODE_EFFORT_LEVEL=max' >"$profile"
  chmod 600 "$profile"

  run_named_launcher "$repo" "$ROOT" docker-agent \
    claude --profile deepseek -- --version
  assert_line "<DOCKER_AGENT_CLAUDE_CONNECTION=profile:deepseek>" "$TEST_DOCKER_LOG"
  assert_no_line "<test-deepseek-secret>" "$TEST_DOCKER_LOG"

  : >"$TEST_DOCKER_LOG"
  printf '%s\n' \
    'ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=one' \
    'ANTHROPIC_API_KEY=two' >"$profile"
  chmod 600 "$profile"
  if run_named_launcher "$repo" "$ROOT" docker-agent \
    claude --profile deepseek -- --version >"$errors" 2>&1; then
    fail "conflicting custom profile unexpectedly succeeded"
  fi
  assert_contains "exactly one credential" "$errors"
  assert_no_line "<run>" "$TEST_DOCKER_LOG"
}
```

再增加独立测试覆盖：未知 key、重复 key、非法 effort、空 endpoint、非法
profile 名称、保留名称、符号链接、错误 owner/mode、配置目录位于 checkout
内，以及三个 selector 同时出现时失败。

- [ ] **Step 2: 运行新测试确认失败**

Run:

```bash
tests/claude_launcher_test.bash
```

Expected: FAIL，因为 profile selector 和验证函数尚未实现。

- [ ] **Step 3: 实现跨平台文件 metadata helper**

在 `docker-agent` 增加：

```bash
file_uid() {
  if stat -c %u "$1" >/dev/null 2>&1; then
    stat -c %u "$1"
  else
    stat -f %u "$1"
  fi
}

file_mode() {
  if stat -c %a "$1" >/dev/null 2>&1; then
    stat -c %a "$1"
  else
    stat -f %Lp "$1"
  fi
}

array_contains() {
  local needle=$1 item
  shift
  for item in "$@"; do
    [[ $item == "$needle" ]] && return 0
  done
  return 1
}
```

- [ ] **Step 4: 实现 host profile validator**

函数签名固定为：

```bash
validate_claude_profile() {
  local file=$1 kind=$2
  local line key value
  local seen_keys=()
  local has_base=0 has_auth_token=0 has_api_key=0

  [[ -e $file ]] || die "Claude profile does not exist: $file"
  [[ ! -L $file ]] || die "Claude profile must not be a symlink: $file"
  [[ -f $file ]] || die "Claude profile must be a regular file: $file"
  [[ $(file_uid "$file") == "$(id -u)" ]] ||
    die "Claude profile must be owned by the current user: $file"
  [[ $(file_mode "$file") == 600 ]] ||
    die "Claude profile must have mode 600: $file"

  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    [[ $line =~ ^[[:space:]]*# ]] && continue
    [[ $line == *=* ]] || die "invalid Claude profile assignment"
    key=${line%%=*}
    value=${line#*=}
    [[ $key =~ ^[A-Z][A-Z0-9_]*$ ]] ||
      die "invalid Claude profile key: $key"
    array_contains "$key" "${seen_keys[@]}" &&
      die "duplicate Claude profile key: $key"
    seen_keys+=("$key")

    case $key in
      ANTHROPIC_BASE_URL) [[ -n $value ]] || die "empty ANTHROPIC_BASE_URL"; has_base=1 ;;
      ANTHROPIC_AUTH_TOKEN) [[ -n $value ]] || die "empty ANTHROPIC_AUTH_TOKEN"; has_auth_token=1 ;;
      ANTHROPIC_API_KEY) [[ -n $value ]] || die "empty ANTHROPIC_API_KEY"; has_api_key=1 ;;
      ANTHROPIC_MODEL|ANTHROPIC_DEFAULT_OPUS_MODEL|ANTHROPIC_DEFAULT_SONNET_MODEL|ANTHROPIC_DEFAULT_HAIKU_MODEL|CLAUDE_CODE_SUBAGENT_MODEL)
        ;;
      CLAUDE_CODE_EFFORT_LEVEL)
        [[ $value =~ ^(low|medium|high|xhigh|max|auto)$ ]] ||
          die "invalid CLAUDE_CODE_EFFORT_LEVEL"
        ;;
      *) die "unsupported Claude profile key: $key" ;;
    esac
  done <"$file"

  if [[ $kind == official-api ]]; then
    ((has_api_key == 1 && has_auth_token == 0 && has_base == 0)) ||
      die "official API profile requires only ANTHROPIC_API_KEY"
  else
    ((has_base == 1 && has_auth_token + has_api_key == 1)) ||
      die "custom profile requires endpoint and exactly one credential"
  fi
}
```

- [ ] **Step 5: 解析 selector 并构造 profile mount**

解析参数时设置：

```bash
CLAUDE_CONNECTION=
CLAUDE_PROFILE_NAME=
```

三个 selector 通过统一 helper 拒绝重复选择。profile 名称校验：

```bash
case $1 in
  --official-subscription)
    select_claude_connection "$1"
    shift
    ;;
  --official-api)
    select_claude_connection "$1"
    CLAUDE_PROFILE_NAME=official-api
    shift
    ;;
  --profile)
    (($# >= 2)) || die "--profile requires a name"
    select_claude_connection "$1"
    CLAUDE_PROFILE_NAME=$2
    CLAUDE_CONNECTION="profile:$CLAUDE_PROFILE_NAME"
    shift 2
    ;;
esac

if [[ -n $CLAUDE_PROFILE_NAME ]]; then
[[ $CLAUDE_PROFILE_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  die "invalid Claude profile name: $CLAUDE_PROFILE_NAME"
[[ $CLAUDE_PROFILE_NAME != official-api || $CLAUDE_CONNECTION == official-api ]] ||
  die "reserved Claude profile name: official-api"
fi
```

把配置解析和验证封装为 `resolve_claude_connection`。该函数在发现原始
checkout 后、执行 `create_isolated_worktree` 前调用；因此配置根目录永远
相对用户发起命令的 checkout 校验，不会因为 `--isolated` 改写
`CHECKOUT_ROOT` 而绕过：

```bash
resolve_claude_connection() {
  local expected_profile profile_dir

CONFIG_ROOT=${DOCKER_AGENT_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent}
install -d -m 700 "$CONFIG_ROOT/claude/profiles"
CONFIG_ROOT=$(cd "$CONFIG_ROOT" && pwd -P)
path_is_within "$CONFIG_ROOT" "$CHECKOUT_ROOT" &&
  die "docker-agent config home must not be inside the checkout"

case $CLAUDE_CONNECTION in
  official-api)
    expected_profile="$CONFIG_ROOT/claude/profiles/official-api.env"
    profile_dir=$(cd "$(dirname "$expected_profile")" && pwd -P)
    CLAUDE_PROFILE_PATH="$profile_dir/$(basename "$expected_profile")"
    path_is_within "$CLAUDE_PROFILE_PATH" "$CONFIG_ROOT" ||
      die "Claude profile resolves outside docker-agent config home"
    path_is_within "$CLAUDE_PROFILE_PATH" "$CHECKOUT_ROOT" &&
      die "Claude profile must not be inside the checkout"
    validate_claude_profile "$CLAUDE_PROFILE_PATH" official-api
    ;;
  profile:*)
    expected_profile="$CONFIG_ROOT/claude/profiles/$CLAUDE_PROFILE_NAME.env"
    profile_dir=$(cd "$(dirname "$expected_profile")" && pwd -P)
    CLAUDE_PROFILE_PATH="$profile_dir/$(basename "$expected_profile")"
    path_is_within "$CLAUDE_PROFILE_PATH" "$CONFIG_ROOT" ||
      die "Claude profile resolves outside docker-agent config home"
    path_is_within "$CLAUDE_PROFILE_PATH" "$CHECKOUT_ROOT" &&
      die "Claude profile must not be inside the checkout"
    validate_claude_profile "$CLAUDE_PROFILE_PATH" custom
    ;;
esac
}
```

`DOCKER_ARGS` 初始化后再加入 profile mount；profile 的路径和内容已经在
创建 isolated worktree 前验证完毕：

```bash
if [[ -n ${CLAUDE_PROFILE_PATH:-} ]]; then
  reject_mount_comma "$CLAUDE_PROFILE_PATH"
  DOCKER_ARGS+=(--mount "type=bind,source=$CLAUDE_PROFILE_PATH,target=/run/docker-agent/claude-profile.env,readonly")
  DOCKER_ARGS+=(--env "DOCKER_AGENT_CLAUDE_PROFILE_FILE=/run/docker-agent/claude-profile.env")
fi
DOCKER_ARGS+=(--env "DOCKER_AGENT_CLAUDE_CONNECTION=$CLAUDE_CONNECTION")
```

subscription 只加入 connection env。

Task 3 暂时要求显式 selector。参数解析、初始 `CHECKOUT_ROOT` 规范化后执行：

```bash
if [[ $AGENT == claude ]]; then
  [[ -n $CLAUDE_CONNECTION ]] ||
    die "Claude connection requires --official-subscription, --official-api, or --profile NAME"
  resolve_claude_connection
fi
```

- [ ] **Step 6: 运行 Claude 和全部 shell 测试**

Run:

```bash
tests/claude_launcher_test.bash
tests/run.bash
for script in docker-agent tests/*.bash; do
  bash -n "$script"
done
shellcheck -x -P . docker-agent tests/*.bash
```

Expected: 两套 launcher 测试及 entrypoint 测试全部 PASS，静态检查为 0。

- [ ] **Step 7: 提交 profile 和直连功能**

```bash
git add docker-agent tests/testlib.bash tests/run.bash tests/claude_launcher_test.bash
git commit -m "feat: add Claude connection profiles" \
  -m "Co-Authored-By: Codex GPT-5.6-Sol <noreply@openai.com>"
```

---

### Task 4: 隔离 Claude state 并挂载 OAuth 凭证

**Files:**
- Modify: `docker-agent`
- Modify: `tests/claude_launcher_test.bash`
- Modify: `tests/testlib.bash`

**Interfaces:**
- Consumes: Task 3 的 `CLAUDE_CONNECTION` 和 profile 选择结果。
- Produces:
  - `slug_for RAW FALLBACK`
  - `path_hash_for CANONICAL_PATH`
  - `validate_owned_mode_600_file FILE LABEL`
  - `ensure_state_identity STATE_DIR CONNECTION_ID`
  - `/claude-state` mount
  - `CLAUDE_CONFIG_DIR=/claude-state`
  - subscription credential mount `/claude-state/.credentials.json`。

- [ ] **Step 1: 写 state identity 和 OAuth 失败测试**

让通用测试 fixture 提供一份合法的订阅 credential，同时允许单个测试通过
`CLAUDE_CONFIG_DIR=...` 覆盖：

```bash
# prepare_fake_runtime:
TEST_CLAUDE_HOME="$base/host claude"
install -d -m 700 "$TEST_CLAUDE_HOME"
printf '%s\n' '{"test":"credential"}' >"$TEST_CLAUDE_HOME/.credentials.json"
chmod 600 "$TEST_CLAUDE_HOME/.credentials.json"

# run_named_launcher:
local host_claude_home=${CLAUDE_CONFIG_DIR:-$TEST_CLAUDE_HOME}
# 加入命令环境：
CLAUDE_CONFIG_DIR="$host_claude_home"
```

在 `tests/claude_launcher_test.bash` 增加：

```bash
test_same_named_repositories_and_worktrees_get_distinct_state() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo_a="$TEST_TMP/a/test"
  local repo_b="$TEST_TMP/b/test"
  local state_a state_b
  make_repo "$repo_a"
  make_repo "$repo_b"
  prepare_fake_runtime "$TEST_TMP"

  run_named_launcher "$repo_a" "$ROOT" docker-agent \
    claude --official-subscription -- --version
  state_a=$(grep -F 'target=/claude-state>' "$TEST_DOCKER_LOG")

  : >"$TEST_DOCKER_LOG"
  run_named_launcher "$repo_b" "$ROOT" docker-agent \
    claude --official-subscription -- --version
  state_b=$(grep -F 'target=/claude-state>' "$TEST_DOCKER_LOG")

  [[ $state_a != "$state_b" ]] ||
    fail "same-named repositories shared Claude state"
}

test_subscription_mounts_only_host_credential_file() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo"
  local claude_home="$TEST_TMP/host claude"
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  install -d -m 700 "$claude_home"
  printf '%s\n' '{"test":"credential"}' >"$claude_home/.credentials.json"
  chmod 600 "$claude_home/.credentials.json"

  CLAUDE_CONFIG_DIR=$claude_home \
    run_named_launcher "$repo" "$ROOT" docker-agent \
      claude --official-subscription -- --version

  assert_line "<type=bind,source=$claude_home/.credentials.json,target=/claude-state/.credentials.json>" \
    "$TEST_DOCKER_LOG"
  assert_no_line "<type=bind,source=$claude_home,target=/claude-state>" \
    "$TEST_DOCKER_LOG"
  assert_line "<CLAUDE_CONFIG_DIR=/claude-state>" "$TEST_DOCKER_LOG"
}
```

再增加测试覆盖：

- 同一 common directory 的 linked worktree 共享 repo ID 但 state mount 不同；
- `official-subscription`、`official-api`、`profile:deepseek` state 不同；
- identity 文件内容不一致时在 Docker 前失败；
- profile 改内容但不改名称时复用 state；
- macOS `--official-subscription` 输出 Keychain 限制；
- credential 缺失、symlink、错误 owner/mode 时失败。

- [ ] **Step 2: 运行测试确认失败**

Run:

```bash
tests/claude_launcher_test.bash
```

Expected: FAIL，因为 `/claude-state` 和 credential mount 尚未实现。

- [ ] **Step 3: 实现可读且稳定的路径身份**

加入：

```bash
slug_for() {
  local raw=$1 fallback=$2 slug
  slug=$(LC_ALL=C printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-48)
  [[ -n $slug ]] || slug=$fallback
  printf '%s\n' "$slug"
}

path_hash_for() {
  printf '%s' "$1" | git hash-object --stdin | cut -c1-16
}
```

repo slug 对普通/linked worktree 使用 common directory 的父目录名；对
submodule common directory 使用其 basename：

```bash
if [[ $(basename "$COMMON_DIR") == .git ]]; then
  repo_name=$(basename "$(dirname "$COMMON_DIR")")
else
  repo_name=$(basename "$COMMON_DIR")
fi
repo_id="$(slug_for "$repo_name" repo)-$(path_hash_for "$COMMON_DIR")"
worktree_id="$(slug_for "$(basename "$CHECKOUT_ROOT")" worktree)-$(path_hash_for "$CHECKOUT_ROOT")"
```

- [ ] **Step 4: 先验证订阅凭证，再实现 identity metadata**

先加入 credential metadata validator：

```bash
validate_owned_mode_600_file() {
  local file=$1 label=$2
  [[ -e $file ]] || die "$label does not exist: $file"
  [[ ! -L $file ]] || die "$label must not be a symlink: $file"
  [[ -f $file ]] || die "$label must be a regular file: $file"
  [[ $(file_uid "$file") == "$(id -u)" ]] ||
    die "$label must be owned by the current user: $file"
  [[ $(file_mode "$file") == 600 ]] ||
    die "$label must have mode 600: $file"
}
```

在创建 state 目录前完成平台判断和 credential 验证：

```bash
CLAUDE_CREDENTIAL_PATH=
if [[ $CLAUDE_CONNECTION == official-subscription ]]; then
  if [[ $HOST_OS == Darwin ]]; then
    die "host Claude subscription credentials are stored in macOS Keychain; use --official-api or --profile"
  fi
  host_claude_home=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
  CLAUDE_CREDENTIAL_PATH="$host_claude_home/.credentials.json"
  validate_owned_mode_600_file \
    "$CLAUDE_CREDENTIAL_PATH" "Claude OAuth credential"
fi
```

随后使用 NUL 分隔 identity 记录，避免路径中的空白和换行产生歧义：

```bash
ensure_state_identity() {
  local state_dir=$1 connection_id=$2
  local identity="$state_dir/.docker-agent-identity"
  local expected
  expected=$(mktemp)
  printf '%s\0' \
    "$COMMON_DIR" "$CHECKOUT_ROOT" claude "$connection_id" >"$expected"

  if [[ -e $identity ]]; then
    cmp -s "$expected" "$identity" || {
      rm -f "$expected"
      die "Claude state identity does not match: $state_dir"
    }
  else
    install -m 600 "$expected" "$identity"
  fi
  rm -f "$expected"
}
```

状态根目录：

```bash
state_base="$DATA_HOME/claude/repos/$repo_id/worktrees/$worktree_id"
case $CLAUDE_CONNECTION in
  official-subscription|official-api)
    state_dir="$state_base/$CLAUDE_CONNECTION"
    ;;
  profile:*)
    state_dir="$state_base/profiles/${CLAUDE_CONNECTION#profile:}"
    ;;
esac
install -d -m 700 "$state_dir"
state_dir=$(cd "$state_dir" && pwd -P)
ensure_state_identity "$state_dir" "$CLAUDE_CONNECTION"
```

这段 state 计算必须放在 `create_isolated_worktree` 以及随后的
`COMMON_DIR`/`GIT_DIR` 刷新之后，确保 repo identity 使用 common directory，
worktree identity 使用最终实际运行的 checkout。

- [ ] **Step 5: 构造 state 和 OAuth mounts**

加入文件 mount helper：

```bash
append_file_mount() {
  local source=$1 target=$2 mode=${3:-rw}
  reject_mount_comma "$source"
  if [[ $mode == ro ]]; then
    DOCKER_ARGS+=(--mount "type=bind,source=$source,target=$target,readonly")
  else
    DOCKER_ARGS+=(--mount "type=bind,source=$source,target=$target")
  fi
}
```

Claude 总是挂载状态目录：

```bash
reject_mount_comma "$state_dir"
DOCKER_ARGS+=(--mount "type=bind,source=$state_dir,target=/claude-state")
DOCKER_ARGS+=(--env "CLAUDE_CONFIG_DIR=/claude-state")
```

订阅模式在 Linux/WSL 嵌套挂载已验证的 credential：

```bash
if [[ -n $CLAUDE_CREDENTIAL_PATH ]]; then
  append_file_mount \
    "$CLAUDE_CREDENTIAL_PATH" /claude-state/.credentials.json
fi
```

- [ ] **Step 6: 运行 state 和回归测试**

Run:

```bash
tests/claude_launcher_test.bash
tests/run.bash
```

Expected: Claude state 测试、现有 Codex/worktree 测试全部 PASS。

- [ ] **Step 7: 提交状态隔离**

```bash
git add docker-agent tests/testlib.bash tests/claude_launcher_test.bash
git commit -m "feat: isolate Claude state per worktree and connection" \
  -m "Co-Authored-By: Codex GPT-5.6-Sol <noreply@openai.com>"
```

---

### Task 5: 实现两级交互菜单

**Files:**
- Modify: `docker-agent`
- Modify: `tests/claude_launcher_test.bash`

**Interfaces:**
- Consumes: Task 3 的 profile 目录和 Task 4 的连接身份。
- Produces:
  - `menu_select PROMPT OPTION...`
  - global integer `MENU_SELECTION`
  - test hooks `DOCKER_AGENT_TEST_FORCE_TTY`、`DOCKER_AGENT_MENU_INPUT_FD`、`DOCKER_AGENT_MENU_OUTPUT_FD`。

- [ ] **Step 1: 写方向键、二级菜单和取消失败测试**

增加 helper：

```bash
run_claude_menu() {
  local repo=$1 keys=$2 menu_log=$3
  (
    exec 9<"$keys"
    exec 8>"$menu_log"
    DOCKER_AGENT_TEST_FORCE_TTY=1 \
    DOCKER_AGENT_MENU_INPUT_FD=9 \
    DOCKER_AGENT_MENU_OUTPUT_FD=8 \
      run_named_launcher "$repo" "$ROOT" docker-agent claude -- --version
  )
}
```

测试选择自定义 endpoint 后再选第二个 profile：

```bash
test_menu_selects_custom_profile_from_second_level() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local repo="$TEST_TMP/repo" keys="$TEST_TMP/keys" menu="$TEST_TMP/menu"
  local profile
  make_repo "$repo"
  prepare_fake_runtime "$TEST_TMP"
  for profile in alpha deepseek; do
    printf '%s\n' \
      "ANTHROPIC_BASE_URL=https://$profile.example.invalid/anthropic" \
      "ANTHROPIC_AUTH_TOKEN=$profile-secret" \
      >"$TEST_AGENT_CONFIG_HOME/claude/profiles/$profile.env"
    chmod 600 "$TEST_AGENT_CONFIG_HOME/claude/profiles/$profile.env"
  done
  printf '\033[B\033[B\n\033[B\n' >"$keys"

  run_claude_menu "$repo" "$keys" "$menu"

  assert_line "<DOCKER_AGENT_CLAUDE_CONNECTION=profile:deepseek>" \
    "$TEST_DOCKER_LOG"
  assert_contains "请选择 Claude Code 的连接方式" "$menu"
  assert_contains "alpha" "$menu"
  assert_contains "deepseek" "$menu"
}
```

增加：

- 顶层第一项选择订阅；
- 顶层第二项选择官方 API；
- `k`/`j` 与方向键行为相同；
- Escape 和 Ctrl-C 退出 130；
- 取消时没有 `docker run`、没有 isolated worktree、没有 state 目录；
- 没有 custom profile 时给出 profile 路径；
- 非 TTY 且无 selector 时列出三个直接参数。

- [ ] **Step 2: 运行测试确认失败**

Run:

```bash
tests/claude_launcher_test.bash
```

Expected: FAIL，因为当前无 selector 时只会报错。

- [ ] **Step 3: 实现可注入 I/O 的菜单函数**

```bash
menu_select() {
  local prompt=$1
  shift
  local options=("$@")
  local index=0 key rest i
  local input_fd=${DOCKER_AGENT_MENU_INPUT_FD:-0}
  local output_fd=${DOCKER_AGENT_MENU_OUTPUT_FD:-1}

  while :; do
    printf '\033[2J\033[H%s\n\n' "$prompt" >&"$output_fd"
    for ((i = 0; i < ${#options[@]}; i++)); do
      if ((i == index)); then
        printf '❯ %s\n' "${options[i]}" >&"$output_fd"
      else
        printf '  %s\n' "${options[i]}" >&"$output_fd"
      fi
    done
    printf '\n↑/↓ 选择 · Enter 确认 · Esc 取消\n' >&"$output_fd"

    IFS= read -rsn1 key <&"$input_fd" || return 130
    case $key in
      $'\n'|'')
        MENU_SELECTION=$index
        return 0
        ;;
      j)
        index=$(((index + 1) % ${#options[@]}))
        ;;
      k)
        index=$(((index + ${#options[@]} - 1) % ${#options[@]}))
        ;;
      $'\e')
        rest=
        IFS= read -rsn2 -t 1 rest <&"$input_fd" || {
          return 130
        }
        case $rest in
          '[A') index=$(((index + ${#options[@]} - 1) % ${#options[@]})) ;;
          '[B') index=$(((index + 1) % ${#options[@]})) ;;
          *) return 130 ;;
        esac
        ;;
    esac
  done
}
```

如果 Bash 3.2 的 `read -t` 行为与测试不一致，保持整数 `1` 秒 timeout，
不得改用 Bash 4 特性或外部 `fzf`/`dialog`。

- [ ] **Step 4: 在任何有副作用之前选择连接方式**

参数解析、`--help` 和初始 Git checkout 的只读发现完成后立即进行菜单选择，
早于 Docker 检查以及 isolated worktree、profile/state 目录创建。此处的
`CONFIG_ROOT` 只计算字面路径供二级菜单读取，不创建目录；选定连接后仍由
Task 3 的 `resolve_claude_connection` 完成规范化和安全校验：

```bash
if [[ $AGENT == claude && -z $CLAUDE_CONNECTION ]]; then
  CONFIG_ROOT=${DOCKER_AGENT_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent}
  if [[ -z ${DOCKER_AGENT_TEST_FORCE_TTY:-} && (! -t 0 || ! -t 1) ]]; then
    die "non-interactive Claude launch requires --official-subscription, --official-api, or --profile NAME"
  fi
  menu_select "请选择 Claude Code 的连接方式：" \
    "Anthropic 官方订阅 / OAuth" \
    "Anthropic 官方 API key" \
    "自定义 endpoint" || exit 130
  case $MENU_SELECTION in
    0) CLAUDE_CONNECTION=official-subscription ;;
    1) CLAUDE_CONNECTION=official-api ;;
    2) choose_custom_profile_menu ;;
  esac
fi
```

`choose_custom_profile_menu` 使用 Bash 3.2 indexed array 和临时文件稳定排序：

```bash
choose_custom_profile_menu() {
  local profile_file profile_name sort_file
  local profile_names=()
  sort_file=$(mktemp)

  shopt -s nullglob
  for profile_file in "$CONFIG_ROOT"/claude/profiles/*.env; do
    profile_name=$(basename "$profile_file" .env)
    [[ $profile_name == official-api ]] && continue
    printf '%s\n' "$profile_name" >>"$sort_file"
  done
  shopt -u nullglob

  if [[ ! -s $sort_file ]]; then
    rm -f "$sort_file"
    die "no custom Claude profiles found in $CONFIG_ROOT/claude/profiles"
  fi
  while IFS= read -r profile_name; do
    profile_names+=("$profile_name")
  done < <(LC_ALL=C sort "$sort_file")
  rm -f "$sort_file"

  menu_select "请选择自定义 endpoint profile：" "${profile_names[@]}" ||
    return 130
  CLAUDE_PROFILE_NAME=${profile_names[MENU_SELECTION]}
  CLAUDE_CONNECTION="profile:$CLAUDE_PROFILE_NAME"
}
```

- [ ] **Step 5: 运行菜单、shell 和静态测试**

Run:

```bash
tests/claude_launcher_test.bash
tests/run.bash
for script in docker-agent tests/*.bash; do
  bash -n "$script"
done
shellcheck -x -P . docker-agent tests/*.bash
```

Expected: 全部 PASS。

- [ ] **Step 6: 提交交互菜单**

```bash
git add docker-agent tests/claude_launcher_test.bash
git commit -m "feat: add interactive Claude connection menu" \
  -m "Co-Authored-By: Codex GPT-5.6-Sol <noreply@openai.com>"
```

---

### Task 6: 在 entrypoint 配置 Claude 环境并安全加载 profile

**Files:**
- Modify: `container-entrypoint:4-71`
- Modify: `tests/entrypoint_test.bash:8-246`
- Modify: `agent-notes.md:1-19`
- Modify: `tests/image_test.bash`

**Interfaces:**
- Consumes:
  - `DOCKER_AGENT_CLAUDE_CONNECTION`
  - 可选 `DOCKER_AGENT_CLAUDE_PROFILE_FILE`
  - `CLAUDE_CONFIG_DIR=/claude-state`
  - 镜像文件 `/usr/local/share/docker-agent/agent-notes.md`。
- Produces:
  - `load_claude_profile FILE KIND`
  - Claude policy/locale environment
  - 最终命令 `claude --dangerously-skip-permissions --append-system-prompt-file FILE [ARGS...]`。

- [ ] **Step 1: 扩展 fake command 并写失败测试**

在 `make_fake_system_commands` 中创建 `claude` symlink：

```bash
for command in getent groupadd useradd usermod mkdir chown gosu codex claude custom-command; do
  ln -s fake-command "$fake_bin/$command"
done
```

fake `claude` 只记录 secret 是否存在，不记录 value：

```bash
claude)
  printf '<ENV_ANTHROPIC_BASE_URL:%s>\n' "${ANTHROPIC_BASE_URL:-}" >>"$log"
  printf '<ENV_AUTH_TOKEN_SET:%s>\n' "$([[ -n ${ANTHROPIC_AUTH_TOKEN:-} ]] && printf 1 || printf 0)" >>"$log"
  printf '<ENV_API_KEY_SET:%s>\n' "$([[ -n ${ANTHROPIC_API_KEY:-} ]] && printf 1 || printf 0)" >>"$log"
  printf '<ENV_TZ:%s>\n' "${TZ:-}" >>"$log"
  printf '<ENV_LANG:%s>\n' "${LANG:-}" >>"$log"
  printf '<ENV_LC_ALL:%s>\n' "${LC_ALL:-}" >>"$log"
  printf '<ENV_LANGUAGE:%s>\n' "${LANGUAGE:-}" >>"$log"
  printf '<ENV_DISABLE_AUTOUPDATER:%s>\n' "${DISABLE_AUTOUPDATER:-}" >>"$log"
  printf '<ENV_DISABLE_TELEMETRY:%s>\n' "${DISABLE_TELEMETRY:-}" >>"$log"
  printf '<ENV_DISABLE_ERROR_REPORTING:%s>\n' "${DISABLE_ERROR_REPORTING:-}" >>"$log"
  printf '<ENV_DISABLE_FEEDBACK_COMMAND:%s>\n' "${DISABLE_FEEDBACK_COMMAND:-}" >>"$log"
  printf '<ENV_DISABLE_FEEDBACK_SURVEY:%s>\n' "${CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY:-}" >>"$log"
  exit "${FAKE_FINAL_STATUS:-0}"
  ;;
```

增加测试：

```bash
test_claude_profile_policy_locale_and_arguments_are_applied() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local fake_bin="$TEST_TMP/bin" log="$TEST_TMP/system.log"
  local profile="$TEST_TMP/deepseek.env" notes="$TEST_TMP/agent-notes.md"
  : >"$log"
  make_fake_system_commands "$fake_bin"
  printf '%s\n' \
    'ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic' \
    'ANTHROPIC_AUTH_TOKEN=entrypoint-secret' \
    'CLAUDE_CODE_EFFORT_LEVEL=max' >"$profile"
  chmod 600 "$profile"
  printf 'container facts only\n' >"$notes"

  DOCKER_AGENT_CLAUDE_CONNECTION=profile:deepseek \
  DOCKER_AGENT_CLAUDE_PROFILE_FILE=$profile \
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
  assert_line "<ENV_TZ:Etc/UTC>" "$log"
  assert_line "<ENV_LANG:en_US.UTF-8>" "$log"
  assert_line "<ENV_LC_ALL:en_US.UTF-8>" "$log"
  assert_line "<ENV_LANGUAGE:en_US:en>" "$log"
  assert_line "<ENV_DISABLE_AUTOUPDATER:1>" "$log"
  assert_line "<ENV_DISABLE_TELEMETRY:1>" "$log"
  assert_line "<ENV_DISABLE_ERROR_REPORTING:1>" "$log"
  assert_line "<ENV_DISABLE_FEEDBACK_COMMAND:1>" "$log"
  assert_line "<ENV_DISABLE_FEEDBACK_SURVEY:1>" "$log"
  assert_no_line "<entrypoint-secret>" "$log"
}
```

增加测试覆盖：每个白名单 key、未知/重复/conflicting key、字面 command
substitution 不执行、official-api 契约、profile 不存在、notes 不存在、
Codex notes 兼容、Claude 退出码保持。

在 `tests/image_test.bash` 增加真实 entrypoint/runtime smoke test。通过 bind
一个名为 `claude` 的只读 probe，避免发起网络推理，同时验证最终 `gosu`
身份和 Claude 专属环境：

```bash
test_claude_runtime_is_non_root_utc_and_en_us() {
  local TEST_TMP
  TEST_TMP=$(new_tmp)
  local probe_dir="$TEST_TMP/probe"
  install -d -m 755 "$probe_dir"
  install -m 755 /dev/null "$probe_dir/claude"
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
    '[[ $(date "+%Z %z") == "UTC +0000" ]]' >"$probe_dir/claude"

  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    --env DOCKER_AGENT_CLAUDE_CONNECTION=official-subscription \
    --env CLAUDE_CONFIG_DIR=/tmp/claude-state \
    --env PATH=/probe:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    --mount "type=bind,source=$probe_dir,target=/probe,readonly" \
    "$IMAGE" claude
}
```

- [ ] **Step 2: 运行 entrypoint 测试确认失败**

Run:

```bash
tests/entrypoint_test.bash
```

Expected: FAIL，因为 entrypoint 尚未识别 Claude。

- [ ] **Step 3: 实现容器内 profile parser**

在 `container-entrypoint` 增加完整的二次验证和 parser。它先验证整份文件，
再导出 assignment，任何错误只输出文件路径或 key 名，不输出 value：

```bash
array_contains() {
  local needle=$1 item
  shift
  for item in "$@"; do
    [[ $item == "$needle" ]] && return 0
  done
  return 1
}

load_claude_profile() {
  local file=$1 kind=$2
  local line key value assignment
  local seen_keys=() assignments=()
  local has_base=0 has_auth_token=0 has_api_key=0

  [[ -e $file ]] || {
    printf 'docker-agent: Claude profile does not exist: %s\n' "$file" >&2
    return 1
  }
  [[ ! -L $file && -f $file ]] || {
    printf 'docker-agent: Claude profile must be a regular non-symlink file: %s\n' "$file" >&2
    return 1
  }
  [[ $(stat -c %u "$file") == "$HOST_UID" ]] || {
    printf 'docker-agent: Claude profile has unexpected owner: %s\n' "$file" >&2
    return 1
  }
  [[ $(stat -c %a "$file") == 600 ]] || {
    printf 'docker-agent: Claude profile must have mode 600: %s\n' "$file" >&2
    return 1
  }

  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    [[ $line =~ ^[[:space:]]*# ]] && continue
    [[ $line == *=* ]] || {
      printf '%s\n' 'docker-agent: invalid Claude profile assignment' >&2
      return 1
    }
    key=${line%%=*}
    value=${line#*=}
    [[ $key =~ ^[A-Z][A-Z0-9_]*$ ]] || {
      printf 'docker-agent: invalid Claude profile key: %s\n' "$key" >&2
      return 1
    }
    if array_contains "$key" "${seen_keys[@]}"; then
      printf 'docker-agent: duplicate Claude profile key: %s\n' "$key" >&2
      return 1
    fi
    seen_keys+=("$key")

    case $key in
      ANTHROPIC_BASE_URL)
        [[ -n $value ]] || {
          printf '%s\n' 'docker-agent: empty ANTHROPIC_BASE_URL' >&2
          return 1
        }
        has_base=1
        ;;
      ANTHROPIC_AUTH_TOKEN)
        [[ -n $value ]] || {
          printf '%s\n' 'docker-agent: empty ANTHROPIC_AUTH_TOKEN' >&2
          return 1
        }
        has_auth_token=1
        ;;
      ANTHROPIC_API_KEY)
        [[ -n $value ]] || {
          printf '%s\n' 'docker-agent: empty ANTHROPIC_API_KEY' >&2
          return 1
        }
        has_api_key=1
        ;;
      ANTHROPIC_MODEL|ANTHROPIC_DEFAULT_OPUS_MODEL|ANTHROPIC_DEFAULT_SONNET_MODEL|ANTHROPIC_DEFAULT_HAIKU_MODEL|CLAUDE_CODE_SUBAGENT_MODEL)
        ;;
      CLAUDE_CODE_EFFORT_LEVEL)
        [[ $value =~ ^(low|medium|high|xhigh|max|auto)$ ]] || {
          printf '%s\n' 'docker-agent: invalid CLAUDE_CODE_EFFORT_LEVEL' >&2
          return 1
        }
        ;;
      *)
        printf 'docker-agent: unsupported Claude profile key: %s\n' "$key" >&2
        return 1
        ;;
    esac
    assignments+=("$key=$value")
  done <"$file"

  if [[ $kind == official-api ]]; then
    ((has_api_key == 1 && has_auth_token == 0 && has_base == 0)) || {
      printf '%s\n' 'docker-agent: official API profile requires only ANTHROPIC_API_KEY' >&2
      return 1
    }
  else
    ((has_base == 1 && has_auth_token + has_api_key == 1)) || {
      printf '%s\n' 'docker-agent: custom profile requires endpoint and exactly one credential' >&2
      return 1
    }
  fi

  for assignment in "${assignments[@]}"; do
    export "$assignment"
  done
}
```

- [ ] **Step 4: 设置 Claude 专属环境与最终参数**

在 `if [[ ${1:-} == codex ]]` 之后增加独立 Claude 分支：

```bash
elif [[ ${1:-} == claude ]]; then
  connection=${DOCKER_AGENT_CLAUDE_CONNECTION:?Claude connection is required}
  if [[ -n ${DOCKER_AGENT_CLAUDE_PROFILE_FILE:-} ]]; then
    case $connection in
      official-api) profile_kind=official-api ;;
      profile:*) profile_kind=custom ;;
      *) printf '%s\n' 'docker-agent: unexpected Claude profile connection' >&2; exit 1 ;;
    esac
    load_claude_profile "$DOCKER_AGENT_CLAUDE_PROFILE_FILE" "$profile_kind"
  fi

  export TZ=Etc/UTC
  export LANG=en_US.UTF-8
  export LC_ALL=en_US.UTF-8
  export LANGUAGE=en_US:en
  export DISABLE_AUTOUPDATER=1
  export DISABLE_TELEMETRY=1
  export DISABLE_ERROR_REPORTING=1
  export DISABLE_FEEDBACK_COMMAND=1
  export CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1

  agent_notes=${DOCKER_AGENT_AGENT_NOTES:-/usr/local/share/docker-agent/agent-notes.md}
  if [[ -r $agent_notes ]]; then
    set -- claude --dangerously-skip-permissions \
      --append-system-prompt-file "$agent_notes" "${@:2}"
  else
    set -- claude --dangerously-skip-permissions "${@:2}"
  fi
fi
```

Codex notes 使用新路径并兼容旧 override：

```bash
agent_notes=${DOCKER_AGENT_AGENT_NOTES:-${DOCKER_CODEX_AGENT_NOTES:-/usr/local/share/docker-agent/agent-notes.md}}
```

更新 `agent-notes.md` 标题为中立的 docker-agent 环境说明，正文不加入
语言、人格、endpoint 或模型指令。

- [ ] **Step 5: 运行 entrypoint、image 和全量 shell 测试**

Run:

```bash
tests/entrypoint_test.bash
tests/run.bash
DOCKER_AGENT_TEST_IMAGE=docker-agent:local tests/image_test.bash
for script in container-entrypoint tests/*.bash; do
  bash -n "$script"
done
shellcheck -x -P . container-entrypoint tests/*.bash
```

Expected: 全部 PASS。

- [ ] **Step 6: 提交 entrypoint 集成**

```bash
git add container-entrypoint agent-notes.md tests/entrypoint_test.bash tests/image_test.bash
git commit -m "feat: configure Claude container runtime" \
  -m "Co-Authored-By: Codex GPT-5.6-Sol <noreply@openai.com>"
```

---

### Task 7: 更新公开帮助和中英文文档

**Files:**
- Modify: `README.md`
- Modify: `README.en.md`
- Create: `docs/zh/claude.md`
- Create: `docs/en/claude.md`
- Modify: `docs/zh/credentials.md`
- Modify: `docs/en/credentials.md`
- Modify: `docs/zh/environment.md`
- Modify: `docs/en/environment.md`
- Modify: `docs/zh/platforms.md`
- Modify: `docs/en/platforms.md`
- Modify: `docs/zh/security.md`
- Modify: `docs/en/security.md`
- Modify: `docs/zh/development.md`
- Modify: `docs/en/development.md`
- Modify: `tests/launcher_test.bash`
- Modify: `tests/claude_launcher_test.bash`

**Interfaces:**
- Consumes: Tasks 1-6 的最终命令、路径、选项和限制。
- Produces: 用户可以仅依靠 README/help/Claude 专题文档完成构建、认证、
  profile 配置、状态清理和安全评估。

- [ ] **Step 1: 先更新 help 契约测试**

Codex help 必须继续包含现有选项；增加 canonical 和 Claude help 检查：

```bash
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
}
```

- [ ] **Step 2: 运行 help 测试确认文档契约缺失**

Run:

```bash
tests/launcher_test.bash
```

Expected: FAIL，直到 usage 文本完整描述新接口。

- [ ] **Step 3: 更新中英文 README 快速入口**

README 必须包含以下可复制命令：

```bash
sudo install -m 0755 ./docker-agent /usr/local/bin/docker-agent
sudo install -m 0755 ./docker-agent /usr/local/bin/docker-codex
sudo install -m 0755 ./docker-agent /usr/local/bin/docker-claude

docker-agent codex
docker-agent claude
docker-agent claude --profile deepseek
```

命令选项块区分公共选项、Codex 参数和三个 Claude 连接参数。说明无 selector
时显示菜单，非 TTY 必须使用显式参数。

- [ ] **Step 4: 编写 Claude 专题文档**

`docs/zh/claude.md` 和 `docs/en/claude.md` 必须逐项包含：

- 顶层菜单和 custom profile 二级菜单；
- 三个直接参数；
- `official-api.env` 的完整最小示例；
- DeepSeek profile 的完整示例；
- config/data root 和 `repo/worktree/connection` 状态树；
- `0600`/`0700` 创建命令；
- Linux/WSL `.credentials.json` 单文件读写挂载；
- macOS Keychain 不可复用；
- UTC、`en_US.UTF-8` 和五个独立策略变量；
- profile secret 对选中容器可读；
- state/profile 清理命令只删除精确目录，不使用递归宽路径示例。

profile 创建示例：

```bash
profile_root="${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent/claude/profiles"
install -d -m 700 "$profile_root"
install -m 600 /dev/null "$profile_root/deepseek.env"
"${EDITOR:-vi}" "$profile_root/deepseek.env"
```

- [ ] **Step 5: 更新现有参考文档和开发验证**

在 credentials/environment/platforms/security 中交叉链接 Claude 专题，
并分别说明认证文件、状态、macOS、profile secret 与关闭内部审批的边界。

development 文档固定使用：

```bash
docker build --check .
docker build -t docker-agent:local .
tests/run.bash
DOCKER_AGENT_TEST_IMAGE=docker-agent:local tests/image_test.bash
```

- [ ] **Step 6: 运行 help、shell 和链接引用检查**

Run:

```bash
tests/run.bash
rg -n 'docker-codex:local|DOCKER_CODEX_TEST_IMAGE' README.md README.en.md docs/zh docs/en
git diff --check
```

Expected: tests PASS；`rg` 只允许出现在明确标注的 legacy compatibility
段落，否则逐项改为 `docker-agent:local` 或 `DOCKER_AGENT_TEST_IMAGE`。

- [ ] **Step 7: 提交文档**

```bash
git add README.md README.en.md docs/zh docs/en tests/launcher_test.bash tests/claude_launcher_test.bash docker-agent
git commit -m "docs: document Claude Code integration" \
  -m "Co-Authored-By: Codex GPT-5.6-Sol <noreply@openai.com>"
```

---

### Task 8: 完整验证和真实 OAuth 验收

**Files:**
- Verify: `docker-agent`
- Verify: `container-entrypoint`
- Verify: `Dockerfile`
- Verify: `tests/*.bash`
- Verify: `README.md`
- Verify: `README.en.md`
- Verify: `docs/zh/*.md`
- Verify: `docs/en/*.md`

**Interfaces:**
- Consumes: Tasks 1-7 的完整实现。
- Produces: shell、Dockerfile、fresh image、真实 WSL/Linux OAuth 写入和三种
  连接方式的验收证据。

- [ ] **Step 1: 运行完整 shell 验证**

Run:

```bash
for script in docker-agent docker-codex docker-claude container-entrypoint container-powershell-shim tests/*.bash; do
  bash -n "$script"
done
shellcheck -x -P . docker-agent container-entrypoint container-powershell-shim tests/*.bash
tests/run.bash
git diff --check
```

Expected: 语法、ShellCheck、launcher、Claude launcher、entrypoint 全部
以状态码 0 结束。

- [ ] **Step 2: 构建并验证 fresh image**

Run:

```bash
docker build --check .
docker build --no-cache --tag docker-agent:local .
DOCKER_AGENT_TEST_IMAGE=docker-agent:local tests/image_test.bash
```

Expected: Dockerfile 无 warning；fresh build 成功；`image tests: PASS`。

然后用 OCI exporter 验证两个目标架构都能完成全量 Dockerfile 构建：

```bash
multiarch_dir=$(mktemp -d)
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --output "type=oci,dest=$multiarch_dir/docker-agent.tar" \
  .
rm -r "$multiarch_dir"
```

Expected: amd64 和 arm64 均完成 Codex、Claude 及工具链安装，不出现
unsupported architecture 或 npm binary 错误。

- [ ] **Step 3: 检查 secret 不进入 Docker inspect**

创建一个不连接网络的 custom profile：

```bash
profile_root="${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent/claude/profiles"
install -d -m 700 "$profile_root"
test_profile="$profile_root/inspect-test.env"
printf '%s\n' \
  'ANTHROPIC_BASE_URL=https://example.invalid/anthropic' \
  'ANTHROPIC_AUTH_TOKEN=inspect-only-secret' >"$test_profile"
chmod 600 "$test_profile"
```

用 fake Docker 测试已经证明参数不含 secret；再运行：

```bash
tests/claude_launcher_test.bash
```

Expected: 测试日志中不存在 `inspect-only-secret`。随后删除该精确测试文件：

```bash
rm "$test_profile"
```

- [ ] **Step 4: 使用专用测试登录验证 OAuth 单文件写入**

不要使用主 `~/.claude` 做 `/logout`/`/login` 测试。创建专用配置目录：

```bash
oauth_test_home=$(mktemp -d)
chmod 700 "$oauth_test_home"
CLAUDE_CONFIG_DIR="$oauth_test_home" claude
```

在宿主 Claude 中完成测试账号登录后，确认：

```bash
test -f "$oauth_test_home/.credentials.json"
test "$(stat -c %a "$oauth_test_home/.credentials.json")" = 600
```

通过容器复用：

```bash
CLAUDE_CONFIG_DIR="$oauth_test_home" \
  docker-agent claude --official-subscription
```

在容器 Claude 中依次执行 `/status`、`/logout`、`/login`，重新登录该测试
账号，然后发送只要求回复 `OK` 的提示。退出后在宿主再次执行：

```bash
CLAUDE_CONFIG_DIR="$oauth_test_home" claude
```

Expected: 宿主仍识别更新后的登录状态，证明单文件 bind mount 支持 Claude
实际凭证写入。若任一步出现只读、`EBUSY`、无法替换或刷新失败，停止交付，
不得改为完整挂载 `~/.claude`；返回设计阶段选择新的凭证同步契约。

测试完成后只删除专用目录：

```bash
rm -r "$oauth_test_home"
```

- [ ] **Step 5: 验证官方 API 与用户 DeepSeek profile**

使用实际 `0600` profile 分别执行：

```bash
docker-agent claude --official-api -- -p "Reply with exactly OK"
docker-agent claude --profile deepseek -- -p "Reply with exactly OK"
```

Expected: 两次都只输出成功响应；`/status` 或启动信息显示正确 provider/model，
没有把 profile value 打印到终端。

- [ ] **Step 6: 验证状态隔离和容器环境**

在同一 worktree 分别启动三种方式并创建可识别 session，然后验证各自
`--continue` 只恢复本连接方式的 session：

```bash
docker-agent claude --official-subscription -- --continue
docker-agent claude --official-api -- --continue
docker-agent claude --profile deepseek -- --continue
```

使用真实镜像的默认 entrypoint 验证 Claude 命令路径：

```bash
docker run --rm \
  --env HOST_UID="$(id -u)" \
  --env HOST_GID="$(id -g)" \
  --env DOCKER_AGENT_CLAUDE_CONNECTION=official-subscription \
  --env CLAUDE_CONFIG_DIR=/tmp/claude-state \
  docker-agent:local \
  claude --version
```

Expected: 输出固定版本 `2.1.212`。Claude 专属 locale/策略值以及 Codex
分支未收到这些值，均由 `tests/entrypoint_test.bash` 的 fake-command 日志
断言，避免为了观察环境而改变生产 entrypoint 行为。

- [ ] **Step 7: 最终仓库检查**

Run:

```bash
git status --short --branch
git log --oneline --decorate -10
```

Expected: 工作区干净，所有 feature/test/docs commit 可见。若验证过程中产生
代码修复，重新执行 Steps 1-6 后提交：

```bash
git add docker-agent docker-codex docker-claude container-entrypoint Dockerfile agent-notes.md tests README.md README.en.md docs
git commit -m "fix: address Claude integration verification" \
  -m "Co-Authored-By: Codex GPT-5.6-Sol <noreply@openai.com>"
```
