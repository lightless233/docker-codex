# Docker Codex 默认关闭 Apps 设计

## 目标

`docker-codex` 每次启动容器内 Codex 时默认关闭 Apps/连接器，避免内置
`codex_apps` MCP 的启动超时影响本地开发。该行为只作用于本次容器进程，
不得修改共享的宿主机 `~/.codex/config.toml`。

## 命令接口

启动器现有的外层参数和 `--` 后的 Codex 参数转发规则保持不变，不新增
`docker-codex` 专用选项。

容器启动命令由：

```text
codex --yolo [codex args...]
```

改为：

```text
codex --yolo --disable apps [codex args...]
```

`--disable apps` 使用 Codex 自身的单次 feature override，因此不会写入共享
配置。

## 错误处理与兼容性

- Docker、Git、挂载、worktree 和用户参数解析逻辑不变。
- `--disable apps` 位于用户传入的 Codex 参数之前，保持启动器默认参数集中
  在 `codex` 后部。
- 当前镜像固定的 Codex CLI 0.145.0 支持该参数组合。

## 测试与文档

- launcher 测试断言最终参数顺序包含
  `codex`、`--yolo`、`--disable`、`apps`，随后才是用户参数。
- launcher 帮助不新增选项。
- 中文和英文 README 说明 Apps 默认关闭、仅影响容器内本次启动。
- 运行全部 shell 测试确认现有 checkout、worktree、挂载和镜像行为不回归。
