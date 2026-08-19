FROM debian:13-slim

ARG NODE_VERSION=24.19.0
ARG GO_VERSION=1.26.6
ARG GO_SHA256_AMD64=708effb774be8237570d0add163225abbdfaf4fca28b2611df167beba4feef89
ARG GO_SHA256_ARM64=d0507e9e9d7fe012aae570108cbd76c15de879e17130ab8cb90d4d7445cb1f2e
ARG CODEX_VERSION=0.148.0
ARG CLAUDE_CODE_VERSION=2.1.229
ARG KIMI_CODE_VERSION=0.36.0
ARG CURSOR_AGENT_VERSION=2026.08.11-e8db854
# Cursor publishes no checksum for the CLI archive, so this digest is recorded
# here to keep the download verifiable; update it together with the version.
ARG CURSOR_AGENT_SHA256_AMD64=bfff4bf6f4e9dd30c1d0ef0a70b6077b074015dd2948e4c50685d53afdcfce5a
ARG CURSOR_AGENT_SHA256_ARM64=ea13f92e295f523a99ce8d8f57d6894d21e5d1e2d030ffad718ccd5955ca2eed
ARG PNPM_VERSION=11.21.0
ARG TARGETARCH

ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/go/bin:/usr/local/cargo/bin:${PATH}
# Use mold as the default linker for faster release builds; a project's own
# rustflags or `docker run -e RUSTFLAGS=...` override this.
ENV RUSTFLAGS="-C link-arg=-fuse-ld=mold"

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
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
        libwayland-client0 \
        locales \
        mold \
        ncurses-term \
        openssh-client \
        pkg-config \
        python-is-python3 \
        python3 \
        python3-pil \
        python3-pip \
        python3-venv \
        ripgrep \
        sccache \
        shellcheck \
        sqlite3 \
        sudo \
        tzdata \
        unzip \
        wl-clipboard \
        xz-utils \
        zip \
        zsh \
        gh \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i 's/^# *\(en_US.UTF-8 UTF-8\)$/\1/' /etc/locale.gen \
    && locale-gen en_US.UTF-8 \
    && locale -a | grep -Fxi en_US.utf8

RUN printf '%s\n' '%sudo ALL=(ALL:ALL) NOPASSWD: ALL' \
      > /etc/sudoers.d/docker-codex \
    && chmod 0440 /etc/sudoers.d/docker-codex \
    && visudo -cf /etc/sudoers.d/docker-codex

# Debian's /etc/profile resets PATH for login shells; re-add the toolchain
# directories so agent commands running through `bash -lc` still find them.
RUN printf '%s\n' \
      'export PATH="/codex-cache/pnpm:/codex-cache/go/bin:/usr/local/go/bin:/usr/local/cargo/bin:$PATH"' \
      > /etc/profile.d/docker-codex-path.sh

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

RUN curl --proto '=https' --tlsv1.2 --silent --show-error --fail \
        https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain stable \
    && rustup component add rustfmt clippy \
    && rustc --version \
    && cargo --version

RUN npm install --global \
        "@openai/codex@${CODEX_VERSION}" \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@moonshot-ai/kimi-code@${KIMI_CODE_VERSION}" \
        "pnpm@${PNPM_VERSION}" \
    && codex --version \
    && claude --version \
    && kimi --version \
    && pnpm --version

# Cursor Agent ships as a self-contained archive with its own Node runtime, so
# it is installed outside the npm layer. The upstream install script is not used
# because it resolves a floating version and edits shell rc files.
RUN set -eux; \
    target_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$target_arch" in \
      amd64) cursor_arch=x64; cursor_sha="$CURSOR_AGENT_SHA256_AMD64" ;; \
      arm64) cursor_arch=arm64; cursor_sha="$CURSOR_AGENT_SHA256_ARM64" ;; \
      *) printf 'unsupported target architecture: %s\n' "$target_arch" >&2; exit 1 ;; \
    esac; \
    archive=$(mktemp); \
    curl --proto '=https' --tlsv1.2 --silent --show-error --fail \
      --output "$archive" \
      "https://downloads.cursor.com/lab/${CURSOR_AGENT_VERSION}/linux/${cursor_arch}/agent-cli-package.tar.gz"; \
    printf '%s  %s\n' "$cursor_sha" "$archive" | sha256sum --check -; \
    install -d -m 0755 /opt/cursor-agent; \
    tar --extract --gzip --file "$archive" --directory /opt/cursor-agent \
      --strip-components=1 --no-same-owner; \
    rm -f "$archive"; \
    ln -s /opt/cursor-agent/cursor-agent /usr/local/bin/cursor-agent; \
    ln -s /opt/cursor-agent/cursor-agent /usr/local/bin/agent; \
    cursor-agent --version

RUN set -eux; \
    target_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$target_arch" in \
      amd64) go_arch=amd64; go_sha="$GO_SHA256_AMD64" ;; \
      arm64) go_arch=arm64; go_sha="$GO_SHA256_ARM64" ;; \
      *) printf 'unsupported target architecture: %s\n' "$target_arch" >&2; exit 1 ;; \
    esac; \
    archive=$(mktemp); \
    curl --proto '=https' --tlsv1.2 --silent --show-error --fail --location \
      --output "$archive" \
      "https://go.dev/dl/go${GO_VERSION}.linux-${go_arch}.tar.gz"; \
    printf '%s  %s\n' "$go_sha" "$archive" | sha256sum --check -; \
    tar --extract --gzip --file "$archive" --directory /usr/local \
      --no-same-owner; \
    rm -f "$archive"; \
    go version

# Keep Docker client tooling in its own late layer. Changing these packages
# should not invalidate the more expensive Node, Rust, agent, and Go layers.
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        docker-buildx \
        docker-cli \
        docker-compose \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 container-entrypoint /usr/local/bin/container-entrypoint
COPY --chmod=0755 container-codex-session-repair /usr/local/bin/container-codex-session-repair
RUN install -d -m 0755 /usr/local/share/docker-agent
COPY --chmod=0644 agent-notes.md /usr/local/share/docker-agent/agent-notes.md
COPY --chmod=0755 container-powershell-shim /usr/local/bin/powershell.exe
COPY --chmod=0755 container-wl-paste-shim /usr/local/bin/wl-paste

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/container-entrypoint"]
CMD ["codex"]
