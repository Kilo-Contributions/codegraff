"""Held-out checks for sa-fix-three: each package's contract beyond its visible test."""
import os
import sys

sys.path.insert(0, os.getcwd())
from geo.distance import bbox, haversine_km, nearest  # noqa: E402
from ledger.money import format_cents, parse_amount, split_evenly  # noqa: E402
from textkit.slug import slugify, title_case, truncate  # noqa: E402

NYC = (40.7128, -74.006)
LA = (34.0522, -118.2437)
SYDNEY = (-33.8688, 151.2093)
d = haversine_km(NYC, LA)
assert 3930 < d < 3940, d
assert abs(haversine_km(NYC, LA) - haversine_km(LA, NYC)) < 1e-6
assert bbox([NYC, LA, SYDNEY]) == (-33.8688, -118.2437, 40.7128, 151.2093), bbox([NYC, LA, SYDNEY])
assert bbox([NYC]) == (40.7128, -74.006, 40.7128, -74.006)
assert nearest(NYC, {"sydney": SYDNEY, "la": LA, "nyc2": (40.73, -73.99)}) == "nyc2"

assert slugify("--Already--Slugged--") == "already-slugged", slugify("--Already--Slugged--")
assert slugify("C3PO & R2D2") == "c3po-r2d2", slugify("C3PO & R2D2")
assert truncate("abcdefghij", 10) == "abcdefghij"
assert truncate("abcdefghij", 9) == "abcdef...", truncate("abcdefghij", 9)
assert len(truncate("x" * 50, 20)) == 20
assert title_case("a tale of two cities") == "A Tale of Two Cities", title_case("a tale of two cities")
assert title_case("war and peace") == "War and Peace"

assert parse_amount("1,000,000") == 100000000, parse_amount("1,000,000")
assert parse_amount("4.35") == 435, parse_amount("4.35")
assert parse_amount(" $0.07 ") == 7, parse_amount(" $0.07 ")
assert format_cents(5) == "$0.05", format_cents(5)
assert format_cents(100000000) == "$1,000,000.00", format_cents(100000000)
assert format_cents(-123456789) == "-$1,234,567.89", format_cents(-123456789)
assert split_evenly(10, 4) == [3, 3, 2, 2], split_evenly(10, 4)
assert split_evenly(7, 7) == [1] * 7
assert sum(split_evenly(1001, 6)) == 1001
print("sa-fix-three hidden OK")
