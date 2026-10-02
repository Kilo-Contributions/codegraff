"""Held-out check for sa-sidecar: parser contract plus the sub-agent's docs/FORMAT.md."""
import os
import re
import sys
import tempfile

sys.path.insert(0, os.getcwd())
from confparse.parser import ConfError, parse  # noqa: E402

assert parse("set a = 1\nunset a\n") == {}, parse("set a = 1\nunset a\n")
assert parse("[db]\nset host = x\nset port = 5\nunset db.port\n") == {"db.host": "x"}
assert parse("[db]\nset host = x\nunset host\n[web]\nset host = y\n") == {"web.host": "y"}
assert parse('set tag = "a#b"  # trailing\n') == {"tag": "a#b"}, parse('set tag = "a#b"  # trailing\n')
assert parse("set n = 3 # three\n# set m = 4\n") == {"n": 3}
d = tempfile.mkdtemp()
for name, body in {
    "base.conf": "set level = 1\n",
    "x.conf": "include base.conf\nset x = 1\n",
    "y.conf": "include x.conf\ninclude base.conf\n",
    "self.conf": "include self.conf\n",
}.items():
    with open(os.path.join(d, name), "w") as f:
        f.write(body)
assert parse("include y.conf\ninclude x.conf\n", d) == {"level": 1, "x": 1}
try:
    parse("include self.conf\n", d)
    raise SystemExit("expected ConfError for a self-include")
except ConfError:
    pass
try:
    parse("frobnicate now\n")
    raise SystemExit("expected ConfError for an unknown directive")
except ConfError:
    pass

doc_path = os.path.join("docs", "FORMAT.md")
assert os.path.isfile(doc_path), "docs/FORMAT.md is missing"
doc = open(doc_path).read()
lines = [x for x in doc.splitlines() if x.strip()]
assert len(lines) >= 12, f"docs/FORMAT.md is too thin ({len(lines)} non-empty lines)"
for word in ("include", "set", "unset", "alias"):
    assert re.search(rf"\b{word}\b", doc), f"docs/FORMAT.md never mentions the {word} directive"
assert "[" in doc and re.search(r"section", doc, re.I), "docs/FORMAT.md does not describe [section] headers"
assert "#" in doc, "docs/FORMAT.md does not describe comments"
print("sa-sidecar hidden OK")
