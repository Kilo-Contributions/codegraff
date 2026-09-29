#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
INC="$TASK_ROOT/live/pr-1373/hidden_case.inc"
if ! grep -qF "test \"Harness's pre-framed text is kept, but only if it really carries the header\"" src/acp_room.zig 2>/dev/null; then
  cat "$INC" >> src/acp_room.zig
fi
exec python3 "$TASK_ROOT/named_unit_check.py" "Harness's pre-framed text is kept, but only if it really carries the header"
