#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
exec python3 "$TASK_ROOT/named_unit_check.py" "decline, cancel, an empty accept and an error each end the question as themselves (#1322)"
