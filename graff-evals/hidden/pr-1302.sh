#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
INC="$TASK_ROOT/live/pr-1302/hidden_case.inc"
if ! grep -qF "test \"mixed documentation changes leave room for committed test roots\"" src/pr_review_input.zig 2>/dev/null; then
  cat "$INC" >> src/pr_review_input.zig
fi
exec python3 "$TASK_ROOT/named_unit_check.py" "mixed documentation changes leave room for committed test roots"
