import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from geo.distance import bbox, haversine_km, nearest  # noqa: E402

PARIS = (48.8566, 2.3522)
LONDON = (51.5074, -0.1278)
BERLIN = (52.52, 13.405)

d = haversine_km(PARIS, LONDON)
assert 340 < d < 345, d
assert haversine_km(PARIS, PARIS) < 1e-9
assert bbox([PARIS, LONDON, BERLIN]) == (48.8566, -0.1278, 52.52, 13.405), bbox([PARIS, LONDON, BERLIN])
assert nearest(PARIS, {"london": LONDON, "berlin": BERLIN}) == "london"
print("geo OK")
