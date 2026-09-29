#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
INC="$TASK_ROOT/live/pr-1330/hidden_case.inc"
if ! grep -qF "test \"recoverInlineCalls (#1247): quoted, unwrapped, unknown, or malformed markup stays text\"" src/tool_call_repair_tests.zig 2>/dev/null; then
  cat "$INC" >> src/tool_call_repair_tests.zig
fi
exec python3 "$TASK_ROOT/named_unit_check.py" "recoverInlineCalls (#1247): quoted, unwrapped, unknown, or malformed markup stays text"
