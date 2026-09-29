#!/bin/sh
set -eu
TASK_ROOT=${TASK_ROOT:?}
exec python3 "$TASK_ROOT/named_unit_check.py" "initRegistryConsent applies GRAFF_NO_PLUGINS before it reads any MCP config"
