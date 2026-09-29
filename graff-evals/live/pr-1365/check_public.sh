#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
exec python3 "$TASK_ROOT/named_unit_check.py" "a cut-off Anthropic tool input is refused, not run as {} (#1218)"
