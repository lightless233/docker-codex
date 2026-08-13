FROM debian:13-slim

ARG NODE_VERSION=24.19.0
ARG CODEX_VERSION=0.147.0
ARG CLAUDE_CODE_VERSION=2.1.229
ARG PNPM_VERSION=11.21.0
ARG TARGETARCH

ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:${PATH}
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
      'export PATH="/codex-cache/pnpm:/usr/local/cargo/bin:$PATH"' \
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
        "pnpm@${PNPM_VERSION}" \
    && codex --version \
    && claude --version \
    && pnpm --version

# Keep Docker client tooling in its own late layer. Changing these packages
# should not invalidate the more expensive Node, Rust, Codex, and Claude layers.
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        docker-buildx \
        docker-cli \
        docker-compose \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 container-entrypoint /usr/local/bin/container-entrypoint
RUN install -d -m 0755 /usr/local/share/docker-agent
COPY --chmod=0644 agent-notes.md /usr/local/share/docker-agent/agent-notes.md
COPY --chmod=0755 container-powershell-shim /usr/local/bin/powershell.exe
COPY --chmod=0755 container-wl-paste-shim /usr/local/bin/wl-paste

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/container-entrypoint"]
CMD ["codex"]
