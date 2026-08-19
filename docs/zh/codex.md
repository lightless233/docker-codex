# Codex 自定义 endpoint profile

本文说明如何为 Codex 准备多个托管 profile，在官方账号和不同的 Responses
API endpoint 之间切换，以及如何把 endpoint 配置和 API key 保存在同一个受保护
的 TOML 文件中。托管布局同时保留宿主 Codex 的原生 `--profile` 兼容性。

## 创建与切换

docker-agent 托管 profile 位于：

```text
${DOCKER_AGENT_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent}/codex/profiles/<name>.config.toml
```

创建器同时在 Codex 原生位置建立一个指向托管文件的兼容链接：

```text
$CODEX_HOME/<name>.config.toml
```

默认 `CODEX_HOME` 是 `~/.codex`。因此同一 profile 可由宿主 Codex 和容器
选择，但真实密钥文件与 Claude profile 一起归入 docker-agent 配置根。交互
创建一个最小 profile：

```bash
docker-codex --create-profile
```

命令依次读取 profile 名称、Responses API endpoint、模型名称和 API key。
key 输入显示为星号。创建过程不要求 Docker daemon 或 Git repository，不会
修改 `config.toml`、`auth.json` 或已有 profile，也不会覆盖托管文件或原生
位置的同名条目。

选择 profile：

```bash
docker-codex --profile deepseek
# 等价入口
docker-agent codex --profile deepseek

# 宿主 Codex 也可直接选择同一个原生 profile
codex --profile deepseek
```

没有 `--profile` 时，启动器保持原有行为，Codex 继续使用
`$CODEX_HOME/config.toml` 和现有认证。可以同时保存任意多个
`<name>.config.toml`，每次启动只选择一个。容器只读挂载当前选择的托管文件；
其他兼容链接在容器内没有可达的目标。

profile 名称必须以字母或数字开头，后续只能使用字母、数字、点、下划线和
连字符。`--profile` 会拒绝缺失、符号链接、目录、非当前用户所有、权限不是
精确 `0600`，或位于当前 checkout/`CODEX_HOME` 内的托管文件。原生位置必须
是指向对应托管文件的兼容链接；缺失时启动器会安全创建，存在冲突或指向其他
文件时则拒绝启动。

为兼容已有配置，如果没有同名托管文件，启动器仍接受权限合格的旧式
`$CODEX_HOME/<name>.config.toml` 普通文件。旧式文件会随完整 `CODEX_HOME`
挂载，不具备“容器只看到当前 profile”的隔离效果。

## 单文件格式

创建器生成的文件类似：

```toml
model_provider = "docker-agent-deepseek"
model = "deepseek-chat"
review_model = "deepseek-chat"

[model_providers."docker-agent-deepseek"]
name = "deepseek"
base_url = "https://relay.example.com/v1"
wire_api = "responses"
experimental_bearer_token = "sk-replace-me"
```

`experimental_bearer_token` 会作为 provider 的 Bearer token，因此不需要第二个
`auth.json`。使用这种方式时，不要在同一个 provider 中再设置 `env_key`、
`[model_providers.<id>.auth]` 或 `requires_openai_auth = true`。

OpenAI 官方配置参考支持直接 bearer token，但明确建议优先使用 `env_key`。
本项目仍提供单文件模式，以满足 profile 可携带 endpoint 和凭证、且不把 key
放入 Docker 参数或环境变量的使用方式；相应地，文件必须保持 `0600`。参见
[OpenAI Codex 配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)。

## 从中转站示例转换

如果中转站给出的示例使用 `auth.json` 和：

```toml
requires_openai_auth = true
```

要改成单文件 profile，只需删除该行，并在同一个 provider table 中加入：

```toml
experimental_bearer_token = "sk-replace-me"
```

其他确定与 endpoint 匹配的模型设置可以继续放在该 profile 中，例如：

```toml
model_reasoning_effort = "xhigh"
model_context_window = 1000000
model_auto_compact_token_limit = 900000
```

不要盲目复制模型上下文数值；它们必须与中转站实际暴露的模型一致，否则可能
导致过晚压缩或请求被拒绝。

当前镜像的 Codex 0.148.0 已移除 `responses_websockets_v2` feature flag，
不要再添加：

```toml
[features]
responses_websockets_v2 = true
```

只有 endpoint 确实实现 Responses WebSocket 时，才在 provider table 中添加：

```toml
supports_websockets = true
```

否则保留创建器的默认配置，Codex 使用 Responses SSE。当前官方 schema 也没有
截图中的顶层 `disable_response_storage` 或 `network_access = "enabled"`；不要把
它们放入需要通过 `--strict-config` 校验的 0.148.0 profile。

## 安全边界与删除

profile 内含明文 API key。不要把它提交到 Git、发送给他人或存放在 checkout。
启动器不会把 key 内容放入 `docker run` 参数，只把当前托管文件只读挂载到
容器；未选择的托管 profile 不会被挂载。Codex 以 `--yolo` 运行，因此选中的
容器进程与它执行的命令仍能读取当前文件。只使用权限最小、可撤销、有有效期
的 key。

删除一个 profile 时使用精确文件名：

```bash
config_root=${DOCKER_AGENT_CONFIG_HOME:-${XDG_CONFIG_HOME:-"$HOME/.config"}/docker-agent}
codex_home=${CODEX_HOME:-"$HOME/.codex"}
rm -- "$codex_home/deepseek.config.toml"
rm -- "$config_root/codex/profiles/deepseek.config.toml"
```

先删除兼容链接，再删除托管文件。删除 profile 不会删除已有 session。若原生
位置是普通文件而不是链接，则它是旧式 profile；确认内容后只删除该普通文件。

---

返回 [README](../../README.md)
