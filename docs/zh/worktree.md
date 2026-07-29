# Checkout 与 worktree

本文说明启动器如何定位和挂载当前 checkout，以及 `--isolated` 隔离
worktree 和 `--bind` 额外目录挂载的行为。需要了解 worktree 的创建与
清理方式，或需要把 checkout 之外的目录挂进容器时阅读本文。

默认情况下，启动器直接使用当前目录所属的 checkout，不会创建分支或
worktree。

checkout 会挂载到容器内完全相同的绝对路径。如果当前 checkout 是 linked
worktree 或 submodule，并且 Git metadata 位于其他目录，启动器会通过 Git
自动发现这些目录，只补充挂载必要的外部 Git metadata，并保持宿主机与
容器内路径一致。

例如，可以直接使用一个长期存在的 linked worktree：

```bash
cd /home/me/program/my-long-lived-worktree
docker-agent codex
```

容器对 Git common directory 拥有写权限，因为暂存和提交操作需要更新
index 与 refs。除非通过额外参数显式挂载，否则容器无法访问其他 sibling
worktree。

## 可选的隔离 worktree

需要新建隔离 worktree 时，显式指定：

```bash
docker-agent codex --isolated issue-123
```

该命令会创建：

- 分支 `codex/issue-123`
- 位于以下目录的 worktree：
  `${DOCKER_AGENT_DATA_HOME:-${DOCKER_CODEX_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/docker-agent}}/worktrees`
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
docker-agent codex \
  --bind /absolute/path/to/fixtures:ro \
  --bind /absolute/path/to/local-tooling \
  --
```

这些目录会挂载到容器内相同的绝对路径。只接受目录；追加 `:ro` 表示只读。
包含英文逗号的路径会被拒绝，因为 Docker 的 `--mount` 语法无法无歧义地
表示此类路径。

启动器不会直接挂载 checkout 的父目录，避免容器意外获得其他仓库或长期
worktree 的访问权限。

---

返回 [README](../../README.md)
