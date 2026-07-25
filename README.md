# docker-codex

**简体中文** | [English](README.en.md)

在开发容器中运行 Codex CLI，同时直接编辑调用者当前的 Git checkout。
启动器会共享宿主机上的 Codex home，能够识别普通 checkout、linked
worktree 和 submodule；只有在用户明确指定时，它才会创建新的 worktree。

## 快速开始

开始前请确认 Docker daemon 已启动，并且宿主机上已经存在可用的
`${CODEX_HOME:-$HOME/.codex}`。

### 1. 首次构建

进入本仓库并构建镜像：

```bash
cd /absolute/path/to/docker-codex
./docker-codex --build -- --version
```

构建完成后应输出当前镜像内的 Codex CLI 版本。后续启动会直接复用本地
`docker-codex:local`，不需要重复构建。

### 2. 让命令在当前终端中随处可用

把本仓库目录加入当前 shell 的 `PATH`：

```bash
export PATH="/absolute/path/to/docker-codex:$PATH"
```

如果需要永久生效，请把同一行加入 `~/.bashrc` 或 `~/.zshrc`，然后重新打开
终端。

### 3. 启动 Codex

进入需要开发的 Git checkout，然后运行：

```bash
cd /absolute/path/to/your-project
docker-codex
```

常用示例：

```bash
# 直接向 Codex 传递参数
docker-codex -- review "review the current branch"

# 创建并使用保留的隔离 worktree
docker-codex --isolated issue-123

# 挂载 checkout 之外的只读目录
docker-codex --bind /absolute/path/to/fixtures:ro --
```

> [!WARNING]
> 启动器默认使用 `--yolo`，并以读写方式挂载当前 checkout、必要的 Git
> metadata 和宿主 Codex home。请只在你信任的项目和 Docker 隔离环境中
> 使用。

启动器还会为本次容器进程传入 `--disable apps`，默认关闭 Apps/连接器，
避免内置 `codex_apps` MCP 的启动问题影响本地开发。它不会修改宿主机共享的
`config.toml`。

支持的宿主平台：

- Linux
- WSL2
- 使用 Docker Desktop 的 macOS，包括 Apple Silicon

镜像基于 Debian 13 slim。Node.js 24.18.0 LTS 从 nodejs.org 官方提供的
linux-x64 或 linux-arm64 压缩包安装，并使用该版本发布目录中的
`SHASUMS256.txt` 校验。镜像还包含 pnpm、Rust stable、Codex CLI、Git、
常用本地编译依赖，以及适合 agent 开发使用的 shell 工具。

## 前置条件

- Git
- Bash 3.2 或更高版本
- Docker，并且 Docker daemon 已启动
- 已存在的 Codex home，通常为 `~/.codex`

在本仓库中构建本地镜像：

```bash
./docker-codex --build -- --version
```

后续启动会复用 `docker-codex:local`：

```bash
cd /path/to/project
/path/to/docker-codex/docker-codex
```

启动器会在 `codex` 后自动加入 `--yolo --disable apps`。Apps/连接器只在
当前容器进程中关闭，宿主机共享的 Codex 配置不会被修改。`--` 后面的参数
会原样传给 Codex：

```bash
/path/to/docker-codex/docker-codex -- review "review the current branch"
```

## Checkout 与 worktree

默认情况下，启动器直接使用当前目录所属的 checkout，不会创建分支或
worktree。

checkout 会挂载到容器内完全相同的绝对路径。如果当前 checkout 是 linked
worktree 或 submodule，并且 Git metadata 位于其他目录，启动器会通过 Git
自动发现这些目录，只补充挂载必要的外部 Git metadata，并保持宿主机与
容器内路径一致。

例如，可以直接使用一个长期存在的 linked worktree：

```bash
cd /home/me/program/my-long-lived-worktree
/path/to/docker-codex/docker-codex
```

容器对 Git common directory 拥有写权限，因为暂存和提交操作需要更新
index 与 refs。除非通过额外参数显式挂载，否则容器无法访问其他 sibling
worktree。

### 可选的隔离 worktree

需要新建隔离 worktree 时，显式指定：

```bash
/path/to/docker-codex/docker-codex --isolated issue-123
```

该命令会创建：

- 分支 `codex/issue-123`
- 位于以下目录的 worktree：
  `${DOCKER_CODEX_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/docker-codex}/worktrees`
- 使用新 worktree 启动的容器

Codex 或 Docker 退出后，worktree 和分支都会保留；即使启动失败也不会自动
删除。请使用标准 Git 命令查看和清理：

```bash
git worktree list
git worktree remove /absolute/path/from-the-list
git branch -d codex/issue-123
```

如果 worktree 中存在未提交改动，Git 会拒绝普通删除，除非用户明确强制
执行。启动器自身绝不会自动删除 worktree。

## 挂载额外的项目目录

项目需要 checkout 之外的 fixture、工具或其他目录时，可以重复使用
`--bind`：

```bash
docker-codex \
  --bind /absolute/path/to/fixtures:ro \
  --bind /absolute/path/to/local-tooling \
  --
```

这些目录会挂载到容器内相同的绝对路径。只接受目录；追加 `:ro` 表示只读。
包含英文逗号的路径会被拒绝，因为 Docker 的 `--mount` 语法无法无歧义地
表示此类路径。

启动器不会直接挂载 checkout 的父目录，避免容器意外获得其他仓库或长期
worktree 的访问权限。

## Codex 配置、记忆与认证

宿主机完整的 `${CODEX_HOME:-$HOME/.codex}` 会以读写方式挂载到
`/codex-home`，同时容器内设置：

