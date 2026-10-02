import json

from cli.search import by_domain
from cli.show import main as show
from jobs.cleanup import inactive_names
from jobs.digest import recipients
from jobs.export import export_json
from web.admin import roster
from web.feed import greeting
from web.profile import profile_card

assert profile_card(1) == "Ada <ada@example.com>", profile_card(1)
assert profile_card(3) == "unknown user", profile_card(3)
assert profile_card(9) == "unknown user", profile_card(9)
assert roster() == ["1: Ada", "2: Grace", "3: Linus (inactive)"], roster()
assert greeting(2) == "Welcome back, Grace!", greeting(2)
assert greeting(3) == "Welcome!", greeting(3)
assert greeting(9) == "Welcome!", greeting(9)
assert recipients() == ["ada@example.com", "grace@example.com"], recipients()
assert inactive_names() == ["Linus"], inactive_names()
assert json.loads(export_json()) == [{"id": 1, "name": "Ada"}, {"id": 2, "name": "Grace"}], export_json()
assert show(["show", "3"]) == "Linus (linus@example.org)", show(["show", "3"])
assert show(["show", "7"]) == "no such user", show(["show", "7"])
assert by_domain("example.com") == ["Ada", "Grace"], by_domain("example.com")
assert by_domain("example.org") == ["Linus"], by_domain("example.org")
print("all OK")
