# 镜像环境与构建缓存

本文说明镜像内的工具链组成、容器内 agent 能看到的环境说明文件，以及
构建缓存 volume 的行为。需要了解镜像里预装了什么、调整工具链，或排查
缓存占用时阅读本文。

## 镜像工具链

镜像基于 Debian 13 slim。Node.js 24.18.0 LTS 从 nodejs.org 官方提供的
linux-x64 或 linux-arm64 压缩包安装，并使用该版本发布目录中的
`SHASUMS256.txt` 校验。镜像还包含 pnpm、Rust stable（含 rustfmt 与
clippy）、Codex CLI、Git、Python 3（pip 与 venv）、常用本地编译依赖，
以及适合 agent 开发使用的 shell 工具。镜像在 `/etc/profile.d` 中保留
Cargo 与 pnpm 的 PATH 条目，login shell 不会丢失工具链。镜像默认通过
`RUSTFLAGS` 使用 mold 链接器加速构建（项目自身的 rustflags 或
`docker run -e RUSTFLAGS=...` 可覆盖）；如需跨 worktree 复用依赖编译
结果，可显式启用 sccache：

```bash
RUSTC_WRAPPER=sccache SCCACHE_DIR=/codex-cache/sccache cargo build
```

## 容器内 agent 的环境说明

镜像内置 `/usr/local/share/docker-codex/agent-notes.md`，记录容器环境
的关键事实：推送凭证是否已配置、默认使用 mold 链接器、sccache 的
opt-in 用法、`CARGO_TARGET_DIR` 的位置等。entrypoint 在启动 `codex`
时自动通过 `-c user_instructions=...` 注入，容器内的 Codex 无需口头
交代即可了解环境；调用方在 `--` 之后传入的 `-c` 覆盖优先级更高。该
文件随镜像版本化，调整工具链时应同步更新。

## 构建缓存

每个 Git common directory 都会获得一个稳定的 Docker volume，名称类似：

```text
docker-codex-cache-<git-path-hash>
```

该 volume 挂载到 `/codex-cache`。Cargo 的 registry/git 下载缓存、pnpm
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
