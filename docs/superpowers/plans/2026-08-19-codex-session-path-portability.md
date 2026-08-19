# Codex 宿主与容器会话路径互通实施计划

**设计依据：** [2026-08-19-codex-session-path-portability-design.md](../specs/2026-08-19-codex-session-path-portability-design.md)

**目标：** 让宿主和容器中的 Codex 对同一个 `CODEX_HOME` 使用相同的逻辑绝对
路径，使新会话可以双向列出和恢复；同时保留 `/codex-home` 历史兼容入口，并提供
显式、带一致性备份、可回滚且幂等的旧路径修复命令。

**实现策略：** 启动器负责解析宿主 `CODEX_HOME` 的逻辑路径与物理路径、构造同路径
挂载和兼容挂载，并把 `--repair-sessions` 分流到非交互维护模式。迁移本身放在镜像内
的独立 Python 工具中，使用 Python 标准库的 SQLite 与 JSON 支持完成锁定、备份、
校验和单事务更新。普通 Codex 启动路径不读取或改写状态数据库。

**技术约束：** Bash 3.2+、Docker bind mount、Python 3 标准库、SQLite、现有无框架
shell 测试；不要求宿主安装 `sqlite3` 或 `jq`，不递归修改共享目录权限，不扩大宿主
挂载范围，不把版本一致性当作路径修复的前置条件。

## 实施顺序

### Task 1：先固定启动器路径契约的回归测试

**涉及文件：**

- 修改 `tests/launcher_test.bash`
- 必要时修改 `tests/testlib.bash`

- [ ] 把现有固定断言 `target=/codex-home` 改成设计后的契约：Docker source 使用解析
  符号链接后的物理目录，主 target 和容器 `CODEX_HOME` 保持宿主的逻辑绝对路径，
  同一 source 另挂到 `/codex-home` 作为历史兼容别名。
- [ ] 覆盖默认路径、自定义路径、路径含空格和 `CODEX_HOME` 为符号链接的情况，明确
  验证逻辑路径不会被 `pwd -P` 替换；同时确认容器 `HOME` 没有变成宿主 home。
- [ ] 保留普通 checkout、linked worktree 和非 Git 目录的现有断言，并确认 Claude、
  Kimi、Cursor Agent 的数据目录挂载不受 Codex 专用改动影响。
- [ ] 增加失败边界：不存在、非目录、非绝对或与既有 Docker target 冲突的路径必须在
  启动 Codex 前给出明确错误，不能静默回退到 `/codex-home`。

**阶段证据：** 新增断言在现有实现上应失败，且失败点只指向 Codex home 的 target、
环境变量或校验语义，不应造成其他 agent 测试回归。

### Task 2：实现逻辑路径与物理路径分离的同路径挂载

**涉及文件：**

- 修改 `docker-agent`
- 修改 `container-entrypoint`

- [ ] 在 Codex runtime 配置中保留用户实际传给宿主 Codex 的逻辑绝对路径，同时单独
  解析物理目录；逻辑路径用于主挂载 target 和容器 `CODEX_HOME`，物理路径只用于
  Docker source、存在性检查和安全边界。
- [ ] 为同一个物理目录同时构造逻辑同路径挂载和 `/codex-home` 兼容挂载。确保主挂载
  决定新会话写入的绝对路径，兼容挂载只让旧 rollout 路径继续可达。
- [ ] 在 entrypoint 降权后、启动 Codex 或修复工具前，以宿主 UID/GID 验证逻辑
  `CODEX_HOME` 可读写；失败时报告目标路径并退出，不执行递归 `chown`/`chmod`。
- [ ] 保持 `HOME=/home/codex`、现有 cache、checkout、Git metadata、PAT、网络和
  剪贴板行为不变，并运行 Task 1 的路径矩阵。

**阶段证据：** fake Docker 日志应显示 source/target/env 三者符合设计；普通 Codex
启动不会出现任何数据库修复命令，其他 launcher 测试保持通过。

### Task 3：加入显式修复入口和独立维护模式

**涉及文件：**

- 修改 `docker-agent`
- 修改 `tests/launcher_test.bash`
- 修改 `tests/install_test.bash`

