# docker-agent

**简体中文** | [English](README.en.md)

在同一个 Docker 镜像里运行 Codex CLI 或 Claude Code。容器挂载当前项目
目录，agent 的修改直接落在宿主文件上；如果项目是 Git checkout，启动器
还会管理 Git metadata、构建缓存、可选 worktree 和剪贴板转发。原有
`docker-codex` 命令继续兼容。

## 快速开始

前置条件：Git、Bash 3.2+、已经启动的 Docker daemon。使用 Codex 时宿主机
需要 `${CODEX_HOME:-$HOME/.codex}`；复用 Claude 官方订阅时，需要先在
Linux/WSL 宿主机上完成 Claude Code 登录。

```bash
# 在源码目录构建一次共享镜像
docker build -t docker-agent:local .

# 安装 docker-agent、docker-codex 和 docker-claude
sudo ./install.sh

# 交互创建自定义 endpoint profile
docker-claude --create-profile

# 在任意项目目录中启动（无需 Git repository）
cd /path/to/your-project
docker-agent codex
docker-agent claude
docker-agent claude --profile deepseek
```

`docker-codex` 等价于 `docker-agent codex`，`docker-claude` 等价于
`docker-agent claude`。没有 `sudo` 时，运行
`./install.sh --prefix "$HOME/.local"` 安装到 `$HOME/.local/bin`。

`docker-agent claude` 在交互终端显示连接菜单：官方订阅/OAuth、官方 API
key、自定义 endpoint；选择自定义 endpoint 后再显示按名称排序的 profile
菜单，并在名称后显示 `ANTHROPIC_MODEL`；未配置主模型时会显示原因明确的
警告。脚本或 CI 没有 TTY，必须显式使用三个连接参数之一。

> [!WARNING]
> Codex 默认使用 `--yolo`，Claude Code 默认使用
> `--dangerously-skip-permissions`。当前项目目录、必要的 Git metadata 和
> 显式凭证会按用途挂载给所选 agent；请只在信任的项目中使用。

常用命令：

```bash
docker-agent codex -- review "review the current branch"
docker-agent claude --create-profile
docker-agent claude --official-subscription
docker-agent claude --official-api
docker-agent claude --profile deepseek -- --version
docker-agent codex --isolated issue-123
docker-agent claude --bind /path/to/fixtures:ro --profile deepseek
docker-agent claude --env CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000 --profile deepseek
docker-agent codex --pat-path ~/.local/share/docker-agent/pat/github-x
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

--pat TOKEN
    直接提供 Git token；会进入 shell 历史，优先使用 --pat-path。

--pat-path FILE
    将 Git token 文件只读挂载到 /codex-credentials/pat。

--disable-clipboard
    不转发宿主显示 socket 和剪贴板。

--help, -h
    输出帮助。
```

`--` 后的参数不再由启动器解释，原样传给 Codex 或 Claude Code。

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

## 文档

- [Claude Code 集成](docs/zh/claude.md)：连接菜单、profile、OAuth、状态与清理。
- [Checkout 与 worktree](docs/zh/worktree.md)：挂载规则、`--isolated`、`--bind`。
- [认证与凭证](docs/zh/credentials.md)：Codex home、Claude 凭证、Git push。
- [镜像环境与构建缓存](docs/zh/environment.md)：工具链、locale、缓存 volume。
- [剪贴板转发](docs/zh/clipboard.md)：容器内贴图和 `--disable-clipboard`。
- [平台说明](docs/zh/platforms.md)：Linux、WSL2、macOS 差异。
- [安全边界](docs/zh/security.md)：容器权限、审批关闭和凭证可见性。
- [开发与验证](docs/zh/development.md)：测试与构建版本。
