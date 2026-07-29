# Claude Code 集成设计

日期：2026-07-29

## 概要

将 docker-codex 扩展为一个多 coding agent 的 Docker 启动器：使用一个
共享开发镜像，并以 `docker-agent` 作为统一入口。第一版支持 Codex 和
Claude Code：

```text
docker-agent codex
docker-agent claude
```

Codex 保持现有行为。Claude Code 支持三种明确的连接方式：复用宿主
Anthropic 订阅登录、使用 Anthropic 官方 API key，以及通过命名 profile
连接兼容 Anthropic API 的自定义 endpoint。交互终端中没有指定连接方式时，
启动器显示可用上下键操作的菜单。

Claude 的状态不写入宿主 `~/.claude`，也不通过完整挂载该目录来共享。
session 和其他可变状态按照仓库、worktree、连接方式隔离，统一存放在
docker-agent 的 data home 中。订阅模式只共享宿主 OAuth 凭证文件。

## 目标

- 在同一个可复现镜像中安装固定版本的 Codex 和 Claude Code。
- 提供中立的统一命令，同时兼容现有 `docker-codex` 用法。
- 让 Claude Code 复用 Codex 已有的 checkout、Git metadata、worktree、
  缓存、Git 凭证、剪贴板、UID/GID 和容器隔离能力。
- 支持以下连接方式：
  - 在 Linux 和 WSL 上复用宿主 Anthropic 订阅/OAuth 登录；
  - 使用 Anthropic 官方 API key；
  - 使用兼容 Anthropic API 的命名自定义 endpoint。
- Claude session 和可变用户状态存放在宿主 `~/.claude` 之外，并在不同
  worktree 和连接方式之间隔离。
- profile 中的凭证不进入 shell 历史、Docker 环境参数、`docker inspect`
  环境输出或启动器日志。
- 使用彼此独立的环境变量关闭 Claude 的自动更新、遥测、错误上报、
  feedback 命令和反馈问卷。
- Claude 容器使用 UTC 和 `en_US.UTF-8`，但不改变 Claude 的回答语言或
  人格。

## 非目标

- 第一版不拆分 Codex 和 Claude 镜像。
- 不在容器启动时安装或升级任一 CLI。
- 不挂载完整的宿主 `~/.claude`。
- 不在不同 worktree 或连接方式之间共享 Claude session。
- 不强制 Claude 使用英文回答。
- 不实现通用 secret manager，也不允许 profile 传入任意环境变量。
- 不尝试让 Linux 容器复用 macOS Keychain 中的订阅凭证。
- 第一版不增加 Bedrock、Vertex、Foundry 或其他 provider 专用模式。

## 已选架构

### 单一镜像

使用一个 `docker-agent:local` 镜像，同时包含两个 CLI 和现有 Debian
开发工具链。在现有固定版本参数旁新增 Claude Code 版本参数。

Dockerfile 暴露 `CODEX_VERSION` 和 `CLAUDE_CODE_VERSION` 两个 build
argument，代码中的默认值必须是完整、精确的已发布版本号。升级版本需要
显式修改源码或传入 build argument，并由镜像测试覆盖。两个 npm 包在同一
层安装：

```text
@openai/codex@${CODEX_VERSION}
@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
```

不采用运行时安装，因为它会让启动依赖网络、造成版本漂移并降低 session
的可复现性。第一版不采用两个最终镜像，因为这会重复构建、发布、缓存和
测试流程，而收益不足。

### 统一分发器

标准公开接口为：

```text
docker-agent codex [公共选项] -- [Codex 参数]
docker-agent claude [公共选项] [连接选项] -- [Claude 参数]
```

分发器统一负责：

- 发现 Git checkout 和 metadata；
- 使用普通或隔离 worktree；
- 增加额外 bind mount；
- 使用每仓库构建缓存；
- 映射宿主 UID/GID；
- 为 Git push 转发 PAT；
- 转发显示和剪贴板；
- 构建或选择镜像；
- 检查 Docker daemon。

agent 专用代码只负责选择状态目录、挂载、环境变量、入口脚本设置和最终
CLI 参数。

