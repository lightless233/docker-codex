# Claude Code 集成

本文说明 Claude Code 的连接选择、profile 格式、官方订阅复用、状态隔离、
容器环境和清理方式。

## 启动与连接菜单

在交互终端直接运行：

```bash
docker-agent claude
```

顶层菜单提供：

1. Anthropic 官方订阅 / OAuth
2. Anthropic 官方 API key
3. 自定义 endpoint

第三项会打开二级菜单，列出 profile 目录中除 `official-api.env` 外的
`*.env`，按 C locale 的名称顺序排列。方向键或 `j`/`k` 移动，Enter
确认，Esc 或 Ctrl-C 取消并返回 130。菜单不记忆上次选择。每个名称后会
显示 `ANTHROPIC_MODEL` 的值；该变量为空或缺失时，即使配置了其他模型
映射，也会显示“将使用 Claude 默认模型名”的警告。菜单预览会移除控制
字符，并将超过 64 个字符的模型名截断；profile 中的实际值不会改变。

也可以直接选择连接，适合 shell alias、脚本和 CI：

```bash
docker-agent claude --official-subscription
docker-agent claude --official-api
docker-agent claude --profile deepseek
```

三个参数互斥。没有 stdin/stdout TTY 时不会显示菜单，必须显式指定其中
一个。`--` 后面的参数原样传给 Claude Code：

```bash
docker-agent claude --profile deepseek -- --version
```

## Profile 目录与权限

profile 根目录是：

```text
${DOCKER_AGENT_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent}/claude/profiles
```

推荐使用交互创建命令：

```bash
docker-claude --create-profile
```

该命令依次读取 profile 名称、API endpoint 和 API key。API key 输入显示为
星号，支持粘贴与退格，不会显示明文；创建器将其写为
`ANTHROPIC_AUTH_TOKEN`。该动作必须单独使用，但不要求当前目录是 Git
checkout，也不要求 Docker daemon 正在运行。同名 profile 已存在时拒绝
覆盖。

创建完成后会输出 profile 的绝对路径和启动命令，并在星号警示框中提醒
配置 `ANTHROPIC_MODEL`；否则 Claude Code 会向自定义 endpoint 使用默认
Claude 模型名。如需添加模型映射等其他白名单环境变量，直接编辑输出的
文件。也可以手动创建：

```bash
profile_root="${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent/claude/profiles"
install -d -m 700 "$profile_root"
install -m 600 /dev/null "$profile_root/deepseek.env"
"${EDITOR:-vi}" "$profile_root/deepseek.env"
```

profile 必须位于 checkout 外，是当前用户拥有、权限精确为 `0600` 的普通
文件，不能是符号链接。配置目录使用 `0700`。文件格式不是 shell 脚本，
不要写 `export`，也不会执行变量展开、命令替换或反斜杠转义。每个非注释
行都是 `KEY=value`，第一个 `=` 后的内容按字面值处理；值可以由一对匹配
的单引号或双引号完整包围，解析时只移除最外层这一对引号。单边或不匹配
的引号会被拒绝。

只允许以下九个键：

```text
ANTHROPIC_BASE_URL
ANTHROPIC_AUTH_TOKEN
ANTHROPIC_API_KEY
ANTHROPIC_MODEL
ANTHROPIC_DEFAULT_OPUS_MODEL
ANTHROPIC_DEFAULT_SONNET_MODEL
ANTHROPIC_DEFAULT_HAIKU_MODEL
CLAUDE_CODE_SUBAGENT_MODEL
CLAUDE_CODE_EFFORT_LEVEL
```

宿主启动器和容器 entrypoint 都会独立验证白名单、重复键和连接契约，且
不会 `source` 或 `eval` profile。

## 官方 API key

固定文件名为 `official-api.env`，最小内容如下：

```bash
profile_root="${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent/claude/profiles"
install -d -m 700 "$profile_root"
install -m 600 /dev/null "$profile_root/official-api.env"
printf '%s\n' 'ANTHROPIC_API_KEY=sk-ant-replace-me' \
  >"$profile_root/official-api.env"
```

该 profile 必须有且仅有 `ANTHROPIC_API_KEY` 这一种凭证，不能设置
`ANTHROPIC_BASE_URL` 或 `ANTHROPIC_AUTH_TOKEN`。模型相关白名单键仍可按需
加入。

## 自定义 endpoint

