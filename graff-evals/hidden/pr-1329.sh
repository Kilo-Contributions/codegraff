#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
INC="$TASK_ROOT/live/pr-1329/hidden_case.inc"
if ! grep -qF "test \"joinWithin (#1291): a stalled handshake returns at the budget and stays queued\"" src/acp_mcp_servers.zig 2>/dev/null; then
  cat "$INC" >> src/acp_mcp_servers.zig
fi
exec python3 "$TASK_ROOT/named_unit_check.py" "joinWithin (#1291): a stalled handshake returns at the budget and stays queued"
