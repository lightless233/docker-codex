# Debian Node LTS and Container Privileges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Node base image with Debian 13 slim, install pinned Node.js 24.18.0 directly from nodejs.org, give the host-mapped runtime user passwordless sudo, and launch Codex with `--yolo` by default.

**Architecture:** The Dockerfile owns immutable toolchain installation and verifies the official Node archive before extraction. The entrypoint owns runtime UID/GID and sudo-group setup while preserving host ownership on bind mounts. The host launcher keeps Docker as the outer security boundary and inserts `--yolo` immediately after the `codex` executable.

**Tech Stack:** Docker/BuildKit, Debian 13 slim, Bash 3-compatible shell, Node.js 24.18.0 LTS official binaries, SHA-256, sudo, gosu, Codex CLI 0.145.0, pnpm 10.14.0, Rust stable, shellcheck.

## Global Constraints

- Use `debian:13-slim` as the base image.
- Do not install `nodejs` or `npm` from Debian or third-party apt repositories.
- Default `NODE_VERSION` to exactly `24.18.0`; upgrades remain explicit build args or code changes.
- Download Node only from `https://nodejs.org/dist/v${NODE_VERSION}/`.
- Support Docker target architectures `amd64` and `arm64`; fail clearly for every other architecture.
- Verify the selected archive against the official `SHASUMS256.txt` before extraction.
- Run Codex as the host numeric UID/GID, not root, during normal operation.
- Give the runtime user passwordless sudo without adding it to GID 0.
- Never recursively chown the checkout, Git metadata, or `/codex-home`.
- Launch Codex with `--yolo` by default while retaining Docker as the outer boundary.
- Do not add `--privileged`, Docker socket mounts, broad host mounts, or credential copies.
- Preserve Linux, WSL2, macOS Docker Desktop, amd64, and arm64 launcher behavior.

---

## File Map

- `Dockerfile` — Debian base, native packages, official Node archive installation, sudo policy, Rust, Codex, and pnpm.
- `container-entrypoint` — runtime UID/GID mapping, sudo-group membership, private writable directories, and privilege drop.
- `docker-codex` — Docker argument assembly and default Codex `--yolo` insertion.
- `tests/image_test.bash` — real-container checks for OS, Node provenance, and runtime sudo.
- `tests/entrypoint_test.bash` — runtime user and sudo setup tests.
- `tests/launcher_test.bash` — launcher argument-order test.
- `tests/testlib.bash` — ordered-line assertion shared by launcher tests.
- `tests/run.bash` — deterministic test-suite entrypoint.
- `README.md` — Node provenance, build arguments, sudo behavior, and `--yolo` security boundary.

---

### Task 1: Debian Base and Official Node LTS Installation

**Files:**
- Create: `tests/image_test.bash`
- Modify: `Dockerfile`

**Interfaces:**
- Consumes: Docker automatic build arg `TARGETARCH`, optional build arg `NODE_VERSION`.
- Produces: `/usr/local/bin/node`, `/usr/local/bin/npm`, and an image definition that supports `amd64`/`arm64`.

- [x] **Step 1: Add the failing real-image test**

Create `tests/image_test.bash`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/testlib.bash
source "$ROOT/tests/testlib.bash"

DOCKER_BIN=${DOCKER_CODEX_DOCKER_BIN:-docker}
IMAGE=${DOCKER_CODEX_TEST_IMAGE:-docker-codex:local}

test_debian_and_official_node_runtime() {
  "$DOCKER_BIN" image inspect "$IMAGE" >/dev/null
  "$DOCKER_BIN" run --rm --entrypoint bash "$IMAGE" -lc '
    set -euo pipefail
    source /etc/os-release
    [[ $ID == debian ]]
    [[ $VERSION_ID == 13 ]]
    [[ $(node --version) == v24.18.0 ]]
    if dpkg-query --show nodejs npm >/dev/null 2>&1; then
      printf "%s\n" "nodejs/npm unexpectedly installed through dpkg" >&2
      exit 1
    fi
  '
}

