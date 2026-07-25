# Debian、Node LTS 与容器权限设计

## 目标

将开发镜像从 `node:22-bookworm` 改为 `debian:13-slim`，消除基础镜像
预置 `node` 用户带来的常见 UID 1000 冲突，并让 Node.js 只从 Node 官方
发行站点安装。容器继续以宿主 UID/GID 运行 Codex，日常写入 bind mount
时保持宿主文件归属；Codex 同时获得免密 sudo，可在容器内部按需取得 root
权限。

## 镜像和 Node.js 安装

Dockerfile 使用：

```dockerfile
FROM debian:13-slim
ARG NODE_VERSION=24.18.0
ARG TARGETARCH
```

Node.js 不通过 Debian 或任何第三方 apt 仓库安装。构建阶段根据目标架构选择
Node 官方预编译包：

- `amd64` 对应 `linux-x64`
- `arm64` 对应 `linux-arm64`
- 其他架构直接失败并输出明确错误

安装过程从
`https://nodejs.org/dist/v${NODE_VERSION}/` 下载对应的 `.tar.xz` 包及
`SHASUMS256.txt`，先执行 SHA-256 校验，再将包内容解压到 `/usr/local`。
临时下载内容在同一构建层删除。构建阶段执行 `node --version` 和
`npm --version`，确保安装结果可运行。

`NODE_VERSION` 默认固定为当前选定的最新 LTS `24.18.0`，保证镜像可复现；
以后通过显式 build arg 或代码提交升级，不在构建时动态选择版本。

## 容器用户与 sudo

镜像通过 apt 安装 `sudo` 以及原有开发依赖，但不安装 `nodejs` 或 `npm`。
entrypoint 仍以 root 启动，继续负责：

1. 解析宿主 `HOST_UID` 和 `HOST_GID`；
2. 复用或创建相应用户和组；
3. 初始化容器私有 home 与 `/codex-cache`；
4. 将运行用户加入 `sudo` 组；
5. 以宿主数值 UID/GID 执行 Codex。

sudoers 为 `sudo` 组配置 `NOPASSWD: ALL`。运行用户不加入 GID 0 的 root
组，因为 root 组不等同于 root 权限，且会增加跨平台 GID 冲突。Codex
需要修改系统目录或安装包时可直接运行 `sudo`。

entrypoint 不对 checkout、Git metadata 或 `/codex-home` 执行递归 chown，
因此源码、Git 状态和共享 Codex 状态继续由宿主用户拥有。

## Codex 权限模式

宿主启动器默认在 `codex` 后加入 `--yolo`，即跳过 Codex 自身的审批和命令
沙箱。Docker 是外层隔离边界；启动器继续禁止自动挂载 Docker socket、宿主
根目录、整个 home、SSH/GPG 私钥，并且不使用 `--privileged`。

`--` 后的用户参数仍逐字透传。默认调用等价于：

```sh
codex --yolo <用户参数>
```

免密 sudo 让 Codex 在必要时拥有完整的容器内 root 能力，但正常命令仍以
宿主 UID/GID 执行，避免 Linux bind mount 上产生不必要的 root-owned 文件。

## 测试与验收

自动化测试新增以下断言：

- Dockerfile 基础镜像为 `debian:13-slim`；
- Node 默认版本为 `24.18.0`；
- 下载源为 `nodejs.org`，并校验 `SHASUMS256.txt`；
- amd64/arm64 映射存在，未知架构失败；
- apt 安装列表不包含 `nodejs` 或 `npm`；
- entrypoint 为新建和已存在的运行用户配置 sudo；
- 启动器默认将 `--yolo` 放在用户 Codex 参数之前。

最终验收包括：

1. shell 测试和 shellcheck；
2. `docker build --check .`；
3. Linux 本机完整镜像构建；
4. 验证 Node.js、npm、pnpm、Codex 和 Rust 版本；
5. 以非 root 宿主 UID 启动容器，验证 `sudo -n true`；
6. 验证容器内普通用户和 sudo 创建文件时的归属差异；
7. 普通 checkout 与 linked worktree 启动回归。

macOS/Apple Silicon 继续由架构映射和自动化参数测试覆盖；没有真实 macOS
Docker Desktop 环境时，不声称完成 macOS 实机验证。
