#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
exec python3 "$TASK_ROOT/named_unit_check.py" "parse: stdio with args and env, http with headers, sse and malformed left out"
