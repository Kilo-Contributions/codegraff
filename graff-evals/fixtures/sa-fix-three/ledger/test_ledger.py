import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from ledger.money import format_cents, parse_amount, split_evenly  # noqa: E402

assert parse_amount("$1,234.50") == 123450, parse_amount("$1,234.50")
assert parse_amount("0.29") == 29, parse_amount("0.29")
assert parse_amount("-12.5") == -1250, parse_amount("-12.5")
assert format_cents(123450) == "$1,234.50", format_cents(123450)
assert format_cents(-1250) == "-$12.50", format_cents(-1250)
assert split_evenly(100, 3) == [34, 33, 33], split_evenly(100, 3)
print("ledger OK")