### 兼容入口

同一份分发器可以安装为三个名称：

```text
docker-agent
docker-codex
docker-claude
```

以 `docker-agent` 调用时，第一个位置参数必须是 `codex` 或 `claude`。
以 `docker-codex` 或 `docker-claude` 调用时，脚本根据自身 basename
选择 agent，因此以下现有用法继续有效：

```text
docker-codex -- review "review the current branch"
```

`docker-claude` 等价于 `docker-agent claude`。同一脚本复制为任一名称后
都可以独立运行；使用符号链接只是便捷方式，不是必要条件。

中立的新环境变量使用 `DOCKER_AGENT_` 前缀。已有 `DOCKER_CODEX_` 变量
继续作为对应公共行为和 Codex 行为的 fallback，避免升级后静默丢失现有
用户配置。

## Claude 命令接口

### 直接连接选项

Claude 提供三个互斥的连接选择参数：

```text
--official-subscription
--official-api
--profile NAME
```

示例：

```bash
docker-agent claude --official-subscription
docker-agent claude --official-api
docker-agent claude --profile deepseek
docker-agent claude --profile deepseek -- --model opus
```

连接选择参数由 docker-agent 解析，绝不传给 Claude。`--` 后的参数原样
转发。

不采用 `--api-key` 作为选择参数，因为该名称容易让人误以为需要把 secret
直接写到命令行。`--official-api` 只选择一个固定的受保护 profile。

同时传入多个选择参数时直接报错。`--profile` 必须有值。保留名称
`official-api` 不能通过 `--profile` 选择，调用方必须使用
`--official-api`。

### 交互菜单

Claude 未指定选择参数，且 stdin、stdout 都是 TTY 时，宿主启动器显示：

```text
请选择 Claude Code 的连接方式：

❯ Anthropic 官方订阅 / OAuth
  Anthropic 官方 API key
  自定义 endpoint

↑/↓ 选择 · Enter 确认 · Esc 取消
```

菜单支持：

- 上、下方向键；
- 可选的 `j`、`k` 导航；
- Enter 确认；
- Escape 和 Ctrl-C 取消。

选择“自定义 endpoint”后，打开第二级菜单，按照稳定的字典序列出 profile
名称。保留 profile `official-api` 不出现在该菜单中。用户选中 profile 后，
必须在启动 Docker 前完成全部验证。不存在任何自定义 profile 时，启动器
退出并显示 profile 目录和简短创建示例。

顶层菜单始终保持上述三种连接类型，不记忆上一次选择，也不存在隐藏的
默认 profile。

stdin 或 stdout 任意一个不是 TTY 时，省略选择参数属于错误。错误信息列出
三种直接调用形式，确保 CI、管道和自动化流程不会等待交互输入而卡死。

## 文件布局与身份计算

### 配置目录

docker-agent 的配置根目录为：

```text
${DOCKER_AGENT_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent}
```

Claude profile 存放在：

```text
<config-root>/claude/profiles/
```

启动器以 `0700` 创建配置目录。启动器绝不从 checkout 中搜索 profile；
如果配置根目录位于 checkout 内，则拒绝启动。

### 数据目录

docker-agent 的 data root 按以下优先级确定：

1. `DOCKER_AGENT_DATA_HOME`；
2. 兼容变量 `DOCKER_CODEX_DATA_HOME`；
3. `${XDG_DATA_HOME:-$HOME/.local/share}/docker-agent`。

Claude 状态目录结构为：

```text
<data-root>/claude/
└── repos/
    └── <repo-slug>-<repo-hash>/
        └── worktrees/
            └── <worktree-slug>-<worktree-hash>/
                ├── official-subscription/
                ├── official-api/
                └── profiles/
                    └── <profile-name>/
```

选中的叶子目录以读写方式挂载到 `/claude-state`，容器设置：

```text
CLAUDE_CONFIG_DIR=/claude-state
```

