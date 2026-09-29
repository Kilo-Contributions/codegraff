#!/bin/bash
set -euo pipefail
test "$(cat /app/answer)" = done
test ! -e /app/.graff
printf '1\n' > /logs/verifier/reward.txt
