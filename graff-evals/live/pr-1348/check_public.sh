#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
exec python3 "$TASK_ROOT/named_unit_check.py" "one check in one directory is one entry whatever its spelling"
