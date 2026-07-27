# Codex 配置、认证与 Git 推送凭证

本文说明宿主 Codex home 如何与容器共享、认证信息的操作系统边界，以及
如何显式地向容器提供 Git 推送凭证。配置认证或需要从容器内 `git push`
时阅读本文。

## Codex 配置、记忆与认证

宿主机完整的 `${CODEX_HOME:-$HOME/.codex}` 会以读写方式挂载到
`/codex-home`，同时容器内设置：

```text
CODEX_HOME=/codex-home
```

因此宿主和容器可以共享：

- Codex 配置
- 本地 memory
- session 与其他持久状态
- skills 和 plugins
- 文件形式保存的认证信息

宿主和容器中的多个 Codex 进程共享状态，其行为与宿主机上同时运行多个
Codex 进程相同。升级状态格式时，建议让镜像内 Codex CLI 与宿主版本保持
一致。

认证存在操作系统边界：

- 保存在 `auth.json` 中的凭据可以通过目录挂载共享
- Linux keyring 和 macOS Keychain 不会进入 Linux 容器

入口脚本会执行 `codex login status`。如果检查失败，它会输出警告但继续
启动，让 Codex 自己接管后续交互登录。启动器不会修改
`cli_auth_credentials_store`，也不会把凭据复制进镜像层。

如果 `config.toml` 引用了其他宿主机绝对路径，需要通过 `--bind` 补充挂载。
配置中的 STDIO MCP 命令和本地工具也必须已经安装在镜像中，或者显式挂载到
容器内。

## 向容器提供 Git 推送凭证

容器默认没有任何 Git 凭证，推送会失败。启动器提供两种显式 opt-in
方式，把 token 以只读文件挂载到容器内固定路径
`/codex-credentials/pat`，并通过 `GIT_CONFIG_*` 环境变量注入通用的
credential helper 和 origin host 的 SSH→HTTPS `insteadOf` 重写。这些
配置只存在于容器进程的环境中，不会写入任何与宿主共享的配置文件。

推荐把 token 保存在 checkout 之外的专用文件中：

```bash
install -d -m 700 ~/.local/share/docker-codex/pat
$EDITOR ~/.local/share/docker-codex/pat/github-<repo>   # 只写 token 一行
chmod 600 ~/.local/share/docker-codex/pat/github-<repo>

docker-codex --pat-path ~/.local/share/docker-codex/pat/github-<repo>
```

可以用 `DOCKER_CODEX_PAT_PATH` 设置默认路径，避免每次输入。

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
