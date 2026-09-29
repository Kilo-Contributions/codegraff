#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
exec python3 "$TASK_ROOT/named_unit_check.py" "shutdown frees a filled cache and is a no-op when empty (#1196)"
