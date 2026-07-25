#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
"$ROOT/tests/launcher_test.bash"
"$ROOT/tests/entrypoint_test.bash"