这样可以按照仓库、worktree 和连接方式隔离 session、auto memory、设置、
plugin、缓存及其他 Claude 可变状态。重复启动同一 worktree 和连接方式时
复用原状态。修改命名 profile 的内容不会丢弃该 profile 的状态；重命名
profile 会选择新的状态目录。

### 避免同名路径冲突

只使用可读名称不够安全，因为 `/home/test` 和 `/project/test` 的 basename
相同。

仓库身份使用规范化的 Git common directory，worktree 身份使用规范化的
checkout root：

```text
repo_hash     = git_hash_object(canonical_common_dir)[0:16]
worktree_hash = git_hash_object(canonical_checkout_root)[0:16]
repo_id       = sanitized_repo_name + "-" + repo_hash
worktree_id   = sanitized_worktree_name + "-" + worktree_hash
```

规范路径使用物理路径语义（`pwd -P`）解析。hash 复用现有
`git hash-object --stdin` helper，因为 Git 已经是跨平台必需依赖，而
macOS 不保证存在 GNU `sha256sum`。

slug 将 `[A-Za-z0-9._-]` 之外的字符替换为 `_`，空名称使用稳定的 fallback，
并限制为 48 个字符，兼顾路径可读性。

每个状态叶子目录包含一份 identity metadata，记录规范化 common directory、
checkout 路径、agent 和连接身份。复用状态前，启动器必须比对 metadata。
任何不一致都是硬错误，从而避免即使截断 hash 发生碰撞也把不相关状态合并。

移动仓库或 worktree 后会有意产生新身份。旧状态保留供用户手动检查或删除，
启动器绝不自动迁移或清理。

## 认证

### Anthropic 订阅 / OAuth

在 Linux 和 WSL 上，宿主凭证来源为：

```text
${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json
```

启动器要求该文件是调用用户拥有、权限为 `0600` 的普通文件，并将单个文件
以读写方式挂载到：

```text
/claude-state/.credentials.json
```

宿主 Claude 目录中的其他内容不进入容器。Claude session 和其他可变状态
仍然使用隔离的 `/claude-state`。

凭证文件需要读写权限，因为 Claude Code 可能刷新 OAuth 凭证。实现必须使用
真实 Linux/WSL Claude 登录验证：通过单文件 bind mount 可以完成凭证刷新
和写入。如果该验收失败，则订阅复用功能不能视为完成；启动器不得静默回退
为挂载完整 `~/.claude`。

在 macOS 上，Claude 订阅凭证保存在 Keychain，不能通过该文件契约复用到
Linux 容器。第一版选择 `--official-subscription` 时明确说明限制，并引导
用户改用 `--official-api` 或自定义 profile；不得宣称支持 macOS 宿主订阅
复用。

### Anthropic 官方 API

`--official-api` 加载保留 profile：

```text
<config-root>/claude/profiles/official-api.env
```

最小内容：

```ini
ANTHROPIC_API_KEY=sk-ant-example
```

该 profile 可以包含允许的模型选择变量，但不允许出现
`ANTHROPIC_BASE_URL` 或 `ANTHROPIC_AUTH_TOKEN`，确保该模式始终表示
使用 API key 访问 Anthropic 官方 endpoint。

### 自定义 endpoint profile

`--profile NAME` 精确解析为：

```text
<config-root>/claude/profiles/NAME.env
```

名称必须匹配：

```text
[A-Za-z0-9][A-Za-z0-9._-]*
```

拒绝路径分隔符、路径穿越、英文逗号以及保留名称 `official-api`。拒绝符号
链接；目标必须是调用用户拥有、权限精确为 `0600` 的普通文件。

自定义 profile 必须包含：

- 非空的 `ANTHROPIC_BASE_URL`；
- `ANTHROPIC_AUTH_TOKEN` 或 `ANTHROPIC_API_KEY` 中的一个且只能有一个。

示例：

```ini
ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
ANTHROPIC_AUTH_TOKEN=sk-example
ANTHROPIC_MODEL=deepseek-v4-pro[1m]
ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-pro[1m]
ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-pro[1m]
ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash
CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-flash
CLAUDE_CODE_EFFORT_LEVEL=max
```

### Profile 格式