- [ ] 在 `docker-codex` 与 `docker-agent codex` 的帮助和参数解析中加入
  `--repair-sessions`；该参数由启动器消费，不能透传给 Codex，也不能用于其他 agent。
- [ ] 将修复请求分流到一次性非交互维护执行路径，复用镜像选择/构建、宿主 UID/GID
  和 Codex home 路径解析，但不启动 Codex、不创建 worktree、不注入 PAT，也不执行
  正常 agent 的网络、剪贴板和项目挂载准备。
- [ ] 对与维护模式无意义或会改变执行边界的参数组合给出明确错误；镜像不存在、镜像
  内缺少修复工具或同路径挂载失败时，必须在修改共享状态前非零退出。
- [ ] 用 fake Docker 证明两个公开入口执行相同的修复命令并正常退出，同时证明普通
  启动和 `-- --repair-sessions` 的 Codex 原生参数边界没有被误判。

**阶段证据：** launcher/install 测试应能区分“启动器维护选项”和“传给 Codex 的参数”，
且修复模式的 Docker 参数不包含 Codex 命令、项目凭证或交互 TTY。

### Task 4：实现镜像内会话路径修复工具

**涉及文件：**

- 新增 `container-codex-session-repair`
- 修改 `Dockerfile`

- [ ] 用 Python 标准库实现单一用途的容器命令，只处理当前 `CODEX_HOME` 下受支持的
  状态数据库和 `threads(id, rollout_path)` 契约；任何能力、文件或 schema 前置条件
  不满足时，在写入前失败。
- [ ] 使用有界超时取得 SQLite 写锁，在锁保护期间通过独立 SQLite 连接创建包含 WAL
  已提交数据的一致性备份；备份先写临时文件再原子发布，使用受限权限，并记录可直接
  在宿主访问的逻辑绝对路径。
- [ ] 在更新前验证源数据库和备份完整性、表与字段；只枚举
  `/codex-home/sessions/` 前缀记录。把旧前缀后的相对部分映射到逻辑
  `CODEX_HOME/sessions`，并通过规范化后的 sessions 根做 containment 校验，拒绝
  `..`、越界符号链接和其他路径穿越。
- [ ] 对每条候选记录验证文件存在、为普通文件、当前 UID 可读、JSON session metadata
  可解析且 metadata ID 与数据库 row ID 完全一致。缺失、不可读、格式错误或 ID 不
  匹配只计入跳过，不输出路径内的会话正文或其他敏感内容。
- [ ] 把所有通过校验的 `rollout_path` 更新放在同一个事务中，在提交前再次执行完整性
  检查；锁超时、写入失败或检查失败时整体回滚并非零退出，不删除 rollout、row、
  历史索引或已有备份。
- [ ] 成功时只输出必要审计信息：完整宿主备份路径、更新数量、跳过数量；没有候选记录
  和重复执行都成功，后者更新数量必须为零。

**阶段证据：** 工具的所有状态变更都位于“取得锁—发布备份—单事务更新—完整性检查—
提交”边界内；正常 Codex 命令不会导入或调用该工具。

### Task 5：建立迁移安全与幂等测试矩阵

**涉及文件：**

- 新增 `tests/session_repair_test.py`
- 修改 `tests/run.bash`
- 必要时修改 `tests/testlib.bash`

- [ ] 使用临时 `CODEX_HOME` 和 Python SQLite fixture 覆盖成功迁移，确认备份包含 WAL
  中已提交记录、只改变 `rollout_path`，且备份可以独立打开并通过完整性检查。
- [ ] 在同一 fixture 混合有效记录、文件缺失、不可读文件、损坏 JSON、metadata ID
  不匹配、非目标前缀、`..` 路径和越界符号链接，验证只有有效记录更新，跳过统计准确，
  输出不泄露会话正文。
- [ ] 覆盖路径含空格、自定义逻辑路径和符号链接路径，验证更新结果保留宿主逻辑
  `CODEX_HOME`，而不是测试机解析后的物理路径。
- [ ] 覆盖数据库缺失、损坏、未知 schema、持续写锁和事务中写入失败；验证非零退出、
  有界等待、无部分提交，并且已发布的一致性备份不会被清理。
