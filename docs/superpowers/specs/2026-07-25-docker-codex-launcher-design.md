# Docker Codex Launcher 设计

## 目标

提供一个可分享的本地开发工具，让 Codex CLI 在 Docker 容器中运行，同时：

- 直接读写调用者当前 Git checkout；
- 共享宿主机的 `CODEX_HOME`，继承配置、记忆、skills、plugins 和文件式认证；
- 自动兼容普通 checkout、linked worktree 和 submodule；
- 支持 Linux、WSL2 和 macOS Docker Desktop；
- 仅显式请求时创建新的隔离 worktree；
- 不通过挂载整个宿主 home、项目父目录或 Docker socket 来换取便利。

本项目交付三个核心组件：

1. `docker-codex`：宿主启动器；
2. `Dockerfile`：多架构开发镜像；
3. `container-entrypoint`：容器用户和运行环境入口。

测试、README 和辅助配置属于这三个组件的配套交付。

## 非目标

- 不替代 Git 分支管理、合并或 push 流程；
- 不自动删除 worktree、分支或未提交内容；
- 不默认挂载 SSH/GPG agent、私钥、宿主 Docker socket或整个 home；
- 不保证宿主 OS keyring/Keychain 可被 Linux 容器读取；
- 不为具体业务仓库硬编码 fixture、端口或外部服务路径；
- 不在容器中运行 Docker daemon。

## 用户接口

默认在当前 checkout 启动：

```sh
docker-codex [--] [codex 参数...]
```

显式创建隔离 worktree 后启动：

```sh
docker-codex --isolated <name> [--] [codex 参数...]
```

附加项目特有的同路径挂载：

```sh
docker-codex --bind /absolute/path[:ro]
```

其他基础选项：

- `--image <ref>`：覆盖默认镜像名 `docker-codex:local`；
- `--build`：启动前重建本地镜像；
- `--help`：输出用法。

启动器默认执行 `codex`，`--` 后的参数逐字传递给 Codex。未知启动器参数直接报错，不做猜测性转发。

## Checkout 与 worktree 发现

启动器从调用时的物理当前目录出发，通过 Git 自身发现：

- `git rev-parse --show-toplevel`
- `git rev-parse --git-dir`
- `git rev-parse --git-common-dir`
- `git rev-parse --show-superproject-working-tree`

不通过判断 `.git` 是文件还是目录来推断仓库类型。

当前 checkout 根目录以宿主绝对路径挂载到容器相同的绝对路径；容器工作目录保持为调用者启动时所在的仓库子目录。这样 linked worktree 的绝对路径回链、Git index 和 `git worktree` 命令保持一致。

若 `git-common-dir` 已包含在 checkout 根目录内，不额外挂载。若它位于 checkout 根目录外，则以读写方式挂载到容器相同路径。linked worktree 的 per-worktree Git 目录通常位于 common dir 内，因此挂载 common dir 即可覆盖两者。若实际布局不满足该关系，启动器应额外挂载缺失的 Git 目录，而不是扩大到父目录。

非 Git 目录启动时直接失败并给出清晰提示。

## 隔离 worktree

`--isolated <name>` 是可选模式，不是默认行为。

启动器在宿主执行 `git worktree add`，基于调用者当前 `HEAD` 创建分支 `codex/<name>`。默认位置：

```text
${DOCKER_CODEX_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/docker-codex}/worktrees/<repo-id>/<name>
```

`repo-id` 由 Git common dir 的规范绝对路径生成稳定、文件系统安全的标识，防止同名仓库互相覆盖。

以下情况 fail-fast：

- 名称为空、包含路径穿越或不能安全用作分支/目录名；
- 目标分支已存在；
- 目标目录已存在；
- 当前为 detached HEAD 且无法确定用户意图；
- Git 拒绝创建 worktree。

容器退出后保留 worktree 和分支。首版不提供自动清理；用户使用标准 `git worktree remove` 和 `git branch -d` 显式处理，避免异常退出或未提交内容导致丢失。

## Docker 挂载与边界

每次启动至少挂载：

1. 当前 checkout：读写、宿主和容器路径相同；
2. 宿主 `${CODEX_HOME:-$HOME/.codex}`：读写，容器固定为 `/codex-home`；
3. 持久构建缓存 volume：容器固定为 `/codex-cache`。

按需增加：

- checkout 外部的 Git common/per-worktree 元数据：读写、路径相同；
- `--bind` 指定目录：同路径读写或只读。

启动器使用 `docker run --mount`，不用 `-v` 字符串语法，以正确处理空格并让错误更明确。

明确禁止启动器自动挂载：

- `/var/run/docker.sock`
- 宿主根目录
- 整个宿主 home
- checkout 的共同父目录
- SSH/GPG agent 或私钥

Linux/WSL2 增加 `host.docker.internal:host-gateway`；macOS Docker Desktop 使用其原生 `host.docker.internal`。

## Codex 状态与认证

容器设置：

```text
CODEX_HOME=/codex-home
```

