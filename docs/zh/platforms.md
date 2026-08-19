# 平台说明

本文说明 Linux/WSL2 与 macOS 宿主上的平台差异与注意事项。剪贴板转发
（含 WSL 下的 `powershell.exe` shim）单独记录在
[clipboard.md](clipboard.md)。

## 共享 Docker 网络

所有 agent 容器默认加入持久化的 `docker-agent` bridge
网络。启动器会在该网络不存在时自动创建，不会在 agent 退出时
删除。其他开发服务可以加入同一网络：

```bash
docker run -d --name project-pg --network docker-agent \
  -e POSTGRES_PASSWORD=change-me postgres:17
```

agent 容器随后可以通过 `project-pg:5432` 访问 PostgreSQL。使用可重复的
`--network NAME` 可以同时加入其他网络；
`--disable-default-network` 会禁用共享网络。`host` 和 `none` 是
特殊网络模式，必须与 `--disable-default-network` 一起使用，且不能再组合
其他网络。

该默认网络在所有 docker-agent 实例之间共享；加入它的容器可以相互
访问对方暴露的端口。

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
DOCKER_DEFAULT_PLATFORM=linux/amd64 ./install.sh
```

通过模拟运行 amd64 镜像时，构建和运行速度都会更慢。

---

返回 [README](../../README.md)
