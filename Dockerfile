FROM debian:13-slim

ARG NODE_VERSION=24.18.0
ARG CODEX_VERSION=0.145.0
ARG PNPM_VERSION=10.14.0
ARG TARGETARCH

ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:${PATH}

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

RUN printf '%s\n' '%sudo ALL=(ALL:ALL) NOPASSWD: ALL' \
      > /etc/sudoers.d/docker-codex \
    && chmod 0440 /etc/sudoers.d/docker-codex \
    && visudo -cf /etc/sudoers.d/docker-codex

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
    && rustc --version \
    && cargo --version

RUN npm install --global \
        "@openai/codex@${CODEX_VERSION}" \
        "pnpm@${PNPM_VERSION}" \
    && codex --version \
    && pnpm --version

COPY --chmod=0755 container-entrypoint /usr/local/bin/container-entrypoint

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/container-entrypoint"]
CMD ["codex"]
