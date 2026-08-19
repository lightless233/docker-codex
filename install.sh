#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install.sh [--prefix PREFIX] [--skip-build]

Build docker-agent:local, then install docker-agent and one launcher per
supported agent.

Options:
  --prefix PREFIX  Install commands into PREFIX/bin
                   Default: /usr/local
  --skip-build     Install launchers without checking Docker or building the image
  --help, -h       Show this help

Examples:
  ./install.sh
  ./install.sh --prefix "$HOME/.local"
  ./install.sh --skip-build
EOF
}

prefix=/usr/local
build_image=1
image=docker-agent:local
docker_bin=${DOCKER_AGENT_DOCKER_BIN:-${DOCKER_CODEX_DOCKER_BIN:-docker}}

while (($# > 0)); do
  case $1 in
    --prefix)
      (($# >= 2)) || die "--prefix requires a value"
      [[ -n $2 ]] || die "--prefix requires a non-empty value"
      prefix=$2
      shift 2
      ;;
    --skip-build)
      build_image=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
source_launcher="$script_dir/docker-agent"
[[ -f $source_launcher ]] ||
  die "docker-agent not found beside installer: $source_launcher"

if ((build_image)); then
  if [[ $(id -u) == 0 && -n ${SUDO_USER:-} ]]; then
    die "do not run this installer with sudo; run ./install.sh so Docker uses your user configuration"
  fi

  [[ -f $script_dir/Dockerfile && -f $script_dir/container-entrypoint ]] ||
    die "image build requires Dockerfile and container-entrypoint beside install.sh"

  command -v "$docker_bin" >/dev/null 2>&1 ||
    die "Docker CLI not found: $docker_bin"

  if ! "$docker_bin" buildx version >/dev/null 2>&1; then
    cat >&2 <<'EOF'
install.sh: Docker Buildx is required to build docker-agent:local.

For a Docker CLI installed with Homebrew, install the plugin with:
  brew install docker-buildx

If Docker still cannot find Buildx, add this directory to
"cliPluginsExtraDirs" in ~/.docker/config.json:
  $(brew --prefix)/lib/docker/cli-plugins
EOF
    exit 1
  fi

  "$docker_bin" info >/dev/null 2>&1 ||
    die "Docker daemon is unavailable; start Docker Desktop or another Docker daemon and try again"

  printf 'Building %s...\n' "$image"
  "$docker_bin" build --tag "$image" "$script_dir"
fi

# Read the agent names from the launcher's own registry so a new agent does
# not have to be repeated here.
agents=$(sed -n 's/^SUPPORTED_AGENTS="\([^"]*\)"$/\1/p' "$source_launcher")
[[ -n $agents ]] ||
  die "unable to read the agent registry from: $source_launcher"

names=docker-agent
for agent in $agents; do
  names="$names docker-$agent"
done

bin_dir="$prefix/bin"
use_sudo=0
if ! install -d "$bin_dir" 2>/dev/null || [[ ! -w $bin_dir ]]; then
  command -v sudo >/dev/null 2>&1 ||
    die "cannot write to $bin_dir and sudo is unavailable; use --prefix \"\$HOME/.local\""
  printf 'Administrator access is required to install commands to %s.\n' "$bin_dir"
  sudo install -d "$bin_dir"
  use_sudo=1
fi

for name in $names; do
  if ((use_sudo)); then
    sudo install -m 0755 "$source_launcher" "$bin_dir/$name"
  else
    install -m 0755 "$source_launcher" "$bin_dir/$name"
  fi
done

printf 'Installed %s to %s\n' "${names// /, }" "$bin_dir"
