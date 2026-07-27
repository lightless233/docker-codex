# docker-codex

**简体中文** | [English](README.en.md)

在 Docker 容器里运行 Codex CLI 的启动脚本。容器挂载你当前的 Git checkout，Codex 的修改直接落在宿主机文件上；`~/.codex` 共享，登录态和配置不用再弄一份。容器摸不到系统的其他部分，可以放心让它全自动干活。

## 快速开始

前置条件：Git、Bash 3.2+、Docker daemon 已启动，宿主机上有 `~/.codex`（在本机用过 Codex CLI 就有）。

```bash
# 构建镜像，只需一次
cd /absolute/path/to/docker-codex
./docker-codex --build -- --version

# 安装启动器
sudo install -m 0755 ./docker-codex /usr/local/bin/docker-codex

# 随便进一个项目，启动
cd /path/to/your-project
docker-codex
```

启动之后和平时的 Codex 没什么区别，只是跑在容器里。

没有 `sudo` 就装到用户目录：`install -m 0755 ./docker-codex "$HOME/.local/bin/docker-codex"`（记得把 `~/.local/bin` 加进 `PATH`）。重建镜像要回到这个仓库跑 `./docker-codex --build`；启动器脚本有更新就重新执行一次 `install`。

支持 Linux、WSL2、macOS（Docker Desktop，含 Apple Silicon）。

> [!WARNING]
> 默认 `--yolo`，并且以读写方式挂载当前 checkout、必要的 Git metadata 和宿主 Codex home。只在你信任的项目里用。容器进程还会带 `--disable apps`，只影响当次进程，不改共享配置。

几个常用的进阶参数：

```bash
docker-codex -- review "review the current branch"   # -- 后面的参数原样传给 Codex
docker-codex --isolated issue-123                    # 开个隔离 worktree 干活 → docs/zh/worktree.md
docker-codex --bind /path/to/fixtures:ro --          # 额外挂一个只读目录 → docs/zh/worktree.md
docker-codex --pat-path ~/.local/share/docker-codex/pat/github-x  # 容器里要 git push → docs/zh/credentials.md
```

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

--pat TOKEN
    直接提供 Git 访问 token；存储在 data home（600 权限）并以只读
    挂载到 /codex-credentials/pat。token 会出现在 shell 历史中，
    建议优先使用 --pat-path。

--pat-path FILE
    将 token 文件只读挂载到 /codex-credentials/pat；
    DOCKER_CODEX_PAT_PATH 可设置默认值。

--disable-clipboard
    不转发宿主剪贴板（显示 socket）到容器内。

--help, -h
    输出帮助。
```

构建时改工具版本用 `--build-arg`，见[开发与验证](docs/zh/development.md)。

## 文档

- [Checkout 与 worktree](docs/zh/worktree.md)：挂载规则、`--isolated`、`--bind`。
- [认证与凭证](docs/zh/credentials.md)：Codex home 怎么共享、容器里怎么 `git push`。
- [镜像环境与构建缓存](docs/zh/environment.md)：镜像里装了什么、缓存 volume 怎么管。
- [剪贴板转发](docs/zh/clipboard.md)：容器里贴图的原理和 `--disable-clipboard`。
- [平台说明](docs/zh/platforms.md)：WSL2 和 macOS 的坑。
- [安全边界](docs/zh/security.md)：容器有哪些权限、启动器绝不挂什么。
- [开发与验证](docs/zh/development.md)：跑测试、改构建版本。