```text
CODEX_HOME=/codex-home
```

因此宿主和容器可以共享：

- Codex 配置
- 本地 memory
- session 与其他持久状态
- skills 和 plugins
- 文件形式保存的认证信息

宿主和容器中的多个 Codex 进程共享状态，其行为与宿主机上同时运行多个
Codex 进程相同。升级状态格式时，建议让镜像内 Codex CLI 与宿主版本保持
一致。

认证存在操作系统边界：

- 保存在 `auth.json` 中的凭据可以通过目录挂载共享
- Linux keyring 和 macOS Keychain 不会进入 Linux 容器

入口脚本会执行 `codex login status`。如果检查失败，它会输出警告但继续
启动，让 Codex 自己接管后续交互登录。启动器不会修改
`cli_auth_credentials_store`，也不会把凭据复制进镜像层。

如果 `config.toml` 引用了其他宿主机绝对路径，需要通过 `--bind` 补充挂载。
配置中的 STDIO MCP 命令和本地工具也必须已经安装在镜像中，或者显式挂载到
容器内。

## 构建缓存

每个 Git common directory 都会获得一个稳定的 Docker volume，名称类似：

```text
docker-codex-cache-<git-path-hash>
```

该 volume 挂载到 `/codex-cache`。Cargo target、pnpm 文件以及通用 XDG
缓存都保存在 Docker 的 Linux 文件系统中。对于 macOS Docker Desktop，
这能显著减少大量小文件跨虚拟文件系统读写造成的性能损耗。

查看或删除缓存：

```bash
docker volume ls --filter name=docker-codex-cache-
docker volume rm docker-codex-cache-<git-path-hash>
```

删除缓存只会清除可以重新生成的依赖和构建产物。

## 平台说明

### Linux 与 WSL2

入口脚本会把容器进程映射为宿主机的数值 UID/GID，并通过 Docker 的
`host-gateway` 添加 `host.docker.internal`。

在 WSL2 中，构建性能敏感的项目建议存放在 Linux 文件系统内，而不是
`/mnt/c`。

### macOS

Docker Desktop 必须允许共享 checkout、外部 Git metadata、Codex home
以及所有 `--bind` 源目录。默认情况下，`/Users` 下的路径通常已经包含在
Docker Desktop 的文件共享设置中。

入口脚本能够处理 macOS 常见的 UID 501/GID 20，不假设对应组名一定未被
Debian 占用。宿主机 Keychain 中的凭据仍然无法进入容器。

在 Apple Silicon 上，本地构建会生成原生 Linux arm64 镜像。如果项目明确
需要 Linux amd64 环境，可以手动选择平台：

```bash
DOCKER_DEFAULT_PLATFORM=linux/amd64 ./docker-codex --build -- --version
```

通过模拟运行 amd64 镜像时，构建和运行速度都会更慢。

## 安全边界

容器首先以 root 身份进入 entrypoint，只用于：

- 映射宿主 UID/GID
- 初始化容器私有 home
- 初始化 `/codex-cache`
- 配置运行用户

随后通过 `gosu` 以宿主机的数值 UID/GID 运行 Codex。入口脚本不会递归
修改 checkout、Git metadata 或 `/codex-home` 的所有权，因此普通命令在
bind mount 中创建的文件仍属于宿主用户。

容器运行用户拥有免密 sudo，可以在必要时获得容器内 root 权限，但不会被
加入 root 组。

启动器默认使用 `--yolo`，这会关闭 Codex 自身的审批和命令沙箱。所有读写
挂载都会完整暴露给 agent，Docker 是外层隔离边界。启动器不会使用
`--privileged`。

启动器绝不会自动挂载：

- `/var/run/docker.sock`
- 宿主机根目录或整个 home
- checkout 的共同父目录
- SSH/GPG agent 或私钥
- 无关仓库

Codex 可以自由修改所有被明确以读写方式挂载的路径。除此之外的内容仍由
Docker 隔离。

## 命令行选项

```text
--build
    启动前构建镜像。

--image IMAGE
    使用其他镜像，而不是默认的 docker-codex:local。

--isolated NAME
    创建并使用保留的 codex/NAME 分支及其宿主机 worktree。

--bind PATH[:ro]
    将绝对目录挂载到容器内相同路径；可以重复指定。

--help, -h
    输出帮助。
```

构建时可以显式修改工具版本：

```bash
docker build \
  --build-arg NODE_VERSION=24.18.0 \
  --build-arg CODEX_VERSION=0.145.0 \
  --build-arg PNPM_VERSION=10.14.0 \
  -t docker-codex:local .
```

`NODE_VERSION` 只会通过显式 build arg 或代码修改升级。镜像不会从 Debian
或第三方软件源安装 Node.js/npm。

## 验证

运行 shell 测试：

```bash
tests/run.bash
```

检查并构建镜像，然后运行真实容器测试：

```bash
docker build --check .
docker build -t docker-codex:local .
DOCKER_CODEX_TEST_IMAGE=docker-codex:local tests/image_test.bash
```

shell 测试会使用真实的临时 Git 仓库、linked worktree 和 submodule，只在
Docker 外部边界使用 fake command。独立的镜像测试会运行真实容器，验证
Debian、Node 安装来源、数值 UID/GID、未加入 root 组以及免密 sudo。

Linux 镜像构建和运行时 smoke test 已纳入发布验证。macOS 参数分支和多架构
镜像定义有自动化覆盖，但本项目尚未在真实 macOS Docker Desktop/Apple
Silicon 环境中执行过，不能根据 Linux 测试结果推断已经完成 macOS 实机
验证。
