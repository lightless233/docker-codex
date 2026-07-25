# Docker Codex Launcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a portable one-command launcher that runs Codex in Docker against the caller's current checkout, shares the host Codex home, understands linked worktrees, and optionally creates an isolated worktree.

**Architecture:** A Bash 3-compatible host launcher discovers Git paths and assembles explicit same-path Docker bind mounts. A Debian-based multi-architecture image contains Codex, Rust, Node, pnpm, and common build tools; a root entrypoint initializes only container-private writable directories and then drops to the host numeric UID/GID. Dependency discovery, worktree mutation, container startup, and permission setup remain separate and testable.

**Tech Stack:** Bash 3-compatible shell, Git worktrees, Docker/BuildKit, Debian bookworm, Node.js 22, Rust stable, pnpm, Codex CLI 0.145.0, shellcheck.

## Global Constraints

- Default invocation reuses the current checkout; only `--isolated <name>` creates a worktree.
- Support Linux, WSL2, and macOS Docker Desktop on amd64 and arm64.
- Mount checkout and external Git metadata at identical host/container absolute paths.
- Share the complete host `${CODEX_HOME:-$HOME/.codex}` read-write at `/codex-home`.
- Never automatically mount the Docker socket, whole home, filesystem root, checkout parent, SSH/GPG agents, or private keys.
- Never automatically remove a worktree, branch, commit, or uncommitted file.
- Use Bash 3 indexed arrays; do not use associative arrays, `mapfile`, `${value,,}`, GNU `readlink -f`, GNU `stat -c`, GNU `date -d`, or GNU `sed -r`.
- Preserve every Codex argument boundary; paths containing spaces must work.
- Container initialization may recursively change ownership only under `/codex-cache` and the container-private home, never under checkout, Git metadata, or `/codex-home`.
- Host keyring/Keychain access is not promised; a failed `codex login status` warns and then lets Codex continue.
- The default image is `docker-codex:local`; image builds pin Codex CLI to `0.145.0` unless explicitly overridden at build time.
- No `--privileged`, no Docker-in-Docker, and no credentials copied into image layers.

---

## File Map

- `docker-codex` — host CLI, option parsing, Git discovery, optional worktree creation, Docker argument assembly.
- `container-entrypoint` — numeric UID/GID setup, private-directory ownership, login warning, signal-preserving exec.
- `Dockerfile` — amd64/arm64-compatible development image and pinned tool installation.
- `.dockerignore` — excludes Git state, docs, and tests from the image context.
- `tests/testlib.bash` — temporary directories, assertions, fake Docker logger, and temporary Git repository helpers.
- `tests/launcher_test.bash` — launcher behavior for normal checkouts, linked worktrees, paths, options, and isolated mode.
- `tests/entrypoint_test.bash` — entrypoint behavior with fake system commands.
- `tests/run.bash` — deterministic test entrypoint.
- `README.md` — installation, default/current-checkout workflow, isolated workflow, platform caveats, security boundary, and verification.

---

### Task 1: Test Harness and Default Checkout Launch

**Files:**
- Create: `tests/testlib.bash`
- Create: `tests/launcher_test.bash`
- Create: `tests/run.bash`
- Create: `docker-codex`

**Interfaces:**
- Consumes: host `bash`, `git`, `docker`, `id`, `uname`.
- Produces: executable `docker-codex`; internal environment hooks `DOCKER_CODEX_DOCKER_BIN` and `DOCKER_CODEX_HOST_OS` for deterministic tests.

- [x] **Step 1: Write a failing normal-checkout test**

Create `tests/testlib.bash` with exact argument-line assertions:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_TMP=

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_line() {
  local expected=$1 file=$2
  grep -Fqx -- "$expected" "$file" ||
    fail "missing line <$expected> in $file"
}

assert_no_line() {
  local unexpected=$1 file=$2
  if grep -Fqx -- "$unexpected" "$file"; then
    fail "unexpected line <$unexpected> in $file"
  fi
}

