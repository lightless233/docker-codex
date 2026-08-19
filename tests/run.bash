#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
"$ROOT/tests/install_test.bash"
"$ROOT/tests/launcher_test.bash"
python3 "$ROOT/tests/session_repair_test.py"
"$ROOT/tests/codex_profile_test.bash"
"$ROOT/tests/claude_launcher_test.bash"
"$ROOT/tests/kimi_launcher_test.bash"
"$ROOT/tests/cursor_agent_launcher_test.bash"
"$ROOT/tests/entrypoint_test.bash"
