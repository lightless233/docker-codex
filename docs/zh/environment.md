# 镜像环境与构建缓存

本文说明镜像内的工具链组成、容器内 agent 能看到的环境说明文件，以及
构建缓存 volume 的行为。需要了解镜像里预装了什么、调整工具链，或排查
缓存占用时阅读本文。

## 镜像工具链

镜像基于 Debian 13 slim。Node.js 24.19.0 LTS 从 nodejs.org 官方提供的
linux-x64 或 linux-arm64 压缩包安装，并使用该版本发布目录中的
`SHASUMS256.txt` 校验。镜像还包含 pnpm、Rust stable（含 rustfmt 与
clippy）、Codex CLI、Git、Python 3（pip 与 venv）、常用本地编译依赖，
Claude Code、Kimi Code、Cursor Agent（自带运行时，位于 `/opt/cursor-agent`）、
Docker CLI、Buildx、Compose，以及适合 agent 开发使用的
shell 工具。镜像只包含 Docker 客户端，不包含 `dockerd`；只有显式使用
`--host-docker` 时，客户端才能通过挂载的 Unix socket 访问宿主 Docker。

Docker 只会给容器一个简陋的 `TERM=xterm`，颜色能力被压到 8 色，agent
TUI 的输入框背景等元素会因此失去底色。启动器在有 TTY 时把宿主的 `TERM`
和 `COLORTERM` 转发进容器；如果镜像里没有该终端的 terminfo 条目，
entrypoint 会提示并回落到 `xterm-256color`，而不是让 curses 出错或退回
8 色。镜像安装了 `ncurses-term` 以覆盖常见终端，但个别较新的终端
（如 kitty、ghostty）仍依赖上述回落。显式的
`--env TERM=...` 优先级高于自动转发。

镜像生成 `en_US.UTF-8` locale，并在 `/etc/profile.d` 中保留 Cargo 与
pnpm 的 PATH 条目，login shell 不会丢失工具链。镜像默认通过
`RUSTFLAGS` 使用 mold 链接器加速构建（项目自身的 rustflags 或
`docker run -e RUSTFLAGS=...` 可覆盖）；如需跨 worktree 复用依赖编译
结果，可显式启用 sccache：

```bash
RUSTC_WRAPPER=sccache SCCACHE_DIR=/codex-cache/sccache cargo build
```

## 容器内 agent 的环境说明

镜像内置 `/usr/local/share/docker-agent/agent-notes.md`，记录容器环境
的关键事实：推送凭证是否已配置、默认使用 mold 链接器、sccache 的
opt-in 用法、`CARGO_TARGET_DIR` 的位置等。entrypoint 在启动 Codex 时用
`-c user_instructions=...` 注入，启动 Claude 时用
`--append-system-prompt-file` 注入。文件不包含回答语言、人格、endpoint
或模型指令。调用方在 `--` 之后传入的 Codex `-c` 覆盖优先级更高。

Claude 进程单独使用 UTC 和 `en_US.UTF-8`，不会改变 Codex 或普通容器命令
的环境，也不会强制 Claude 使用英文回答。完整策略见
[Claude Code 集成](claude.md)。

## 构建缓存

每个 Git common directory 或 plain project directory 都会获得一个稳定的
Docker volume，名称类似：

```text
docker-codex-cache-<git-path-hash>
```

plain directory 以 `<当前目录>/.git` 的合成绝对路径计算相同格式的 hash；
以后在该目录执行 `git init` 不会改变 volume 名称。该 volume 挂载到
`/codex-cache`。Cargo 的 registry/git 下载缓存、pnpm
文件以及通用 XDG 缓存都保存在 Docker 的 Linux 文件系统中，并在同一仓库
的所有 worktree 之间共享；Cargo 构建产物则按 worktree 隔离在
`/codex-cache/cargo-targets/<worktree 名>-<路径哈希>` 下，避免
build.rs 指纹在不同 worktree 之间串扰。对于 macOS Docker Desktop，
这能显著减少大量小文件跨虚拟文件系统读写造成的性能损耗。

查看或删除缓存：

```bash
docker volume ls --filter name=docker-codex-cache-
docker volume rm docker-codex-cache-<git-path-hash>
```

删除缓存只会清除可以重新生成的依赖和构建产物。

---

返回 [README](../../README.md)