- [ ] 对成功迁移后的同一数据库再次执行，验证更新数为零、row 与 rollout 文件不再
  变化；普通启动测试继续证明不会隐式迁移。

**阶段证据：** 测试只使用临时目录，不触碰开发者真实 `CODEX_HOME`；成功、跳过、
整体失败和重复执行四类结果均有数据库级断言。

### Task 6：验证镜像集成、降权权限和真实 CLI 边界

**涉及文件：**

- 修改 `tests/image_test.bash`
- 修改 `tests/entrypoint_test.bash`
- 视测试夹具需要修改 `Dockerfile`

- [ ] 验证镜像包含可执行的修复工具及其 Python/SQLite 能力，入口脚本以宿主数值 UID/GID
  执行它，并保持私有 `HOME`。
- [ ] 验证逻辑 `CODEX_HOME` 可读写时 Codex 和修复命令都能启动；权限不足时两者均在
  agent 执行前清晰失败，且共享目录和父目录的 mode/owner 不被修改。
- [ ] 用临时 bind mount 通过真实镜像执行一次 `--repair-sessions` 集成场景，核对宿主
  可见的备份、数据库更新和第二次运行的幂等结果。
- [ ] 确认自定义旧镜像缺少修复命令时只返回能力错误，不对临时数据库产生任何改动。

**阶段证据：** host-only 测试与真实容器测试得到相同迁移结果；容器创建的文件归宿主
UID/GID 所有，没有扩大权限或新增特权参数。

### Task 7：更新中英文用户契约与恢复说明

**涉及文件：**

- 修改 `README.md`
- 修改 `README.en.md`
- 修改 `docs/zh/credentials.md`
- 修改 `docs/en/credentials.md`
- 修改 `docs/zh/security.md`
- 修改 `docs/en/security.md`
- 修改 `docs/zh/platforms.md`
- 修改 `docs/en/platforms.md`

- [ ] 把“宿主目录固定挂到 `/codex-home`”改为“主挂载使用宿主逻辑绝对路径，
  `/codex-home` 仅保留为历史 rollout 兼容别名”，并说明容器 `HOME` 仍然私有。
- [ ] 文档化两个 `--repair-sessions` 入口、迁移前退出相关 Codex 进程的要求、备份输出、
  成功/跳过/失败语义和幂等行为；明确普通启动不会自动迁移。
- [ ] 说明迁移失败不会删除会话，未迁移旧会话仍可先从容器尝试恢复；恢复备份是用户
  显式操作，工具不自动清理备份。
- [ ] 更新 Linux/WSL2 与 macOS Docker Desktop 的同路径文件共享要求，以及版本接近
  只是兼容性建议、不能替代路径修复。

**阶段证据：** 中英文 help、README 和专题文档对主路径、兼容别名、显式修复和失败
恢复使用相同术语，不再把 `/codex-home` 描述为新会话的 `CODEX_HOME`。

### Task 8：执行最终回归与双向恢复验收

- [ ] 运行 launcher、repair、entrypoint、install 和完整 host-only 测试套件，并执行
  Bash 语法检查、ShellCheck、Python 语法/单元测试及 `git diff --check`。
- [ ] 构建项目镜像并运行 image tests，确认固定 Codex 版本、现有剪贴板行为和其他
  agent 集成没有被路径改动破坏。
- [ ] 使用隔离的临时 Codex home 做真实端到端验收：容器新建会话后由宿主 resume，
  宿主新建会话后由容器 resume；数据库中的新 rollout path 在两侧均指向同一文件。
- [ ] 为旧 `/codex-home/sessions/...` fixture 验证迁移前容器兼容恢复、迁移后宿主恢复，
  并再次执行修复确认零更新。
- [ ] 保存 Linux/WSL 的真实执行证据；macOS 无可用 runner 时至少保存参数构造测试，
  并把 Docker Desktop 实机同路径挂载/恢复列为发布前平台门禁，不以推测代替通过。

**完成标准：** 设计 spec 的八项验收标准都有自动化证据或明确的平台门禁；任何真实用户
状态迁移仍需用户显式运行 `--repair-sessions`，本实施与测试阶段不得操作当前
`/home/lightless/.codex` 数据库。
