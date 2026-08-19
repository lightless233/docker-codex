# Codex custom endpoint profiles

This page explains how to keep multiple managed Codex profiles, switch between
official authentication and Responses API endpoints, and store an endpoint
configuration and API key in one protected TOML file. The managed layout keeps
native host-Codex `--profile` compatibility.

## Create and select profiles

docker-agent managed profiles live at:

```text
${DOCKER_AGENT_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/docker-agent}/codex/profiles/<name>.config.toml
```

That stable management path is a symlink. The real file lives in the
per-profile `codex/profiles/<name>/config.toml` directory. The separate
directory lets Codex replace its config atomically while the container still
sees only the selected profile.

The creator also adds a compatibility link at Codex's native location:

```text
$CODEX_HOME/<name>.config.toml
```

`CODEX_HOME` defaults to `~/.codex`. The host and container can therefore
select the same profile while the real secret file is grouped with Claude
profiles under the docker-agent config root. Create a minimal profile
interactively:

```bash
docker-codex --create-profile
```

The command reads a profile name, Responses API endpoint, model name, and API
key. Key input is masked. Creation does not require the Docker daemon or a Git
repository, does not modify `config.toml` or `auth.json`, and never overwrites
an existing managed file or native-path entry.

Select a profile:

```bash
docker-codex --profile deepseek
# Equivalent entry point
docker-agent codex --profile deepseek

# Host Codex can select the same native profile
codex --profile deepseek
```

Without `--profile`, the launcher preserves its existing behavior and Codex
uses the normal `config.toml` and authentication state. Keep as many
`<name>.config.toml` files as needed; one is selected per launch. The container
gets a read-write mount of only that profile's directory so Codex can persist
interactive settings such as `projects.<path>.trust_level`; other compatibility
links have no reachable target inside the container. The first launch migrates
an older flat managed file into its own directory and leaves a link at the old
path.

Names must start with a letter or digit and may then contain letters, digits,
dots, underscores, and hyphens. `--profile` rejects a missing or misdirected
management link, an unsafe profile directory, a real file not owned by the
invoking user or with a mode other than exactly `0600`, or a managed file
inside the current checkout or `CODEX_HOME`. The
native path must be a compatibility link to the matching managed file. The
launcher safely creates a missing link but rejects conflicts and links to a
different target.

For compatibility, when no same-named managed file exists, the launcher still
accepts a valid legacy regular file at `$CODEX_HOME/<name>.config.toml`. Legacy
files are exposed with the complete `CODEX_HOME` mount and do not provide the
"only the selected profile is visible" isolation.

## One-file format

The creator writes a file like this:

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

`experimental_bearer_token` supplies the provider Bearer token, so no second
`auth.json` is needed. Do not combine it in the same provider with `env_key`,
`[model_providers.<id>.auth]`, or `requires_openai_auth = true`.

The official reference supports a direct bearer token but recommends
`env_key`. This project offers the one-file mode so a protected profile can
carry both endpoint configuration and credentials without putting the key in
Docker arguments or environment variables. Keep the file at mode `0600`. See
the [OpenAI Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).

## Converting a relay example

When a relay example uses `auth.json` together with:

```toml
requires_openai_auth = true
```

convert it to one file by removing that line and adding this inside the same
provider table:

```toml
experimental_bearer_token = "sk-replace-me"
```

Provider-specific model settings may remain in the selected profile, for
example:

```toml
model_reasoning_effort = "xhigh"
model_context_window = 1000000
model_auto_compact_token_limit = 900000
```

Do not copy context limits blindly. They must match the model exposed by the
relay or compaction may happen too late and requests may be rejected.

Codex 0.148.0 in the current image has removed the
`responses_websockets_v2` feature flag. Do not add:

```toml
[features]
responses_websockets_v2 = true
```

Only add this to the provider table when the endpoint actually implements the
Responses WebSocket transport:

```toml
supports_websockets = true
```

Otherwise keep the creator's default and use Responses SSE. The current
official schema also does not list the screenshot's top-level
`disable_response_storage` or `network_access = "enabled"`; omit them from a
0.148.0 profile that must pass `--strict-config`.

`features.codex_hooks` is also deprecated; use `features.hooks`. The launcher
atomically migrates that old key in ordinary managed profiles while preserving
its Boolean value. For a hand-written profile containing TOML multiline
strings, it asks for a manual migration rather than risk changing string
contents.

## Security boundary and deletion

The profile contains a plaintext API key. Never commit it, send it to another
person, or store it in a checkout. The launcher does not put the key contents
in `docker run` arguments, and unselected managed profiles are not mounted. To
let Codex save trust and other interactive config, the selected profile is
read-write: Codex and commands it runs can read, modify, or delete it. Use
minimally scoped, revocable, expiring keys and back up profiles when needed.

Delete one profile by its exact filename:

```bash
config_root=${DOCKER_AGENT_CONFIG_HOME:-${XDG_CONFIG_HOME:-"$HOME/.config"}/docker-agent}
codex_home=${CODEX_HOME:-"$HOME/.codex"}
rm -- "$codex_home/deepseek.config.toml"
rm -- "$config_root/codex/profiles/deepseek.config.toml"
rm -r -- "$config_root/codex/profiles/deepseek"
```

Remove both compatibility links first, then that profile's directory. Deleting
a profile does not delete saved sessions. When the native path is a regular
file instead of a link, it is a legacy profile; inspect it and remove only that
regular file.

---

Back to [README](../../README.en.md)
