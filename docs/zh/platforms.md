# 平台说明

本文说明 Linux/WSL2 与 macOS 宿主上的平台差异与注意事项。剪贴板转发
（含 WSL 下的 `powershell.exe` shim）单独记录在
[clipboard.md](clipboard.md)。

## Linux 与 WSL2

入口脚本会把容器进程映射为宿主机的数值 UID/GID，并通过 Docker 的
`host-gateway` 添加 `host.docker.internal`。

在 WSL2 中，构建性能敏感的项目建议存放在 Linux 文件系统内，而不是
`/mnt/c`。

Linux/WSL 可以通过 `--official-subscription` 单文件挂载宿主 Claude Code
的 `.credentials.json`。具体权限和路径见 [Claude Code 集成](claude.md)。

## macOS

Docker Desktop 必须允许共享 checkout、外部 Git metadata、Codex home
以及所有 `--bind` 源目录。默认情况下，`/Users` 下的路径通常已经包含在
Docker Desktop 的文件共享设置中。

入口脚本能够处理 macOS 常见的 UID 501/GID 20，不假设对应组名一定未被
Debian 占用。宿主机 Keychain 中的 Codex 或 Claude 凭据仍然无法进入
容器；Claude 官方订阅模式会明确拒绝，使用 API profile 代替。

在 Apple Silicon 上，本地构建会生成原生 Linux arm64 镜像。如果项目明确
需要 Linux amd64 环境，可以手动选择平台：

```bash
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker build -t docker-agent:local .
```

通过模拟运行 amd64 镜像时，构建和运行速度都会更慢。

---

返回 [README](../../README.md)