宿主和容器直接共享整个 Codex home，允许多个 Codex 客户端使用同一份配置、memory 和持久状态。镜像中的 Codex CLI 版本固定，避免不同容器构建意外漂移；可通过构建参数显式升级。

入口阶段执行只读的 `codex login status`。失败时输出警告，再继续启动 Codex，让 Codex 自身的交互登录流程接管；工具不因 keyring 不可见而提前终止。警告说明以下差异：

- `auth.json` 文件式凭据可随 `CODEX_HOME` 共享；
- Linux keyring 与 macOS Keychain 不会因目录挂载而进入容器。

工具不自动修改 `cli_auth_credentials_store`，也不把凭据复制进镜像层。

## 镜像

镜像使用同时提供 amd64/arm64 的 Debian 系基础镜像，本地构建时跟随宿主 Docker 架构。包含：

- Rust stable 最小工具链；
- Node.js LTS 与 pnpm；
- 固定版本的 Codex CLI；
- Git、OpenSSH client、curl、CA certificates；
- 常用本机构建依赖，如 C/C++ toolchain、pkg-config、OpenSSL headers、clang、cmake；
- `gosu` 或等价的可靠降权工具。

不使用 `--privileged`，不在镜像中写入任何宿主配置或凭据。

Apple Silicon 默认产出 Linux arm64 开发产物。项目若要求 Linux amd64 产物，应由用户显式选择 `--platform linux/amd64` 或使用项目自身交叉编译流程；启动器不静默模拟另一架构。

## 容器入口与权限

容器以 root 进入 `container-entrypoint`，只完成以下受限初始化：

1. 读取启动器传入的宿主 UID/GID；
2. 选择或创建对应的容器用户/组，兼容 macOS 常见 UID 501/GID 20 已被基础镜像占用的情况；
3. 创建并修正容器私有 home 与 `/codex-cache` 权限；
4. 不递归 `chown` checkout、Git metadata 或 `/codex-home`；
5. 降权为宿主 UID/GID；
6. 验证 Codex 登录状态并 `exec codex "$@"`。

所有信号通过 `exec` 直接交给 Codex，确保 Ctrl-C 和 Docker stop 行为正确。

## 跨平台约束

宿主启动器使用 macOS 自带版本也支持的 Bash 3 语法。动态 Docker 参数和 Codex 透传参数使用索引数组保存，确保空格、通配符和引号边界不被二次解释。脚本不依赖：

- Bash 4 专属功能，包括关联数组、`mapfile` 和大小写转换扩展；
- GNU `readlink -f`；
- GNU `stat -c`；
- GNU `date -d`；
- GNU `sed -r`。

规范路径优先由 `git rev-parse --path-format=absolute` 和 `cd ... && pwd -P` 获取。Docker Desktop 路径不在允许共享范围时，保留 Docker 原始错误并补充操作提示。

macOS 下源码保持 bind mount，Cargo target、pnpm store 和其他高频缓存放在 Docker volume 中，避免大量小文件跨虚拟文件系统。源码中的大小写行为仍受宿主文件系统影响，工具不尝试伪装大小写敏感语义。

## 错误处理

启动器遵循 fail-fast：

- 缺少 `git`、`docker` 或 Docker daemon 不可用；
- 当前目录不在 Git checkout；
- `CODEX_HOME` 不存在；
- bind 源不存在；
- Docker 镜像不存在且未请求构建；
- worktree/分支名称冲突；
- 登录状态不可用且无法交互修复。

错误信息包含失败对象和建议，不输出认证文件内容、token 或完整 Docker 环境。

容器启动失败不删除已创建的 worktree，因为其中可能已存在用户可恢复状态。

## 测试与验收

宿主脚本通过无第三方测试框架的 shell 测试覆盖：

- 普通 checkout 只挂载 checkout；
- linked worktree 自动补挂 common Git dir；
- checkout 和 Codex home 含空格；
- 当前子目录被保留为容器工作目录；
- `--bind` 读写/只读；
- 非 Git 目录和缺失路径 fail-fast；
- `--isolated` 创建预期分支与目录，冲突时不覆盖；
- Linux 与 Darwin 分支生成预期 Docker 参数；
- Codex 参数逐字传递。

测试使用临时 Git 仓库和 fake `docker` 捕获参数，不启动真实 Codex。

入口脚本通过容器或受控 fake 命令验证：

- UID/GID 已存在与不存在两类情况；
- GID 已占用时仍可按数值身份降权；
- 只修改容器私有目录权限；
- 信号和退出码透传。

最终验收至少包括：

1. shell 静态检查；
2. 全部脚本测试；
3. Dockerfile 语法/build check；
4. Linux 本机实际 build；
5. 普通临时仓库实启；
6. linked worktree 实启并运行 Git 只读命令；
7. 文档记录 macOS 需要由真实 Docker Desktop/Apple Silicon 环境补做的验证项。

若当前环境没有 macOS，不能声称已完成 macOS 实机验证，只能声称跨平台逻辑和多架构镜像定义已覆盖。
