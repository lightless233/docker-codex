# Cursor Agent 集成

本文说明 Cursor Agent 的启动方式、API key 存放、默认权限模式、worktree
注意事项、项目指令来源和安全边界。

## 启动

```bash
docker-cursor-agent
docker-agent cursor-agent
```

两者等价。`--` 后面的参数原样传给 Cursor Agent：

```bash
docker-cursor-agent -- --model gpt-5
docker-cursor-agent -- -p "总结当前仓库状态" --output-format json
```

公共选项（`--build`、`--image`、`--isolated`、`--bind`、`--env`、
`--network`、`--host-docker`、`--pat-path`、`--disable-clipboard` 等）
与其他 agent 一致，见 [README](../../README.md)。

Claude 专属的连接选择器（`--official-subscription`、`--official-api`、
`--profile`、`--create-profile`）对 Cursor Agent 无效，使用时会直接报错。

## API key

Cursor 官方对容器和 CI 只支持 API key 认证。启动器从下面这个固定路径
读取：

```text
${DOCKER_AGENT_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent}/cursor-agent/api-key
```

从 [Cursor Dashboard → API Keys](https://cursor.com/dashboard/api) 生成
key，然后写入该文件：

```bash
config_root="${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent"
install -d -m 700 "$config_root/cursor-agent"
install -m 600 /dev/null "$config_root/cursor-agent/api-key"
read -rs key && printf '%s' "$key" > "$config_root/cursor-agent/api-key" && unset key
```

该文件必须是当前用户拥有、权限精确为 `0600`、非符号链接的普通文件，且
内容非空，否则启动器拒绝启动。文件中只放 key 本身，结尾换行会被忽略。

这些路径不需要记：文件缺失时启动器会打印上面这几条命令，并且把路径展开
成实际值，可以直接复制执行。

key 以只读方式挂载到容器的
`/run/docker-agent/cursor-api-key`，由 entrypoint 读取后导出为
`CURSOR_API_KEY`。**key 的值不会出现在 `docker run` 参数里**，因此
`docker inspect` 和宿主进程列表都看不到它。

需要注意的一点：Cursor CLI 的 `status` 和 `whoami` 子命令只报告本地
OAuth 登录状态，**完全不看 `CURSOR_API_KEY`**，所以它们在容器里始终
输出 `Not logged in`，即使 key 有效。这意味着无法在启动前预检 key 是否
可用，只能在实际调用时才知道。启动器因此只校验文件本身。

计费上，user API key 的用量记在该用户订阅计划的额度池里，不是独立的
API 账单。额度耗尽后需要在 dashboard 显式开启 on-demand 才能继续，
建议同时设置 spend limit。选用不同模型会显著影响额度消耗速度。

## 数据目录与工作区信任

Cursor Agent 把每个项目的状态放在 `~/.cursor/projects/<项目 slug>/` 下，
其中包括工作区信任标记 `.workspace-trusted` 和会话历史。它没有能整体
重定向数据根的环境变量：`CURSOR_CONFIG_DIR` 只搬 `cli-config.json`，
`projects/` 仍然固定在 `$HOME/.cursor`。

因此启动器把宿主的

```text
${DOCKER_AGENT_CURSOR_HOME:-$HOME/.cursor}
```

挂载到容器的 `/cursor-home`，再由 entrypoint 将容器内的 `$HOME/.cursor`
符号链接过去。宿主没有该目录时以 `0700` 创建。

如果不做这一步，容器每次退出都会丢掉整个 `.cursor`，于是同一个项目每次
启动都重新弹出 `Workspace Trust Required`，`--continue` 和 `--resume`
也永远找不到历史会话。

宿主上装了 Cursor CLI 的话，两边共享同一份数据目录，登录态和信任记录
互通。

## 默认权限与自动更新

容器内 Cursor Agent 默认以 `--force` 启动（`--yolo` 是它的别名），
自动批准工具调用。当传入的参数里已经出现 `-f`、`--force`、`--yolo`
或 `--auto-review` 时，启动器不再追加默认值。

启动器还固定加上隐藏参数 `--disable-auto-update`。Cursor CLI 默认会
自更新，而镜像里的版本由 `CURSOR_AGENT_VERSION` 固定，运行时自更新会
破坏可复现性。

## 不要用 CLI 自带的 worktree

Cursor Agent 自带 `-w/--worktree`，它在 `~/.cursor/worktrees/` 下创建
worktree。容器里的 `$HOME` 是容器私有的，于是会有两个后果：

- worktree 中的所有修改随容器退出一起丢失；
- 宿主仓库里残留一条指向容器内路径的 worktree 记录（`git worktree list`
  显示为 `prunable`）以及新建的分支，需要手动
  `git worktree prune` 和 `git branch -D` 清理。

而且 worktree 是在认证之前创建的，即使这次运行因为 key 无效而没有做
任何事，仓库同样会被污染。

启动器检测到该参数时会打印警告，但仍然原样透传，不阻止。需要隔离
worktree 时请改用项目的 `--isolated NAME`，它在宿主上创建并保留
worktree。

## 项目指令

Cursor Agent 原生读取项目根的 `AGENTS.md`、`CLAUDE.md` 和
`.cursor/rules`，因此项目自身的规则在容器里自动生效，不需要额外注入。

它没有追加或覆盖 system prompt 的命令行参数，镜像内的公共 agent notes
因此不会注入给 Cursor Agent。这与 Codex、Claude Code 和 Kimi Code 不同。

## 容器内的运行时

Cursor CLI 以自带完整运行时的压缩包分发，解压在 `/opt/cursor-agent`，
其中包含它自己的 Node 和 ripgrep，不使用镜像中的 Node。
`/usr/local/bin` 下有 `cursor-agent` 和 `agent` 两个符号链接，与官方
安装脚本提供的两个名称一致。

镜像不使用官方安装脚本，因为该脚本解析浮动版本并会修改 shell rc 文件。
Dockerfile 直接下载固定版本的压缩包，并用记录在 `Dockerfile` 中的
SHA-256 校验——Cursor 官方不发布校验和，该值是本项目自行记录的，升级
版本时必须同步更新。

## 安全边界

API key 对容器内的进程可读，容器用户拥有容器内免密 sudo，且默认关闭了
工具审批，因此只应在信任的项目目录中使用。

key 是账号级凭证。建议在 Cursor dashboard 设置 spend limit，并在
key 泄露或不再需要时立即吊销。

---

返回 [README](../../README.md)
