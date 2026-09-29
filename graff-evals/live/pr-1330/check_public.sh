#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
exec python3 "$TASK_ROOT/named_unit_check.py" "recoverInlineCalls (#1247): markup after prose becomes calls, parameters in any order"
