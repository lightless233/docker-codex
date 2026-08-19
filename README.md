# docker-agent

**简体中文** | [English](README.en.md)

在同一个 Docker 镜像里运行 Codex CLI、Claude Code、Kimi Code 或 Cursor
Agent。容器挂载当前项目目录，agent 的修改直接落在宿主文件上；如果项目是
Git checkout，启动器还会管理 Git metadata、构建缓存、可选 worktree 和
剪贴板转发。原有 `docker-codex` 命令继续兼容。

## 快速开始

前置条件：Git、Bash 3.2+、Docker CLI、Docker Buildx，以及已经启动的
Docker daemon。使用 Codex 时宿主机需要 `${CODEX_HOME:-$HOME/.codex}`；
复用 Claude 官方订阅时，需要先在 Linux/WSL 宿主机上完成 Claude Code
登录。Kimi Code 的数据目录缺失时会自动创建，可以直接在容器内登录。

```bash
# 检查依赖、构建 docker-agent:local，并安装所有启动器
./install.sh

# 交互创建 Codex/Claude 自定义 endpoint profile
docker-codex --create-profile
docker-claude --create-profile

# 在任意项目目录中启动（无需 Git repository）
cd /path/to/your-project
docker-agent codex
docker-agent codex --profile relay
docker-agent claude
docker-agent claude --profile deepseek
docker-agent kimi
docker-agent cursor-agent
```

`docker-codex` 等价于 `docker-agent codex`，`docker-claude` 等价于
`docker-agent claude`，`docker-kimi` 等价于 `docker-agent kimi`，
`docker-cursor-agent` 等价于 `docker-agent cursor-agent`。不要用 `sudo`
运行整个安装器：镜像始终以当前用户身份构建，只有向 `/usr/local/bin`
安装启动器时脚本才会按需请求管理员权限。也可以运行
`./install.sh --prefix "$HOME/.local"` 安装到 `$HOME/.local/bin`，从而不
需要管理员权限；开发或自动化场景可用 `--skip-build` 只安装启动器。

Docker Desktop 通常已经包含 Buildx。如果 Docker CLI 是通过 Homebrew
单独安装的，并且安装器提示缺少 Buildx，请运行
`brew install docker-buildx`。若 `docker buildx version` 仍无法识别插件，
请把 `$(brew --prefix)/lib/docker/cli-plugins` 对应的实际路径加入
`~/.docker/config.json` 的 `cliPluginsExtraDirs`。

Cursor Agent 需要先准备一个 API key 文件，见
[Cursor Agent 集成](docs/zh/cursor-agent.md)。

启动器默认创建并加入共享的 `docker-agent` bridge 网络。需要让
PostgreSQL 等开发服务被 agent 访问时，启动该容器时同样指定
`--network docker-agent`，然后在 agent 内通过容器名访问。

`docker-agent claude` 在交互终端显示连接菜单：官方订阅/OAuth、官方 API
key、自定义 endpoint；选择自定义 endpoint 后再显示按名称排序的 profile
菜单，并在名称后显示 `ANTHROPIC_MODEL`；未配置主模型时会显示原因明确的
警告。脚本或 CI 没有 TTY，必须显式使用三个连接参数之一。

> [!WARNING]
> Codex 与 Kimi Code 默认使用 `--yolo`，Claude Code 默认使用
> `--dangerously-skip-permissions`，Cursor Agent 默认使用 `--force`。
> 当前项目目录、必要的 Git metadata 和
> 显式凭证会按用途挂载给所选 agent；请只在信任的项目中使用。
> `--host-docker` 还会让 agent 获得宿主 Docker 的 root 级控制权，包括
> 挂载任意宿主路径的能力；启用时启动器会在每次启动前显示大幅警告。

常用命令：

```bash
docker-agent codex -- review "review the current branch"
docker-agent codex --create-profile
docker-agent codex --profile relay -- --version
docker-agent claude --create-profile
docker-agent claude --official-subscription
docker-agent claude --official-api
docker-agent claude --profile deepseek -- --version
docker-agent codex --isolated issue-123
docker-agent claude --bind /path/to/fixtures:ro --profile deepseek
docker-agent claude --env CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000 --profile deepseek
docker-agent codex --pat-path ~/.local/share/docker-agent/pat/github-x
docker-agent codex --repair-sessions
docker run -d --name project-pg --network docker-agent -e POSTGRES_PASSWORD=change-me postgres:17
docker-agent codex --network another-development-network
docker-agent claude --host-docker --profile deepseek
docker-agent kimi -- --model kimi-k3
docker-agent kimi --isolated issue-123
docker-agent cursor-agent -- -p "总结当前分支的改动" --output-format json
```

