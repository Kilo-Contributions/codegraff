#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
INC="$TASK_ROOT/live/pr-1348/hidden_case.inc"
if ! grep -qF "test \"sleepText names the cap when a longer pause was requested\"" src/rlm.zig 2>/dev/null; then
  cat "$INC" >> src/rlm.zig
fi
exec python3 "$TASK_ROOT/named_unit_check.py" "sleepText names the cap when a longer pause was requested"
