#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
exec python3 "$TASK_ROOT/named_unit_check.py" "a read-only child keeps reads and read-only shell, not writes (#1360)"