new_tmp() {
  TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/docker-codex-test.XXXXXX")
  trap 'rm -rf "$TEST_TMP"' EXIT
}

make_repo() {
  local path=$1
  mkdir -p "$path"
  git init -q "$path"
  git -C "$path" config user.name Test
  git -C "$path" config user.email test@example.invalid
  printf 'seed\n' >"$path/seed.txt"
  git -C "$path" add seed.txt
  git -C "$path" commit -qm seed
}

make_fake_docker() {
  local path=$1 log=$2
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log=${DOCKER_CODEX_TEST_DOCKER_LOG:?}
printf 'CALL\n' >>"$log"
printf '<%s>\n' "$@" >>"$log"
case ${1:-} in
  info|image) exit 0 ;;
  build) exit 0 ;;
  run) exit 0 ;;
esac
EOF
  chmod +x "$path"
}
```

Create `tests/launcher_test.bash` with `test_normal_checkout`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/testlib.bash
source "$ROOT/tests/testlib.bash"

test_normal_checkout() {
  new_tmp
  local repo="$TEST_TMP/repo with spaces"
  local codex_home="$TEST_TMP/codex home"
  local fake="$TEST_TMP/docker"
  local log="$TEST_TMP/docker.log"
  make_repo "$repo"
  mkdir -p "$codex_home"
  : >"$log"
  make_fake_docker "$fake" "$log"

  (
    cd "$repo"
    CODEX_HOME="$codex_home" \
      DOCKER_CODEX_DOCKER_BIN="$fake" \
      DOCKER_CODEX_TEST_DOCKER_LOG="$log" \
      "$ROOT/docker-codex" -- review "prompt with spaces"
  )

  assert_line "<type=bind,source=$repo,target=$repo>" "$log"
  assert_line "<type=bind,source=$codex_home,target=/codex-home>" "$log"
  assert_line "<$repo>" "$log"
  assert_line "<codex>" "$log"
  assert_line "<review>" "$log"
  assert_line "<prompt with spaces>" "$log"
}

test_normal_checkout
printf 'launcher tests: PASS\n'
```

Create `tests/run.bash`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
"$ROOT/tests/launcher_test.bash"
```

- [x] **Step 2: Run the test to verify it fails**

Run:

```bash
chmod +x tests/run.bash tests/launcher_test.bash
tests/run.bash
```

Expected: FAIL because `docker-codex` does not exist.

- [x] **Step 3: Implement minimal default-checkout launcher**

Create `docker-codex` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

die() { printf 'docker-codex: %s\n' "$*" >&2; exit 1; }

DOCKER_BIN=${DOCKER_CODEX_DOCKER_BIN:-docker}
IMAGE=${DOCKER_CODEX_IMAGE:-docker-codex:local}
HOST_OS=${DOCKER_CODEX_HOST_OS:-$(uname -s)}
BUILD=0
ISOLATED=
BIND_SPECS=()
CODEX_ARGS=()

while (($#)); do
  case $1 in
    --build) BUILD=1; shift ;;
    --image) (($# >= 2)) || die "--image requires a value"; IMAGE=$2; shift 2 ;;
    --isolated) (($# >= 2)) || die "--isolated requires a name"; ISOLATED=$2; shift 2 ;;
    --bind) (($# >= 2)) || die "--bind requires a path"; BIND_SPECS+=("$2"); shift 2 ;;
    --) shift; CODEX_ARGS=("$@"); break ;;
    --help|-h) printf 'Usage: docker-codex [options] [--] [codex args...]\n'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -z $ISOLATED ]] || die "--isolated is not implemented yet"
command -v git >/dev/null 2>&1 || die "git is required"
command -v "$DOCKER_BIN" >/dev/null 2>&1 || die "docker is required"

START_DIR=$(pwd -P)
CHECKOUT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) ||
  die "current directory is not inside a Git checkout"
CHECKOUT_ROOT=$(cd "$CHECKOUT_ROOT" && pwd -P)
CODEX_HOME_SOURCE=${CODEX_HOME:-$HOME/.codex}
[[ -d $CODEX_HOME_SOURCE ]] || die "Codex home does not exist: $CODEX_HOME_SOURCE"
CODEX_HOME_SOURCE=$(cd "$CODEX_HOME_SOURCE" && pwd -P)

COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir)
COMMON_DIR=$(cd "$COMMON_DIR" && pwd -P)
REPO_ID=$(printf '%s' "$COMMON_DIR" | git hash-object --stdin | cut -c1-16)

DOCKER_ARGS=(run --rm)
if [[ -t 0 && -t 1 ]]; then
  DOCKER_ARGS+=(-it)
fi
DOCKER_ARGS+=(--env "CODEX_HOME=/codex-home")
DOCKER_ARGS+=(--env "HOST_UID=$(id -u)" --env "HOST_GID=$(id -g)")
DOCKER_ARGS+=(--mount "type=bind,source=$CHECKOUT_ROOT,target=$CHECKOUT_ROOT")
DOCKER_ARGS+=(--mount "type=bind,source=$CODEX_HOME_SOURCE,target=/codex-home")
DOCKER_ARGS+=(--mount "type=volume,source=docker-codex-cache-$REPO_ID,target=/codex-cache")
DOCKER_ARGS+=(--workdir "$START_DIR")
[[ $HOST_OS != Linux ]] ||
  DOCKER_ARGS+=(--add-host "host.docker.internal:host-gateway")

if ((BUILD)); then
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
  "$DOCKER_BIN" build --tag "$IMAGE" "$SCRIPT_DIR"
else
  "$DOCKER_BIN" image inspect "$IMAGE" >/dev/null 2>&1 ||
    die "image not found: $IMAGE (run with --build)"
fi

exec "$DOCKER_BIN" "${DOCKER_ARGS[@]}" "$IMAGE" codex "${CODEX_ARGS[@]}"
```

