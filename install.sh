#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install.sh [--prefix PREFIX]

Install docker-agent, docker-codex, and docker-claude.

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

bin_dir="$prefix/bin"
install -d "$bin_dir"
for name in docker-agent docker-codex docker-claude; do
  install -m 0755 "$source_launcher" "$bin_dir/$name"
done

printf 'Installed docker-agent, docker-codex, and docker-claude to %s\n' \
  "$bin_dir"