## 命令行选项

公共选项：

```text
--build
    启动前从源码目录构建 docker-agent:local。

--image IMAGE
    使用其他镜像，而不是默认的 docker-agent:local。

--isolated NAME
    在 Git checkout 中创建并使用保留的 codex/NAME 分支及宿主 worktree。

--bind PATH[:ro]
    将绝对目录挂载到容器内相同路径；可重复，:ro 表示只读。

--env NAME[=VALUE]
    向容器设置环境变量；可重复。不写 VALUE 时继承同名宿主环境变量。

--network NETWORK
    在默认 docker-agent 网络之外再加入指定 Docker 网络；可重复。

--disable-default-network
    不创建、不加入共享的 docker-agent 网络。未另外指定网络时，
    Docker 使用内置 bridge 网络。

--host-docker
    将宿主 Docker Unix socket 挂载到容器，使 agent 可以操作宿主的所有
    容器、镜像、网络和卷。默认禁用；启用时会显示安全警告。

--pat TOKEN
    直接提供 Git token；会进入 shell 历史，优先使用 --pat-path。

--pat-path FILE
    将 Git token 文件只读挂载到 /codex-credentials/pat。

--disable-clipboard
    不向容器转发宿主剪贴板。

--help, -h
    输出帮助。
```

`--` 后的参数不再由启动器解释，原样传给所选 agent。

Codex profile 与维护选项：

```text
--create-profile
    在 docker-agent 配置根的 codex/profiles 下交互创建 profile；endpoint、
    模型和 API key 保存在同一个权限为 0600 的文件中；必须单独使用。

--profile NAME
    使用并校验托管 profile，同时维护 $CODEX_HOME 下的原生兼容链接；没有该
    选项时保持默认认证与配置。旧的 $CODEX_HOME/NAME.config.toml 仍可回退使用。

--repair-sessions
    备份 Codex 状态数据库，把经过文件和 session ID 校验的历史
    /codex-home/sessions 路径迁移为宿主 CODEX_HOME 路径，然后退出。
    不启动 Codex，也不会在普通启动时自动执行。
```

运行修复前应退出宿主和容器中的 Codex 进程。完整迁移与失败恢复语义见
[认证与凭证](docs/zh/credentials.md)。

多 profile、单文件 SK、中转站示例转换与安全限制见
[Codex 自定义 endpoint profile](docs/zh/codex.md)。

Claude 连接与 profile 选项：

```text
--create-profile
    交互创建自定义 endpoint profile；必须单独使用；完成后提醒配置主模型。

--official-subscription
    Linux/WSL：复用宿主 Claude Code 的 .credentials.json。

--official-api
    使用受保护的 official-api.env 中的 ANTHROPIC_API_KEY。

--profile NAME
    使用受保护的 NAME.env 自定义 endpoint profile。
```

profile 创建、OAuth 挂载、状态隔离、UTC/locale 和安全边界详见
[Claude Code 集成](docs/zh/claude.md)。

Kimi Code 没有对应的连接选择器：它共享宿主的数据根，登录、provider 和
会话都保存在其中，详见 [Kimi Code 集成](docs/zh/kimi.md)。Cursor Agent
使用受保护的 API key 文件，详见
[Cursor Agent 集成](docs/zh/cursor-agent.md)。

## 文档

- [Codex 自定义 endpoint profile](docs/zh/codex.md)：多 profile、单文件 SK 与 Responses API 兼容性。
- [Claude Code 集成](docs/zh/claude.md)：连接菜单、profile、OAuth、状态与清理。
- [Kimi Code 集成](docs/zh/kimi.md)：数据根共享、登录、默认权限与指令注入。
- [Cursor Agent 集成](docs/zh/cursor-agent.md)：API key、默认权限、worktree 注意事项。
- [Checkout 与 worktree](docs/zh/worktree.md)：挂载规则、`--isolated`、`--bind`。
- [认证与凭证](docs/zh/credentials.md)：Codex home、Claude 凭证、Git push。
- [镜像环境与构建缓存](docs/zh/environment.md)：工具链、locale、缓存 volume。
- [剪贴板转发](docs/zh/clipboard.md)：容器内贴图和 `--disable-clipboard`。
- [平台说明](docs/zh/platforms.md)：Linux、WSL2、macOS 差异。
- [安全边界](docs/zh/security.md)：容器权限、审批关闭和凭证可见性。
- [开发与验证](docs/zh/development.md)：测试与构建版本。
