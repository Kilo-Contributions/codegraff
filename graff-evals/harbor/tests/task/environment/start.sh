#!/bin/sh
# Serve the scripted model, then run whatever the environment starts the
# container with (Harbor's Apple container backend passes `sh -c "sleep
# infinity"`; with no command, keep the container alive).
python /mock_model.py --script /script.json --port 1234 >/tmp/model.log 2>&1 &
if [ "$#" -gt 0 ]; then exec "$@"; fi
exec sleep infinity