- [x] **Step 4: Run tests and syntax checks**

Run:

```bash
chmod +x docker-codex
bash -n docker-codex tests/testlib.bash tests/launcher_test.bash tests/run.bash
tests/run.bash
```

Expected: `launcher tests: PASS`.

- [x] **Step 5: Commit**

```bash
git add docker-codex tests
git commit -m "feat: launch Codex from current checkout"
```

---

### Task 2: Linked Worktree, Conditional Mounts, and Portable Options

**Files:**
- Modify: `docker-codex`
- Modify: `tests/launcher_test.bash`

**Interfaces:**
- Consumes: Task 1 `DOCKER_ARGS`, `CHECKOUT_ROOT`, `COMMON_DIR`, `BIND_SPECS`.
- Produces: `append_same_path_mount(path, mode)` and `path_is_within(child, parent)`; linked-worktree and `--bind` behavior.

- [x] **Step 1: Add failing linked-worktree and bind tests**

Add tests that create a sibling linked worktree, enter a subdirectory, and assert:

```bash
assert_line "<type=bind,source=$common_dir,target=$common_dir>" "$log"
assert_line "<--workdir>" "$log"
assert_line "<$worktree/sub dir>" "$log"
assert_line "<type=bind,source=$fixture,target=$fixture,readonly>" "$log"
```

Add a normal-checkout assertion proving its internal `.git` is not mounted a second time:

```bash
assert_no_line "<type=bind,source=$repo/.git,target=$repo/.git>" "$log"
```

Create a real repository containing a checked-out submodule and assert the submodule checkout is mounted together with its external `.git/modules/...` metadata. Simulate `DOCKER_CODEX_HOST_OS=Darwin` and assert no Linux `host-gateway` argument is emitted.

Add negative cases for a missing bind source and a path containing a comma; both must fail before fake Docker receives `run`.

- [x] **Step 2: Run focused tests to verify failure**

Run:

```bash
tests/launcher_test.bash
```

Expected: FAIL because common Git metadata and `--bind` are not added.

- [x] **Step 3: Implement conditional same-path mounts**

Add:

