#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
INC="$TASK_ROOT/live/pr-1339/hidden_case.inc"
if ! grep -qF "test \"noAnswerText keeps cancel as cancel and never calls a lost question a cancel (#1322)\"" src/ask_user.zig 2>/dev/null; then
  cat "$INC" >> src/ask_user.zig
fi
exec python3 "$TASK_ROOT/named_unit_check.py" "noAnswerText keeps cancel as cancel and never calls a lost question a cancel (#1322)"