profile 使用刻意缩小的 `.env` 子集：

- 忽略空行；
- 第一个非空白字符为 `#` 的行是注释；
- 其他每行必须是一个 `KEY=VALUE`；
- 使用第一个 `=` 分隔 key 和 value；
- key 不能包含空白字符；
- value 是字面文本，必填项不得为空；
- `export`、shell 引号、变量插值、命令替换和续行都没有特殊含义。

因此用户直接填写不带 shell 引号的原始值。启动器和 entrypoint 绝不对
profile 使用 `source` 或 `eval`。

第一版白名单为：

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

未知 key、重复 key、冲突凭证和非法 effort level 都是错误。
`CLAUDE_CODE_EFFORT_LEVEL` 允许 `low`、`medium`、`high`、`xhigh`、
`max` 或 `auto`。以后增加其他 Claude 变量时，必须显式修改源码并新增
测试，不能通过通配符自动转发。

启动器不隐式继承宿主 shell 中的 `ANTHROPIC_*` 或 `CLAUDE_CODE_*`
配置。选中的 profile 或明确的连接方式构成完整的路由决策。单次 session
切换模型仍可通过 `--` 后的 Claude 原生参数完成。

### 凭证传递

API profile 作为只读 bind mount 挂载到固定容器路径。启动器验证内容，
但不把 value 复制到 Docker `--env` 参数。root entrypoint 再次解析挂载
文件，导出白名单变量，然后才降低到宿主 UID/GID 执行 Claude。

由此得到：

- profile 内容和 token 不出现在 Docker 命令参数、启动器日志、
  fake-Docker 测试日志或 `docker inspect` 环境变量中；
- `docker inspect` 可以看到宿主 profile 路径和 profile 名称；
- 容器用户可以读取选中的 profile；
- Claude 进程及同 UID 进程可以看到导出的凭证环境变量。

`0600` 可以防止宿主其他用户读取 profile，但不能对已被明确授予该凭证的
agent 保密。这与现有 Git PAT 挂载属于同一信任边界，必须在文档中说明。

## Claude 运行环境

### 语言环境与时区

共享镜像安装 `locales` 和 `tzdata`，并生成 `en_US.UTF-8`。镜像不设置
全局 locale 或时区。

只有 Claude 启动时注入：

```text
TZ=Etc/UTC
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
LANGUAGE=en_US:en
```

这些变量改变 Claude 容器内进程的 locale、编码、排序和时间显示，不添加
system prompt、memory 指令或回答语言偏好。Codex 保持现有环境。

### 更新与遥测策略

每个 Claude 进程独立设置以下变量：

```text
DISABLE_AUTOUPDATER=1
DISABLE_TELEMETRY=1
DISABLE_ERROR_REPORTING=1
DISABLE_FEEDBACK_COMMAND=1
CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
```

不使用合并变量 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`。profile 不得
覆盖或取消上述进程级默认值。

### 最终命令

entrypoint 以映射后的非 root 宿主用户执行：

```text
claude --dangerously-skip-permissions \
  --append-system-prompt-file <container-agent-notes> \
  <调用方参数>
