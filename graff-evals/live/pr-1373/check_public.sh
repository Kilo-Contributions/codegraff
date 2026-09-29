#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
exec python3 "$TASK_ROOT/named_unit_check.py" "an agent's room line becomes an advisory room message; a person's stays a prompt"