```bash
path_is_within() {
  local child=$1 parent=$2
  [[ $child == "$parent" || $child == "$parent/"* ]]
}

reject_mount_comma() {
  [[ $1 != *,* ]] || die "Docker --mount paths containing commas are unsupported: $1"
}

append_same_path_mount() {
  local path=$1 mode=${2:-rw}
  [[ -e $path ]] || die "bind source does not exist: $path"
  path=$(cd "$path" && pwd -P)
  reject_mount_comma "$path"
  if [[ $mode == ro ]]; then
    DOCKER_ARGS+=(--mount "type=bind,source=$path,target=$path,readonly")
  else
    DOCKER_ARGS+=(--mount "type=bind,source=$path,target=$path")
  fi
}
```

Discover `GIT_DIR` using `git rev-parse --path-format=absolute --git-dir`. After the checkout mount, add `COMMON_DIR` only when it is outside `CHECKOUT_ROOT`; add `GIT_DIR` only when it is outside both already mounted roots.

Parse each `--bind` value as either `/absolute/path` or `/absolute/path:ro`, require an absolute source, and call `append_same_path_mount`.

- [x] **Step 4: Run all launcher tests**

Run:

```bash
bash -n docker-codex tests/*.bash
tests/run.bash
```

Expected: all launcher tests pass.

- [x] **Step 5: Commit**

```bash
git add docker-codex tests/launcher_test.bash
git commit -m "feat: support linked worktrees and extra mounts"
```

---

### Task 3: Explicit Isolated Worktree Mode

**Files:**
- Modify: `docker-codex`
- Modify: `tests/launcher_test.bash`

**Interfaces:**
- Consumes: Task 2 Git discovery and same-path mount functions.
- Produces: `validate_isolated_name(name)` and `create_isolated_worktree(name)`; environment override `DOCKER_CODEX_DATA_HOME`.

- [x] **Step 1: Add failing isolated-worktree tests**

Test `--isolated feature-one` against a temporary normal repository and assert:

```bash
git -C "$repo" show-ref --verify --quiet refs/heads/codex/feature-one
[[ -f "$data_home/worktrees/$repo_id/feature-one/seed.txt" ]]
assert_line "<type=bind,source=$worktree,target=$worktree>" "$log"
```

Run the same name a second time and assert nonzero exit without deleting the first directory or branch. Add invalid-name cases:

```text
../escape
/absolute
name with spaces
codex/already-prefixed
```

Add a detached-HEAD case and assert fail-fast.

- [x] **Step 2: Run focused tests to verify failure**

Run:

```bash
tests/launcher_test.bash
```

Expected: FAIL with the Task 1 placeholder `--isolated is not implemented yet`.

- [x] **Step 3: Implement host-side worktree creation**

Add:

```bash
validate_isolated_name() {
  local name=$1
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    die "invalid isolated worktree name: $name"
}

create_isolated_worktree() {
  local name=$1 current_branch data_home repo_id target branch
  validate_isolated_name "$name"
  current_branch=$(git branch --show-current)
  [[ -n $current_branch ]] ||
    die "--isolated requires the current checkout to be on a branch"
  data_home=${DOCKER_CODEX_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/docker-codex}
  mkdir -p "$data_home/worktrees"
  data_home=$(cd "$data_home" && pwd -P)
  repo_id=$(printf '%s' "$COMMON_DIR" | git hash-object --stdin | cut -c1-16)
  target="$data_home/worktrees/$repo_id/$name"
  branch="codex/$name"
  [[ ! -e $target ]] || die "isolated worktree path already exists: $target"
  ! git show-ref --verify --quiet "refs/heads/$branch" ||
    die "isolated worktree branch already exists: $branch"
  mkdir -p "$(dirname "$target")"
  git worktree add -b "$branch" "$target" HEAD
  CHECKOUT_ROOT=$target
  START_DIR=$target
}
```

Call the function after initial common-dir discovery, then refresh `GIT_DIR` and `COMMON_DIR` from the new worktree using `git -C "$CHECKOUT_ROOT"`. Preserve the created worktree on every subsequent error.

