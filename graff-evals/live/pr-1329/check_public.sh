#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
exec python3 "$TASK_ROOT/named_unit_check.py" "joinWithin (#1291): a server that fails fast ends the wait early"
