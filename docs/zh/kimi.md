# Kimi Code 集成

本文说明 Kimi Code 的启动方式、数据根共享、登录、默认权限模式、容器
指令注入和安全边界。

## 启动

```bash
docker-kimi
docker-agent kimi
```

两者等价。`--` 后面的参数原样传给 Kimi Code：

```bash
docker-kimi -- --model kimi-k3
docker-kimi -- -p "总结当前仓库状态"
```

公共选项（`--build`、`--image`、`--isolated`、`--bind`、`--env`、
`--network`、`--host-docker`、`--pat-path`、`--disable-clipboard` 等）
与其他 agent 一致，见 [README](../../README.md)。

Claude 专属的连接选择器（`--official-subscription`、`--official-api`、
`--profile`、`--create-profile`）对 Kimi Code 无效，使用时会直接报错。
Kimi Code 的 provider 配置写在配置文件里，不通过环境变量注入，因此没有
对应的 profile 机制。

## 数据根与登录

Kimi Code 把配置、会话、日志和 OAuth 凭据都放在一个数据根下，默认是
`~/.kimi-code`，可用 `KIMI_CODE_HOME` 重定向。启动器把宿主的

```text
${KIMI_CODE_HOME:-$HOME/.kimi-code}
```

挂载到容器的 `/kimi-home`，并在容器内设置 `KIMI_CODE_HOME=/kimi-home`。
因此宿主和容器共享同一份登录状态：在任意一侧登录，另一侧立即可用。

宿主没有该目录时启动器会以 `0700` 创建，所以宿主不需要自己安装
Kimi Code。该路径存在但不是目录时启动器拒绝启动。

首次使用在容器内登录即可：

```bash
docker-kimi
# 在 TUI 中执行 /login，选择 Kimi Code OAuth 或 Kimi 平台 API key
```

这与 Claude Code 的处理不同。Claude 只挂载单个凭据文件并为每个
worktree 和连接方式维护独立状态；Kimi Code 共享整个数据根，会话历史
因此也在宿主和所有项目之间共享。

## 默认权限模式

容器内 Kimi Code 默认以 `--yolo` 启动，自动批准常规工具调用，与 Codex
的默认行为一致。

Kimi Code 拒绝把 `--yolo` 与 `--prompt`、`--auto`、`--plan` 组合使用，
而且非交互模式本身就以自动权限运行。所以当传入的参数里已经出现
`-p`、`--prompt`、`--auto`、`--plan`、`-y` 或 `--yolo` 时，启动器不再
追加默认值：

```bash
# 实际执行 kimi --yolo --model kimi-k3
docker-kimi -- --model kimi-k3

# 实际执行 kimi -p "..."，不追加 --yolo
docker-kimi -- -p "总结当前仓库状态"
```

## 容器环境说明的注入

Codex 和 Claude Code 都有直接追加系统提示的命令行参数，Kimi Code 没有。
它会合并读取指令文件，其中跨工具通用的位置是真实 home 下的
`~/.agents/AGENTS.md`，由 `os.homedir()` 解析，也就是容器内的
`/home/codex/.agents/AGENTS.md`。

entrypoint 因此把镜像内的公共 agent notes 复制到该路径，并且只在文件
不存在时写入。该路径位于容器私有的 home，不在挂载的数据根内，所以
不会写进宿主的 `~/.kimi-code`，宿主自己配置的
`$KIMI_CODE_HOME/AGENTS.md` 也继续生效，两者是合并关系。

notes 只描述容器事实，不包含回答语言、人格、endpoint 或模型指令。

## 安全边界

共享数据根里含有 OAuth 凭据或 API key，容器内的 Kimi Code 进程可读。
容器用户还拥有容器内免密 sudo，且默认关闭了工具审批，因此只应在信任
的项目目录中使用。

数据根是宿主目录的绑定挂载，容器内对配置和会话的修改会直接写回宿主。
需要与宿主完全隔离时，为该次启动显式指定另一个数据根：

```bash
KIMI_CODE_HOME=~/.kimi-code-throwaway docker-kimi
```

---

返回 [README](../../README.md)
