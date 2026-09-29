#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
INC="$TASK_ROOT/live/pr-1257/hidden_case.inc"
if ! grep -qF "test \"an over-limit record is dropped and the next one still arrives\"" src/stdin_line.zig 2>/dev/null; then
  cat "$INC" >> src/stdin_line.zig
fi
exec python3 "$TASK_ROOT/named_unit_check.py" "an over-limit record is dropped and the next one still arrives"