init_tests
test_debian_and_official_node_runtime
printf 'image tests: PASS\n'
```

Keep this integration test separate from `tests/run.bash` because it requires a previously built Docker image.

- [x] **Step 2: Run the image test and verify RED**

Run:

```bash
DOCKER_CODEX_TEST_IMAGE=docker-codex:local bash tests/image_test.bash
```

Expected: FAIL because the current local image reports Debian 12 and Node 22.

- [x] **Step 3: Implement Debian and official Node installation**

Replace the Dockerfile base and build arguments with:

```dockerfile
FROM debian:13-slim

ARG NODE_VERSION=24.18.0
ARG CODEX_VERSION=0.145.0
ARG PNPM_VERSION=10.14.0
ARG TARGETARCH
```

Keep the existing native packages, add `sudo` and `xz-utils`, and do not add `nodejs` or `npm`:

```dockerfile
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        clang \
        cmake \
        curl \
        git \
        gosu \
        jq \
        libssl-dev \
        openssh-client \
        pkg-config \
        ripgrep \
        shellcheck \
        sqlite3 \
        sudo \
        xz-utils \
        zsh \
    && rm -rf /var/lib/apt/lists/*
```

After native packages are installed, select and verify the official archive:

```dockerfile
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eux; \
    target_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$target_arch" in \
      amd64) node_arch=x64 ;; \
      arm64) node_arch=arm64 ;; \
      *) printf 'unsupported target architecture: %s\n' "$target_arch" >&2; exit 1 ;; \
    esac; \
    node_archive="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    node_base_url="https://nodejs.org/dist/v${NODE_VERSION}"; \
    install_dir=$(mktemp -d); \
    cd "$install_dir"; \
    curl --proto '=https' --tlsv1.2 --silent --show-error --fail \
      --output "$node_archive" "$node_base_url/$node_archive"; \
    curl --proto '=https' --tlsv1.2 --silent --show-error --fail \
      --output SHASUMS256.txt "$node_base_url/SHASUMS256.txt"; \
    grep " ${node_archive}\$" SHASUMS256.txt | sha256sum --check -; \
    tar --extract --xz --file "$node_archive" --directory /usr/local \
      --strip-components=1 --no-same-owner; \
    cd /; \
    rm -rf "$install_dir"; \
    node --version; \
    npm --version
```

- [x] **Step 4: Build and run the focused real-image test**

Run:

```bash
docker build --tag docker-codex:test .
DOCKER_CODEX_TEST_IMAGE=docker-codex:test bash tests/image_test.bash
tests/run.bash
```

Expected: all commands exit 0 and print `image tests: PASS`, `launcher tests: PASS`, and `entrypoint tests: PASS`.

- [x] **Step 5: Commit the image change**

```bash
git add Dockerfile tests/image_test.bash
git commit -m "feat: install official Node LTS on Debian"
```

---

### Task 2: Passwordless Sudo for the Host-Mapped User

**Files:**
- Modify: `Dockerfile`
- Modify: `container-entrypoint`
- Modify: `tests/entrypoint_test.bash`

**Interfaces:**
- Consumes: `HOST_UID`, `HOST_GID`, Debian `sudo` group, and the runtime username resolved by `getent`.
- Produces: a host-mapped non-root user that can run `sudo -n` while ordinary bind-mount writes retain host ownership.

- [x] **Step 1: Add failing entrypoint assertions**

In `test_missing_uid_and_gid_are_created_without_touching_shared_mounts`, add:

```bash
assert_line "<--groups>" "$log"
assert_line "<sudo>" "$log"
```

In the existing-user half of `test_existing_gid_is_reused_and_existing_uid_skips_user_creation`, after the log reset and invocation, add:

```bash
assert_line "<CALL:usermod>" "$log"
assert_line "<--append>" "$log"
assert_line "<--groups>" "$log"
assert_line "<sudo>" "$log"
assert_line "<existing>" "$log"
```

Append a real runtime test to `tests/image_test.bash`:

```bash
test_runtime_user_has_passwordless_sudo_without_root_group() {
  "$DOCKER_BIN" run --rm \
    --env HOST_UID=12345 \
    --env HOST_GID=23456 \
    "$IMAGE" \
    bash -lc '
      set -euo pipefail
      [[ $(id -u) == 12345 ]]
      [[ $(id -g) == 23456 ]]
      ! id -G | tr " " "\n" | grep -qx 0
      sudo -n true
    '
}
```

Add this invocation before the final `printf`:

```bash
test_runtime_user_has_passwordless_sudo_without_root_group
```

- [x] **Step 2: Run focused tests and verify RED**

Run:

```bash
bash tests/entrypoint_test.bash
DOCKER_CODEX_TEST_IMAGE=docker-codex:test bash tests/image_test.bash
```

Expected: the entrypoint test fails because users are not added to `sudo`; after adding the new runtime test to the invocation list, the image test also fails because the runtime user cannot execute `sudo -n true`.

- [x] **Step 3: Add and validate the sudoers policy**

Add after the native-package installation layer:

```dockerfile
RUN printf '%s\n' '%sudo ALL=(ALL:ALL) NOPASSWD: ALL' \
      > /etc/sudoers.d/docker-codex \
    && chmod 0440 /etc/sudoers.d/docker-codex \
    && visudo -cf /etc/sudoers.d/docker-codex
```

- [x] **Step 4: Add the runtime user to sudo**

Change the non-root existing-user branch to:

```bash
if [[ $HOST_UID != 0 ]]; then
  usermod --home "$RUNTIME_HOME" --append --groups sudo "$RUNTIME_USER"
fi
```

Change new-user creation to:

```bash
useradd --uid "$HOST_UID" --gid "$HOST_GID" --groups sudo \
  --home-dir "$RUNTIME_HOME" --no-create-home --shell /bin/bash docker-codex
```

Do not add `root` to supplementary groups and do not change the final numeric `gosu "$HOST_UID:$HOST_GID"` boundary.

- [x] **Step 5: Run focused and full shell tests**

Run:

```bash
bash tests/entrypoint_test.bash
docker build --tag docker-codex:test .
DOCKER_CODEX_TEST_IMAGE=docker-codex:test bash tests/image_test.bash
tests/run.bash
```

Expected: all commands exit 0.

- [x] **Step 6: Commit the sudo change**

```bash
git add Dockerfile container-entrypoint tests/entrypoint_test.bash tests/image_test.bash
git commit -m "feat: grant runtime user passwordless sudo"
```

---

### Task 3: Default Codex `--yolo`

**Files:**
- Modify: `docker-codex`
- Modify: `tests/testlib.bash`
- Modify: `tests/launcher_test.bash`

**Interfaces:**
- Consumes: the existing `CODEX_ARGS` Bash indexed array.
- Produces: Docker command suffix `IMAGE codex --yolo "${CODEX_ARGS[@]}"` with exact user argument boundaries preserved.

- [x] **Step 1: Add an ordered-line assertion**

Append to `tests/testlib.bash`:

```bash
assert_ordered_lines() {
  local file=$1
  shift
  local expected line_number last_line=0
  for expected in "$@"; do
    line_number=$(awk -v target="$expected" '$0 == target { print NR; exit }' "$file")
    [[ -n $line_number ]] ||
      fail "missing ordered line <$expected> in $file"
    ((line_number > last_line)) ||
      fail "line <$expected> is out of order in $file"
    last_line=$line_number
  done
}
```

In `test_normal_checkout_preserves_paths_and_codex_arguments`, add:

```bash
assert_ordered_lines "$TEST_DOCKER_LOG" \
  "<codex>" \
  "<--yolo>" \
  "<review>" \
  "<prompt with spaces>"
```

- [x] **Step 2: Run the launcher test and verify RED**

Run:

```bash
bash tests/launcher_test.bash
```

Expected: FAIL with `missing ordered line <--yolo>`.

- [x] **Step 3: Insert `--yolo` at the executable boundary**

Change the final launcher command to:

```bash
exec "$DOCKER_BIN" "${DOCKER_ARGS[@]}" "$IMAGE" codex --yolo "${CODEX_ARGS[@]}"
```

- [x] **Step 4: Run focused and full shell tests**

Run:

```bash
bash tests/launcher_test.bash
tests/run.bash
```

Expected: both commands exit 0 and the launcher test proves `--yolo` precedes every user argument.

- [x] **Step 5: Commit the launcher change**

```bash
git add docker-codex tests/testlib.bash tests/launcher_test.bash
git commit -m "feat: run container Codex in yolo mode"
```

---

### Task 4: Documentation and Full Image Verification

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: completed Tasks 1–3 and image tag `docker-codex:local`.
- Produces: documented build/runtime contract and fresh verification evidence.

- [x] **Step 1: Update documented image contents and build arguments**

Replace references to the Node base/toolchain with text stating:

```markdown
The image uses Debian 13 slim and installs Node.js 24.18.0 LTS from the
official nodejs.org linux-x64/linux-arm64 archive after checking it against
the release's SHASUMS256.txt.
```

Extend the build-arg example with:

```bash
--build-arg NODE_VERSION=24.18.0 \
```

Document that changing `NODE_VERSION` remains explicit and that neither Debian nor third-party Node repositories are used.

- [x] **Step 2: Document sudo and `--yolo` behavior**

Update the security section with these exact operational facts:

```markdown
Codex normally runs with the caller's numeric UID/GID so files created on
bind mounts remain owned by the host user. The runtime user has passwordless
sudo inside the container and may obtain container root when needed; it is
not added to the root group.

The launcher adds `--yolo` by default. This disables Codex's own approvals
and command sandbox, so every read-write mount is fully exposed to the agent.
Docker remains the outer boundary: the launcher does not use --privileged or
mount the Docker socket, host root, whole home, or unrelated repositories.
```

- [x] **Step 3: Run shell syntax, tests, and static analysis**

Run:

```bash
bash -n docker-codex container-entrypoint tests/*.bash
shellcheck docker-codex container-entrypoint tests/*.bash
tests/run.bash
git diff --check
```

Expected: all four commands exit 0 with no shellcheck diagnostics or whitespace errors.

- [x] **Step 4: Validate and build the image**

Run:

```bash
docker build --check .
docker build --tag docker-codex:local .
arch_log=$(mktemp "${TMPDIR:-/tmp}/docker-codex-arch.XXXXXX")
if docker build --build-arg TARGETARCH=unsupported . >"$arch_log" 2>&1; then
  printf '%s\n' 'unsupported architecture build unexpectedly succeeded' >&2
  exit 1
fi
grep -F 'unsupported target architecture: unsupported' "$arch_log"
rm -f "$arch_log"
```

Expected: the first two commands exit 0, the normal build output shows a successful SHA-256 check for the selected Node archive, and the deliberately unsupported architecture build fails with the expected message.

- [x] **Step 5: Verify installed tool versions**

Run:

```bash
docker run --rm --entrypoint sh docker-codex:local -lc \
  'node --version && npm --version && pnpm --version && codex --version && rustc --version && cargo --version'
```

Expected:

```text
v24.18.0
```

followed by valid npm, pnpm 10.14.0, Codex 0.145.0, rustc, and cargo version lines.

- [x] **Step 6: Verify non-root identity and passwordless sudo**

Run:

```bash
docker run --rm \
  --env HOST_UID=12345 \
  --env HOST_GID=23456 \
  docker-codex:local \
  sh -lc 'id && test "$(id -u)" = 12345 && sudo -n true'
```

Expected: exit 0, `uid=12345`, primary `gid=23456`, and no sudo password prompt.

- [x] **Step 7: Verify normal checkout and linked-worktree launches**

From this repository, run:

```bash
./docker-codex -- --version
```

Expected: exit 0 and `codex-cli 0.145.0`.

Create a temporary linked worktree outside the checkout, launch the same command from it, and then remove only that temporary worktree:

```bash
verification_root=$(mktemp -d "${TMPDIR:-/tmp}/docker-codex-e2e.XXXXXX")
git worktree add --detach "$verification_root/worktree" HEAD
(
  cd "$verification_root/worktree"
  /home/lightless/program/docker-codex/docker-codex -- --version
)
git worktree remove "$verification_root/worktree"
rmdir "$verification_root"
```

Expected: the linked-worktree launch exits 0 and prints `codex-cli 0.145.0`.

- [x] **Step 8: Commit documentation**

```bash
git add README.md
git commit -m "docs: describe Debian Node and container privileges"
```

- [x] **Step 9: Perform final repository verification**

Run:

```bash
git status --short --branch
git log -5 --oneline
tests/run.bash
docker image inspect docker-codex:local --format '{{.Id}}'
```

Expected: a clean `main` worktree, four new implementation commits after the design/plan commits, passing tests, and a concrete local image ID.