- [x] **Step 4: Run launcher tests and inspect worktree state**

Run:

```bash
bash -n docker-codex tests/*.bash
tests/run.bash
```

Expected: isolated branch and worktree tests pass; no test removes a non-test worktree.

- [x] **Step 5: Commit**

```bash
git add docker-codex tests/launcher_test.bash
git commit -m "feat: add explicit isolated worktree mode"
```

---

### Task 4: Container Entrypoint and Development Image

**Files:**
- Create: `tests/entrypoint_test.bash`
- Modify: `tests/run.bash`
- Create: `container-entrypoint`
- Create: `Dockerfile`
- Create: `.dockerignore`

**Interfaces:**
- Consumes: launcher-provided `HOST_UID`, `HOST_GID`, `CODEX_HOME=/codex-home`, `/codex-cache`, and command `codex ...`.
- Produces: image entrypoint that drops to `HOST_UID:HOST_GID` and preserves the child command exit code/signals.

- [x] **Step 1: Write failing entrypoint tests**

Create fake `getent`, `groupadd`, `useradd`, `mkdir`, `chown`, `gosu`, and `codex` commands in a temporary `PATH`. Log every argument as `<value>` lines. Test:

- UID absent/GID absent calls `groupadd` and `useradd`;
- UID absent/GID 20 already present calls `useradd` without trying to recreate the group;
- UID already present skips `useradd`;
- `chown` receives only `/home/codex` and `/codex-cache`;
- failed fake `codex login status` writes a warning but final fake `gosu ... codex` still runs;
- non-Codex commands skip login status;
- final command exit status is returned unchanged.

Append `"$ROOT/tests/entrypoint_test.bash"` to `tests/run.bash`.

- [x] **Step 2: Run tests to verify failure**

Run:

```bash
tests/run.bash
```

Expected: FAIL because `container-entrypoint` does not exist.

- [x] **Step 3: Implement the entrypoint**

Create `container-entrypoint` around these exact boundaries:

```bash
#!/usr/bin/env bash
set -euo pipefail

HOST_UID=${HOST_UID:?HOST_UID is required}
HOST_GID=${HOST_GID:?HOST_GID is required}
RUNTIME_HOME=/home/codex

if ! getent group "$HOST_GID" >/dev/null; then
  groupadd --gid "$HOST_GID" docker-codex
fi
if ! getent passwd "$HOST_UID" >/dev/null; then
  useradd --uid "$HOST_UID" --gid "$HOST_GID" \
    --home-dir "$RUNTIME_HOME" --no-create-home --shell /bin/bash docker-codex
fi

mkdir -p "$RUNTIME_HOME" /codex-cache
chown "$HOST_UID:$HOST_GID" "$RUNTIME_HOME" /codex-cache
export HOME=$RUNTIME_HOME
export USER=docker-codex
export LOGNAME=docker-codex
export CODEX_HOME=${CODEX_HOME:-/codex-home}
export CARGO_TARGET_DIR=/codex-cache/cargo-target
export XDG_CACHE_HOME=/codex-cache/xdg
export PNPM_HOME=/codex-cache/pnpm
export PATH="$PNPM_HOME:$PATH"

if [[ ${1:-} == codex ]]; then
  if ! gosu "$HOST_UID:$HOST_GID" codex login status >/dev/null 2>&1; then
    printf '%s\n' \
      'docker-codex: warning: container cannot use the current Codex login; file auth can be shared, host keyrings cannot.' >&2
  fi
fi

exec gosu "$HOST_UID:$HOST_GID" "$@"
```

Do not run recursive `chown`.

- [x] **Step 4: Add Dockerfile and build checks**

Create a `node:22-bookworm` image that:

