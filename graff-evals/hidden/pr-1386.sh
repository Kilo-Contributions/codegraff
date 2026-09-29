#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
INC="$TASK_ROOT/live/pr-1386/hidden_case.inc"
if ! grep -qF "test \"maker: routers' vendor prefixes and nested slugs\"" src/model_maker.zig 2>/dev/null; then
  cat "$INC" >> src/model_maker.zig
fi
exec python3 "$TASK_ROOT/named_unit_check.py" "maker: routers' vendor prefixes and nested slugs"