与问题描述一致的 DeepSeek profile 可以写成：

```text
ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
ANTHROPIC_AUTH_TOKEN=sk-123456
ANTHROPIC_MODEL=deepseek-v4-pro[1m]
ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-pro[1m]
ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-pro[1m]
ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash
CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-flash
CLAUDE_CODE_EFFORT_LEVEL=max
```

自定义 profile 必须设置 `ANTHROPIC_BASE_URL`，并在
`ANTHROPIC_AUTH_TOKEN` 与 `ANTHROPIC_API_KEY` 中恰好选择一个。凭证和模型
profile 保存在同一个 `0600` 文件中。启动时该文件只读挂载到选中的
Claude 容器，内容不会出现在 `docker run` 参数中。

## 复用官方订阅 / OAuth

Linux 与 WSL 使用宿主：

```text
${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json
```

启动器只挂载这一个认证文件，不挂载完整 `~/.claude`。文件必须由当前
用户拥有、权限精确为 `0600`、不是符号链接。它以读写方式挂载到独立
Claude state 的 `.credentials.json`，因为 Claude Code 可能刷新凭证。
会话、历史和其他状态仍保存在 docker-agent 的独立 data root。

macOS 的 Claude 订阅通常保存在 Keychain，Linux 容器无法直接复用，因此
`--official-subscription` 会拒绝启动；请使用 `--official-api` 或自定义
profile。

## 状态隔离

默认 data root 是：

```text
${DOCKER_AGENT_DATA_HOME:-${DOCKER_CODEX_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/docker-agent}}
```

Claude 状态树：

```text
<data-root>/claude/repos/
  <repo-name>-<Git-common-dir-or-synthetic-.git-path-hash>/
    worktrees/
      <worktree-name>-<checkout-path-hash>/
        official-subscription/
        official-api/
        profiles/
          <profile-name>/
```

repo 和 worktree ID 都包含规范化绝对路径的 16 位 Git object hash，所以
`/home/test` 与 `/project/test` 不会因同名冲突。plain directory 使用
`<当前目录>/.git` 作为合成 common dir；以后在原目录执行 `git init` 仍会
复用同一状态。不同 repo、worktree 和连接方式拥有不同
`CLAUDE_CONFIG_DIR`；同一组合的后续容器会复用该状态。profile 内容变化但
名称不变时也复用原状态。

每个状态目录含权限为 `0600` 的 `.docker-agent-identity`，启动器会核对
repo、checkout 和连接身份，防止路径碰撞或错误复用。

## Claude 容器环境

entrypoint 只对 Claude 进程设置：

```text
TZ=Etc/UTC
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
LANGUAGE=en_US:en
DISABLE_AUTOUPDATER=1
DISABLE_TELEMETRY=1
DISABLE_ERROR_REPORTING=1
DISABLE_FEEDBACK_COMMAND=1
CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
```

这些变量保持拆分，不从 profile 合并或覆盖。英文 locale 只改变容器的系统
语言环境，不向 Claude Code 添加“必须使用英文回答”的提示；回答语言仍由
Claude Code、项目指令和用户请求决定。

Claude 启动时固定加入 `--dangerously-skip-permissions`。镜像中的公共
agent notes 只描述容器事实，不包含回答语言、人格、endpoint 或模型指令。

## 安全与精确清理

profile secret 对选中的容器进程可读；容器用户还拥有容器内免密 sudo，
并且 Claude 自身审批已关闭。因此 profile 只应包含当前任务需要的最小
权限、可撤销凭证，不要把 profile 放进仓库。

删除一个 profile 使用精确文件路径：

```bash
profile_root="${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent/claude/profiles"
rm -- "$profile_root/deepseek.env"
```

删除某个精确状态前，先列出 identity 文件并人工确认：

```bash
data_root="${XDG_DATA_HOME:-$HOME/.local/share}/docker-agent"
find "$data_root/claude/repos" -name .docker-agent-identity -type f -print

# 把下面值替换为上一条输出对应状态目录的完整绝对路径
state_dir="/home/me/.local/share/docker-agent/claude/repos/repo-HASH/worktrees/worktree-HASH/profiles/deepseek"
rm -rf -- "$state_dir"
```

不要递归删除整个 `data_root`、`claude` 或 `repos` 根目录。删除 state 不会
删除 profile 或 OAuth 源文件；下次启动会创建空状态。

---

返回 [README](../../README.md)
