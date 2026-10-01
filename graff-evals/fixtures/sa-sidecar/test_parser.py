import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from confparse.parser import ConfError, parse  # noqa: E402

conf = """
set name = "edge"
[server]
set port = 8080
set debug = true
set color = "#ff8800"   # brand color
unset debug
alias listen = port
"""
got = parse(conf)
assert got == {"name": "edge", "server.port": 8080, "server.color": "#ff8800", "listen": 8080}, got

d = tempfile.mkdtemp()
for name, body in {
    "common.conf": "set shared = 1\n",
    "b.conf": "include common.conf\nset b = 2\n",
    "c.conf": "include common.conf\nset c = 3\n",
    "loop1.conf": "include loop2.conf\n",
    "loop2.conf": "include loop1.conf\n",
}.items():
    with open(os.path.join(d, name), "w") as f:
        f.write(body)
got = parse("include b.conf\ninclude c.conf\n", d)
assert got == {"shared": 1, "b": 2, "c": 3}, got
try:
    parse("include loop1.conf\n", d)
    raise SystemExit("expected ConfError for an include cycle")
except ConfError:
    pass
print("parser OK")
