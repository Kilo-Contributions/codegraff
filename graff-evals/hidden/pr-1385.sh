#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
INC="$TASK_ROOT/live/pr-1385/hidden_case.inc"
if ! grep -qF "test \"detect: anything else is plain text\"" src/acp_view_meta.zig 2>/dev/null; then
  cat "$INC" >> src/acp_view_meta.zig
fi
exec python3 "$TASK_ROOT/named_unit_check.py" "detect: anything else is plain text"
