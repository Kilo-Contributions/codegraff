#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
exec python3 "$TASK_ROOT/named_unit_check.py" "a check promoted to the background resolves when its job exits 0 (#1326)"
