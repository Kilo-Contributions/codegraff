#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
INC="$TASK_ROOT/live/pr-1254/hidden_case.inc"
if ! grep -qF "test \"parse: no params, no list, or an empty list is nothing to connect\"" src/acp_mcp_servers.zig 2>/dev/null; then
  cat "$INC" >> src/acp_mcp_servers.zig
fi
exec python3 "$TASK_ROOT/named_unit_check.py" "parse: no params, no list, or an empty list is nothing to connect"
