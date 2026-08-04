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
完整暴露给 agent。默认模式下 Docker 是外层隔离边界。启动器不会使用
`--privileged`。

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

## 显式的宿主 Docker 权限

`--host-docker` 会把宿主 Docker Unix socket 挂载到容器内的
`/var/run/docker.sock`，设置 `DOCKER_HOST`，并把运行用户加入 socket 的
数值 GID。启动器会在每次启用时输出中英双语的大幅警告。

这相当于把宿主 Docker API 的完整控制权交给 agent：它不仅能操作所有宿主
容器、镜像、网络和卷，还能创建容器并挂载任意宿主路径，从而读写宿主文件。
因此该权限在实际效果上等同于宿主 root 权限。把 socket 以只读 bind mount
挂载也不会把 Docker API 变成只读，所以本项目没有提供这种伪隔离模式。

该选项不会挂载宿主 `~/.docker`。默认 socket 是
`/var/run/docker.sock`；特殊环境可通过宿主环境变量
`DOCKER_AGENT_DOCKER_SOCKET` 指定其他绝对路径。由 agent 创建的容器不会
自动加入 `docker-agent` 网络；需要互通时，创建容器时应显式指定
`--network docker-agent`。

所选 agent 可以自由修改所有被明确以读写方式挂载的路径。除此之外的内容仍由
Docker 隔离；启用 `--host-docker` 后不再具有这层宿主隔离。

---

返回 [README](../../README.md)
