#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install.sh [--prefix PREFIX]

Install docker-agent and one launcher per supported agent.

Options:
  --prefix PREFIX  Install commands into PREFIX/bin
                   Default: /usr/local
  --help, -h       Show this help

Examples:
  sudo ./install.sh
  ./install.sh --prefix "$HOME/.local"
EOF
}

prefix=/usr/local

while (($# > 0)); do
  case $1 in
    --prefix)
      (($# >= 2)) || die "--prefix requires a value"
      [[ -n $2 ]] || die "--prefix requires a non-empty value"
      prefix=$2
      shift 2
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
install -d "$bin_dir"
for name in $names; do
  install -m 0755 "$source_launcher" "$bin_dir/$name"
done

printf 'Installed %s to %s\n' "${names// /, }" "$bin_dir"
