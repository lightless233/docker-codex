# Agent 配置、认证与 Git 推送凭证

本文说明 Codex 与 Claude Code 的认证边界，以及如何显式地向容器提供 Git
推送凭证。配置认证或需要从容器内 `git push` 时阅读本文。Kimi Code 共享
整个数据根，认证方式见 [Kimi Code 集成](kimi.md)；Cursor Agent 使用
受保护的 API key 文件，见 [Cursor Agent 集成](cursor-agent.md)。

## Codex 配置、记忆与认证

宿主机完整的 `${CODEX_HOME:-$HOME/.codex}` 会以读写方式挂载到容器内相同
的逻辑绝对路径，同时容器内 `CODEX_HOME` 也使用这个路径。例如宿主使用
`/home/lightless/.codex` 时，容器收到：

```text
source=/home/lightless/.codex
target=/home/lightless/.codex
CODEX_HOME=/home/lightless/.codex
```

如果宿主 `CODEX_HOME` 是符号链接，Docker source 使用解析后的物理目录，
target 和 `CODEX_HOME` 仍保留宿主使用的逻辑路径。容器的
`HOME=/home/codex` 不变，不会因此挂载整个宿主 home。

同一个物理目录还会挂载到 `/codex-home`，但它只作为旧版 docker-codex
写入的绝对 session 路径的兼容别名；新会话不会继续把这个别名写进状态数据库。

因此宿主和容器可以共享：

- Codex 配置
- 本地 memory
- session 与其他持久状态
- skills 和 plugins
- 文件形式保存的认证信息

宿主和容器中的多个 Codex 进程共享状态，其行为与宿主机上同时运行多个
Codex 进程相同。升级状态格式时，建议让镜像内 Codex CLI 与宿主版本保持
接近；版本一致不能替代 session 路径修复。

### 修复旧 session 路径

旧版容器创建的 session 可能仍在状态数据库中引用
`/codex-home/sessions/...`。先退出宿主和容器内所有 Codex 进程，再显式运行：

```bash
docker-codex --repair-sessions
# 等价入口
docker-agent codex --repair-sessions
```

修复命令使用镜像内工具，不要求宿主安装 `sqlite3` 或 `jq`。它取得有界的
数据库写锁，先在当前 `CODEX_HOME/session-repair-backups` 下创建包含 WAL 已提交
数据的一致性备份并打印完整路径，然后只迁移以下记录：rollout 路径使用历史
前缀、文件仍位于当前 `sessions` 目录内且可读、JSON metadata 可解析、metadata
中的 session ID 与数据库 row ID 一致。

成功输出还会包含更新数和跳过数；缺失、越界、损坏或 ID 不匹配的记录只会跳过，
不会删除 session 文件或数据库 row。重复运行是安全的，已经迁移的记录不会再次
变化。普通 `docker-codex` 启动不会自动运行修复。

若数据库被其他 Codex 进程持续锁定、schema 不受支持或完整性检查失败，命令会
整体回滚并非零退出。工具不会清理已经发布的备份。未迁移的旧 session 仍可借助
容器内 `/codex-home` 兼容别名尝试恢复；从备份还原数据库必须由用户在所有 Codex
进程退出后显式完成。

认证存在操作系统边界：

- 保存在 `auth.json` 中的凭据可以通过目录挂载共享
- Linux keyring 和 macOS Keychain 不会进入 Linux 容器

入口脚本会执行 `codex login status`。如果检查失败，它会输出警告但继续
启动，让 Codex 自己接管后续交互登录。启动器不会修改
`cli_auth_credentials_store`，也不会把凭据复制进镜像层。

如果 `config.toml` 引用了其他宿主机绝对路径，需要通过 `--bind` 补充挂载。
配置中的 STDIO MCP 命令和本地工具也必须已经安装在镜像中，或者显式挂载到
容器内。

自定义 Responses endpoint 可以使用多个原生 Codex profile。启动器支持
`--create-profile` 和 `--profile NAME`。托管文件位于 docker-agent 配置根的
`codex/profiles` 下，并通过 `$CODEX_HOME` 中的兼容链接供宿主 Codex 使用；
单个权限为 `0600` 的 TOML 保存 endpoint 与 bearer token。具体格式和安全限制见
[Codex 自定义 endpoint profile](codex.md)。

## Claude Code 认证与状态

Claude 不挂载完整 `~/.claude`。Linux/WSL 的官方订阅模式只把宿主
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json` 作为单个读写文件
挂到每个 repo/worktree/连接独立的 state 中；API key 和自定义 endpoint
则来自 checkout 外、权限为 `0600` 的 profile。macOS Keychain 不能被
Linux 容器复用。

profile 格式、连接参数、状态路径和清理方法见
[Claude Code 集成](claude.md)。

## 向容器提供 Git 推送凭证

容器默认没有任何 Git 凭证，推送会失败。启动器提供两种显式 opt-in
方式，把 token 以只读文件挂载到容器内固定路径
`/codex-credentials/pat`，并通过 `GIT_CONFIG_*` 环境变量注入通用的
credential helper 和 origin host 的 SSH→HTTPS `insteadOf` 重写。这些
配置只存在于容器进程的环境中，不会写入任何与宿主共享的配置文件。

推荐把 token 保存在 checkout 之外的专用文件中：

```bash
install -d -m 700 ~/.local/share/docker-agent/pat
$EDITOR ~/.local/share/docker-agent/pat/github-<repo>   # 只写 token 一行
chmod 600 ~/.local/share/docker-agent/pat/github-<repo>

docker-agent codex --pat-path ~/.local/share/docker-agent/pat/github-<repo>
```

可以用 `DOCKER_AGENT_PAT_PATH` 设置默认路径，避免每次输入；旧的
`DOCKER_CODEX_PAT_PATH` 仍作为兼容 fallback。

`--pat TOKEN` 直接在命令行传入 token：启动器会把它写入 data home 下的
`pat/<repo-id>`（目录 700、文件 600），再走相同的挂载逻辑。注意 token
值会留在 shell 历史和进程列表里，**这只是无法准备 token 文件时的兜底
方案，优先使用 `--pat-path`**；确实需要用 `--pat` 时，请确认 token 按
最小权限签发、可随时撤销且有效期短。

凭证进入容器后，agent 可以读取它。请只使用限定单个仓库、权限最小、
带过期时间的 token（如 GitHub fine-grained PAT），不再需要时在服务端
撤销即可。

---

返回 [README](../../README.md)
