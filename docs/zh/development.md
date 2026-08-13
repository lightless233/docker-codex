# 开发与验证

本文说明如何运行本项目的测试，以及构建镜像时如何显式修改工具版本。
修改启动器、Dockerfile 或 entrypoint 后阅读本文。

## 构建时的版本参数

构建时可以显式修改工具版本：

```bash
docker build \
  --build-arg NODE_VERSION=24.19.0 \
  --build-arg CODEX_VERSION=0.147.0 \
  --build-arg CLAUDE_CODE_VERSION=2.1.229 \
  --build-arg PNPM_VERSION=11.21.0 \
  -t docker-agent:local .
```

`NODE_VERSION` 只会通过显式 build arg 或代码修改升级。镜像不会从 Debian
或第三方软件源安装 Node.js/npm。

## 验证

检查 Dockerfile，构建镜像，然后运行 shell 与真实容器测试：

```bash
docker build --check .
docker build -t docker-agent:local .
tests/run.bash
DOCKER_AGENT_TEST_IMAGE=docker-agent:local tests/image_test.bash
```

shell 测试会使用真实的临时 Git 仓库、linked worktree 和 submodule，只在
Docker 外部边界使用 fake command。独立的镜像测试会运行真实容器，验证
Debian、Node 安装来源、Codex/Claude 版本、数值 UID/GID、Claude 的
UTC/locale/遥测策略、未加入 root 组以及免密 sudo。

Linux 镜像构建和运行时 smoke test 已纳入发布验证。macOS 参数分支和多架构
镜像定义有自动化覆盖，但本项目尚未在真实 macOS Docker Desktop/Apple
Silicon 环境中执行过，不能根据 Linux 测试结果推断已经完成 macOS 实机
验证。

---

返回 [README](../../README.md)
