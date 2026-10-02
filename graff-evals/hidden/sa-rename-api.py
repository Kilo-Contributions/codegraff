"""Held-out check for sa-rename-api: the new API exists, the old one is gone everywhere."""
import inspect
import os
import re
import sys

sys.path.insert(0, os.getcwd())
import core.users as users  # noqa: E402

assert not hasattr(users, "fetch_user"), "fetch_user still defined in core/users.py"
get_user, User = users.get_user, users.User
assert get_user(1) == User(1, "Ada", "ada@example.com", True), get_user(1)
assert get_user(3) is None, get_user(3)
assert get_user(9) is None and get_user(9, include_inactive=True) is None
assert get_user(3, include_inactive=True) == User(3, "Linus", "linus@example.org", False)
param = inspect.signature(get_user).parameters.get("include_inactive")
assert param is not None and param.kind is inspect.Parameter.KEYWORD_ONLY and param.default is False, param

stale = []
for pkg in ("core", "web", "jobs", "cli"):
    for root, dirs, files in os.walk(pkg):
        dirs[:] = [d for d in dirs if not d.startswith((".", "__"))]
        for name in files:
            if name.endswith(".py"):
                path = os.path.join(root, name)
                if re.search(r"\bfetch_user\b", open(path).read()):
                    stale.append(path)
assert not stale, f"fetch_user still referenced in {stale}"
print("sa-rename-api hidden OK")
