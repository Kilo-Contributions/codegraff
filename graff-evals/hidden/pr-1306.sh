#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
INC="$TASK_ROOT/live/pr-1306/hidden_case.inc"
if ! grep -qF "test \"a marker split across deltas leaves no cite or turn words behind\"" src/acp_citations.zig 2>/dev/null; then
  cat "$INC" >> src/acp_citations.zig
fi
exec python3 "$TASK_ROOT/named_unit_check.py" "a marker split across deltas leaves no cite or turn words behind"