- installs `bash build-essential ca-certificates clang cmake curl git gosu jq libssl-dev openssh-client pkg-config ripgrep shellcheck sqlite3 zsh`;
- sets `RUSTUP_HOME=/usr/local/rustup` and `CARGO_HOME=/usr/local/cargo`;
- installs Rust stable with the minimal rustup profile;
- installs `@openai/codex@${CODEX_VERSION}` where the default build arg is `0.145.0`;
- enables corepack and prepares `pnpm@${PNPM_VERSION}` with an explicit default;
- copies `container-entrypoint` to `/usr/local/bin/container-entrypoint`;
- uses `ENTRYPOINT ["/usr/local/bin/container-entrypoint"]` and `CMD ["codex"]`.

Create `.dockerignore`:

```text
.git
docs
tests
README.md
```

Run:

```bash
chmod +x container-entrypoint tests/entrypoint_test.bash
bash -n container-entrypoint tests/*.bash
tests/run.bash
docker build --check .
```

Expected: tests pass and Docker build check reports no errors.

- [x] **Step 5: Commit**

```bash
git add container-entrypoint Dockerfile .dockerignore tests
git commit -m "feat: add portable development image"
```

---

### Task 5: Documentation and End-to-End Verification

**Files:**
- Create: `README.md`
- Modify: `docker-codex`
- Modify: `tests/launcher_test.bash`

**Interfaces:**
- Consumes: all previous user-facing CLI options and image behavior.
- Produces: complete usage and security documentation; verified local Linux workflow.

- [x] **Step 1: Add failing help-output assertions**

Capture `docker-codex --help` and assert it documents:

```text
--build
--image IMAGE
--isolated NAME
--bind PATH[:ro]
--help
```

Also assert the help names the default `docker-codex:local` image and states that isolated worktrees are retained.

- [x] **Step 2: Run tests to verify the help is incomplete**

Run:

```bash
tests/launcher_test.bash
```

Expected: FAIL because Task 1 only prints a one-line usage string.

- [x] **Step 3: Complete help and README**

Document:

- prerequisites and `./docker-codex --build`;
- default current checkout behavior;
- automatic normal/linked/submodule Git handling;
- `--isolated` branch/path behavior and explicit cleanup commands;
- `--bind /path:ro` for project-specific fixtures;
- direct full `CODEX_HOME` sharing and concurrent local clients;
- file auth versus Linux keyring/macOS Keychain;
- Linux/WSL2/macOS differences;
- Apple Silicon native arm64 behavior and explicit amd64 choice;
- Docker Desktop file-sharing requirements;
- cache volume location and removal command;
- security boundary and intentionally unmounted resources;
- current verification scope, explicitly marking macOS real-hardware validation as not run.

- [x] **Step 4: Run complete local verification**

Run:

```bash
bash -n docker-codex container-entrypoint tests/*.bash
tests/run.bash
docker build --check .
docker build -t docker-codex:local .
docker run --rm --entrypoint shellcheck docker-codex:local \
  /usr/local/bin/container-entrypoint
docker run --rm --entrypoint bash \
  -v "$PWD:/src:ro" docker-codex:local \
  -lc 'shellcheck /src/docker-codex /src/container-entrypoint /src/tests/*.bash'
docker run --rm --entrypoint codex docker-codex:local --version
```

Then create a temporary normal repository and linked worktree, use a temporary copied `CODEX_HOME`, and run the launcher with Codex `--version` or a harmless Git read-only command. Do not use the user's real authentication for API calls.

Expected:

- all shell tests pass;
- Dockerfile check and build pass;
- shellcheck exits zero;
- image reports `codex-cli 0.145.0`;
- normal checkout and linked worktree mounts expose valid `git status`;
- no file outside temporary test roots is modified.

- [x] **Step 5: Commit**

```bash
git add README.md docker-codex tests/launcher_test.bash
git commit -m "docs: document Docker Codex workflows"
```

---

## Final Self-Review

- [x] Compare every design section with a task above; record macOS hardware validation as pending rather than claiming it.
- [x] Search for placeholders with `rg -n 'TB[D]|TO[D]O|implement later|fill in' .`.
- [x] Run `git diff --check` and confirm a clean worktree after commits.
- [x] Run the complete verification command set again from `main`.
