# 安全边界

本文说明容器的权限模型、默认挂载策略以及启动器明确不会挂载的内容。
评估是否可以在某个项目中安全使用本工具时阅读本文。

容器首先以 root 身份进入 entrypoint，只用于：

- 映射宿主 UID/GID
- 初始化容器私有 home
- 初始化 `/codex-cache`
- 配置运行用户

随后通过 `gosu` 以宿主机的数值 UID/GID 运行所选 agent。入口脚本不会递归
修改 checkout、Git metadata 或 `/codex-home` 的所有权，因此普通命令在
bind mount 中创建的文件仍属于宿主用户。

容器运行用户拥有免密 sudo，可以在必要时获得容器内 root 权限，但不会被
加入 root 组。

Codex 固定使用 `--yolo`；Claude 固定使用
`--dangerously-skip-permissions`。两者的内部审批都会关闭，所有读写挂载
完整暴露给 agent，Docker 是外层隔离边界。启动器不会使用 `--privileged`。

Codex 收到完整的宿主 Codex home。Claude 不收到完整 `~/.claude`：官方
订阅只挂载单个 `.credentials.json`，API/custom 只挂载选中的 profile，
其他 session 状态来自独立 data root。profile secret 和 OAuth 凭证对选中
容器可读；OAuth 文件还是读写挂载，以允许刷新。详见
[Claude Code 集成](claude.md)。

启动器绝不会自动挂载：

- `/var/run/docker.sock`
- 宿主机根目录或整个 home
- checkout 的共同父目录
- SSH/GPG agent 或私钥
- 无关仓库

所选 agent 可以自由修改所有被明确以读写方式挂载的路径。除此之外的内容仍由
Docker 隔离。

---

返回 [README](../../README.md)