```

调用方参数保持原始顺序，放在启动器参数之后。

追加的说明只包含目前已经提供给 Codex 的容器事实：

- Git 凭证已经接好，但不得读取或泄露；
- 禁止在容器内运行 `git worktree prune` 和 `git worktree remove`；
- cache 和 `CARGO_TARGET_DIR` 的位置；
- mold 默认行为和 sccache 可选用法；
- externally managed Python 的使用说明；
- 容器内免密 sudo 和宿主 UID/GID 文件所有权。

说明中不包含语言、人格、回答风格或 provider 指令。项目中的
`CLAUDE.md` 和 `.claude/` 通过 checkout 挂载自然可见。

## 入口脚本与数据流

对于以下自定义连接：

```text
docker-agent claude --profile deepseek -- --model opus
```

数据流为：

1. 选择 Claude agent 和 `deepseek` 连接身份。
2. 确定 checkout、Git common directory 和规范化 worktree 路径。
3. 计算并验证 repository/worktree identity metadata。
4. 从受保护配置根目录解析 `deepseek.env`。
5. 验证名称、所有者、权限、格式、白名单、endpoint 和凭证。
6. 以 `0700` 创建该连接方式专属状态目录。
7. 将状态目录 bind 到 `/claude-state`。
8. 将 profile 以只读方式 bind 到固定 profile 路径。
9. 增加 Claude 专属 locale、时区、更新和遥测环境变量。
10. 使用选定 workdir 和正常项目挂载启动共享镜像。
11. entrypoint 再次验证并解析 profile。
12. 使用 `gosu` 降低权限。
13. 使用启动器参数和调用方参数执行 Claude。

官方 API 流程以保留 profile 替代第 4 步。订阅流程以读写凭证文件挂载替代
profile 挂载与解析。

## 错误处理

所有可以在宿主发现的错误都必须发生在 `docker run` 之前：

- 缺少 agent 或 agent 不受支持；
- 非 TTY 环境没有连接选择参数；
- 同时指定互斥的连接选项；
- profile 名称非法；
- profile 目录或文件不存在；
- profile 是符号链接、所有者不正确或权限不正确；
- profile 位于 checkout 内；
- profile assignment 格式错误、未知、重复或冲突；
- 自定义 endpoint 或凭证缺失；
- 官方 API profile 非法；
- Linux/WSL OAuth 凭证不存在；
- macOS 不支持复用订阅凭证；
- state identity metadata 不一致；
- 现有 Git、bind、Docker daemon 或镜像错误。

entrypoint 必须再次验证，因为挂载文件才是进程最终消费的输入。entrypoint
错误可以指出非法 key 或契约，但绝不能输出 secret value 或完整 profile
内容。

菜单取消时，不创建 worktree、状态目录或 Docker 容器。Ctrl-C 以状态码
`130` 退出。

## 安全模型

Claude 使用 `--dangerously-skip-permissions`，与当前 Codex 的 `--yolo`
安全姿态一致。Docker 仍是外层隔离边界。

本功能不会增加：

- Docker socket 访问；
- privileged 模式；
- 宿主 SSH/GPG agent 或私钥；
- 完整 home 挂载；
- 完整 `~/.claude` 挂载；
- 对无关 profile 或状态目录的自动访问。

Claude 可以修改 checkout、必要的 Git metadata、每仓库构建缓存、当前选中
的状态目录，以及订阅模式下的 OAuth 凭证文件。它可以读取选中的 API
profile。除非用户显式增加 bind mount，否则它无法读取其他 profile 文件
或其他 Claude 状态叶子目录。

现有剪贴板警告继续适用：转发 display socket 后，容器进程可以与宿主
剪贴板协议交互。

## 向后兼容

- 继续接受现有 `docker-codex` 命令语法。
- Codex 继续按照原有方式共享宿主 Codex home。
- 现有 worktree、PAT、bind、cache、clipboard 和 image 选项保持原行为。
- 兼容已有 `DOCKER_CODEX_*` 配置，并将其作为对应行为的 fallback。
- 第一版继续使用已有 `/codex-cache` 路径和 cache volume 命名，避免只因
  名称变化就丢弃大型依赖缓存。
- 不自动迁移任何现有 Codex 状态。

本功能不要求同时重命名仓库。文档以 `docker-agent` 作为标准入口。

## 测试

### 启动器测试

扩展 fake-Docker launcher 测试，覆盖：

- 标准 `docker-agent codex` 和 `docker-agent claude` dispatch；
- `docker-codex`、`docker-claude` basename 兼容；
- Codex 参数顺序保持不变；
- Claude 三种直接连接方式；
- 互斥参数和缺少参数值；
- 非 TTY 且没有连接参数时失败；
- 顶层菜单按键和取消；
- 自定义 profile 二级菜单及稳定排序；
- profile 不存在和非法时的诊断；
- `0600`、owner、普通文件、符号链接、checkout 位置和白名单校验；
- token 不出现在 Docker 参数和测试日志；
- Claude state 按 repository、worktree、mode 和 profile 挂载；
- 不同路径下的同名仓库获得不同 ID；
- linked worktree 共享 repository ID，但不共享 worktree ID；
- identity metadata 碰撞检测；
- OAuth 单文件读写挂载；
- Claude 专属环境变量不出现在 Codex 启动中。

菜单渲染与选择逻辑必须支持注入输入进行测试，不能只依赖人工 PTY 操作。

### 入口脚本测试

覆盖：

- 解析每个允许的 profile key；
- 拒绝未知、重复、空值和冲突 key；
- 保留字面 value，不执行 shell；
- 设置四个独立的遥测/反馈变量；
- 单独关闭 auto updater；
- 导出 Claude locale 和时区；
- 选择隔离的 `CLAUDE_CONFIG_DIR`；
- 通过 Claude CLI 参数注入容器说明；
- 保留调用方参数和最终退出码；
- secret value 不出现在错误信息。

### 镜像测试

构建全新镜像并验证：

- Codex 和 Claude CLI 的精确版本；
- 两个 CLI 都支持 amd64 和 arm64 镜像构建；
- `locale -a` 包含 `en_US.utf8`；
- Claude 模式进程的 `LANG`、`LC_ALL` 为 `en_US.UTF-8`；
- `locale charmap` 输出 `UTF-8`；
- `TZ=Etc/UTC date '+%Z %z'` 输出 `UTC +0000`；
- Claude 使用映射后的非 root UID/GID；
- 现有 sudo、PATH、Rust、mold、sccache、Python、archive 和 clipboard
  smoke test 继续通过。

常规镜像测试不需要执行真实网络推理。

### 手工验收

在真实 WSL/Linux 宿主上：

1. 复用已有宿主 Claude 订阅凭证。
2. 启动、恢复并刷新订阅 session。
3. 确认单文件 bind mount 支持凭证写入。
4. 使用 Anthropic 官方 API profile。
5. 使用 DeepSeek 兼容 profile 示例。
6. 确认 Docker inspect 中没有 profile secret。
7. 分别恢复每种连接方式的 session，确认互不混用。
8. 在两个不同路径运行同名仓库。
9. 并发运行同一仓库的两个 worktree。
10. 确认 Claude 容器为 UTC 和 `en_US.UTF-8`，Codex 不受影响。

在 macOS 上，验证官方 API 和自定义 profile，并验证订阅复用以明确的
Keychain 限制失败，而不是给出误导性的凭证错误。

## 文档

同步更新中英文文档：

- `docker-agent` quick start 和安装方式；
- Codex 兼容入口；
- Claude 菜单和直接连接参数；
- `official-api.env` 与自定义 profile 的创建和保护；
- 状态目录布局和清理；
- Linux/WSL OAuth 共享和 macOS 限制；
- UTC 和 locale 行为；
- 遥测与自动更新策略；
- 选中的 API profile 和 OAuth 凭证可以被对应容器读取；
- 开发命令和手工验收步骤。

安全文档必须继续说明：两个 agent 都在关闭内部审批的情况下运行，并且可以
外传任何被明确挂载进容器的凭证或数据。

## 验收标准

满足以下全部条件后功能才算完成：

- 全新共享镜像包含固定版本、可以工作的 Codex 和 Claude CLI；
- 所有现有 Codex 测试和已记录工作流保持有效；
- Claude 交互启动显示两级菜单；
- 三种 Claude 直接连接方式都可以跳过菜单运行；
- state 按 repository、worktree 和连接身份隔离；
- 同名路径不会意外共享 state；
- 订阅复用只挂载 OAuth 凭证文件，不挂载完整宿主 Claude 目录；
- OAuth 凭证刷新可以通过 WSL/Linux 单文件挂载完成；
- API profile value 不出现在 Docker 参数、inspect 环境或日志中；
- 每个 Claude 进程都收到彼此独立的更新、遥测、错误、反馈、UTC 和 locale
  变量；
- 不引入任何 Claude 回答语言指令；
- 中英文文档说明行为和安全边界；
- shell、entrypoint、image 和手工验收检查全部通过。
