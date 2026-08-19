# 开发与验证

本文说明如何运行本项目的测试，以及构建镜像时如何显式修改工具版本。
修改启动器、Dockerfile 或 entrypoint 后阅读本文。

## 构建时的版本参数

构建时可以显式修改工具版本：

```bash
docker build \
  --build-arg NODE_VERSION=24.19.0 \
  --build-arg GO_VERSION=1.26.6 \
  --build-arg CODEX_VERSION=0.148.0 \
  --build-arg CLAUDE_CODE_VERSION=2.1.229 \
  --build-arg KIMI_CODE_VERSION=0.36.0 \
  --build-arg CURSOR_AGENT_VERSION=2026.08.11-e8db854 \
  --build-arg PNPM_VERSION=11.21.0 \
  -t docker-agent:local .
```

`NODE_VERSION` 只会通过显式 build arg 或代码修改升级。镜像不会从 Debian
或第三方软件源安装 Node.js/npm。

`GO_VERSION` 同样只会显式升级。Go 从官方 linux-amd64/linux-arm64 压缩包
安装，而不是使用 Debian 软件包；修改版本时还必须根据对应版本发布的校验和
同步更新 `GO_SHA256_AMD64` 与 `GO_SHA256_ARM64`。

升级 `CURSOR_AGENT_VERSION` 时必须同步更新 Dockerfile 中的
`CURSOR_AGENT_SHA256_AMD64` 和 `CURSOR_AGENT_SHA256_ARM64`。Cursor 官方
不发布校验和，这两个值由本项目自行记录，可以这样重新计算：

```bash
for arch in x64 arm64; do
  curl -fsSL "https://downloads.cursor.com/lab/VERSION/linux/$arch/agent-cli-package.tar.gz" |
    sha256sum
done
```

## 验证

检查 Dockerfile，构建镜像，然后运行 shell 与真实容器测试：

```bash
docker build --check .
docker build -t docker-agent:local .
tests/run.bash
tests/bash32_compat_test.bash
DOCKER_AGENT_TEST_IMAGE=docker-agent:local tests/image_test.bash
```

shell 测试会使用真实的临时 Git 仓库、linked worktree 和 submodule，只在
Docker 外部边界使用 fake command。`codex_profile_test.bash` 使用临时
`CODEX_HOME`、docker-agent 配置根和伪终端验证单文件 profile 创建、原生
兼容链接、单 profile 挂载、密钥遮罩、TOML 转义、权限校验与选择参数；
`session_repair_test.py` 只在临时 `CODEX_HOME` 中验证
SQLite/WAL 一致性备份、路径与 session ID 校验、锁超时、事务回滚和幂等性，
绝不读取或修改用户真实 Codex 状态。独立的镜像测试会运行真实容器，验证
Debian、Node 安装来源、Codex/Claude/Kimi 版本、经兼容链接加载且仅挂载当前
文件的 Codex profile 严格配置解析、数值 UID/GID、Claude 的 UTC/locale/遥测策略、Kimi 指令文件的落点、
Codex session 修复工具的降权运行、未加入 root 组以及免密 sudo。
`bash32_compat_test.bash` 会在官方 Bash 3.2 镜像内重新运行完整 shell 测试，
覆盖 macOS 自带 Bash 的语法和运行时行为；首次运行需要拉取镜像和 Alpine
测试依赖。

Linux 镜像构建和运行时 smoke test 已纳入发布验证。macOS 参数分支和多架构
镜像定义有自动化覆盖，但本项目尚未在真实 macOS Docker Desktop/Apple
Silicon 环境中执行过，不能根据 Linux 测试结果推断已经完成 macOS 实机
验证。

---

返回 [README](../../README.md)
