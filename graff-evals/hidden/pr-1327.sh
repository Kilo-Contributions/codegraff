#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
INC="$TASK_ROOT/live/pr-1327/hidden_case.inc"
if ! grep -qF "test \"question aliases and a double-encoded argument string are read\"" src/ask_user_args.zig 2>/dev/null; then
  cat "$INC" >> src/ask_user_args.zig
fi
exec python3 "$TASK_ROOT/named_unit_check.py" "question aliases and a double-encoded argument string are read"
