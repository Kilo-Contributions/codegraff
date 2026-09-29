"""graff's one-shot usage footer, parsed for Harbor's token accounting.

`graff -p` ends stderr with one cumulative line:

    [usage] 3 api call(s) · 7538 in (4096 cached, 0 cache writes) + 512 out tokens · $0.01234567

"in" already counts the cached tokens. The dollar figure covers metered calls
only, so it is reported only when the line says nothing else was left out
(subscription calls, unpriced calls, or calls without usage).
"""

from __future__ import annotations

import re
from dataclasses import dataclass

ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
FOOTER = re.compile(
    r"^\[usage\]\s+(?P<partial>known subtotal:\s*)?(?P<calls>\d+) api call\(s\)\s*·\s*"
    r"(?P<input>\d+) in \((?P<cached>\d+) cached(?:, (?P<writes>\d+) cache writes)?\)\s*\+\s*"
    r"(?P<output>\d+) out tokens(?:\s*·\s*\$(?P<usd>[0-9]+(?:\.[0-9]+)?))?(?P<rest>.*)$"
)


@dataclass(frozen=True)
class Usage:
    calls: int
    input_tokens: int
    cached_tokens: int
    cache_write_tokens: int
    output_tokens: int
    cost_usd: float | None


def parse_footer(stderr: str) -> Usage | None:
    """The last footer line in `stderr`, or None when the run printed none."""
    found = None
    for line in stderr.splitlines():
        match = FOOTER.fullmatch(ANSI.sub("", line).strip())
        if match:
            found = match
    if found is None:
        return None
    complete = found["partial"] is None and not found["rest"].strip()
    usd = found["usd"]
    return Usage(
        calls=int(found["calls"]),
        input_tokens=int(found["input"]),
        cached_tokens=int(found["cached"]),
        cache_write_tokens=int(found["writes"] or 0),
        output_tokens=int(found["output"]),
        cost_usd=float(usd) if usd is not None and complete else None,
    )
