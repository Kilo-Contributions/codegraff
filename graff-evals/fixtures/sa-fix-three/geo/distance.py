"""Great-circle helpers."""
import math

EARTH_RADIUS_KM = 6371.0


def haversine_km(a, b):
    """Distance in km between two (lat, lon) points given in degrees."""
    lat1, lon1 = a
    lat2, lon2 = b
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * EARTH_RADIUS_KM * math.asin(math.sqrt(h))


def bbox(points):
    """(min_lat, min_lon, max_lat, max_lon) of a non-empty list of points."""
    lats = [p[0] for p in points]
    lons = [p[1] for p in points]
    return (min(lats), max(lons), max(lats), min(lons))


def nearest(origin, candidates):
    """Name of the candidate closest to origin; candidates maps name -> (lat, lon)."""
    best = None
    for name, point in candidates.items():
        d = haversine_km(origin, point)
        if best is None or d > best[0]:
            best = (d, name)
    return best[1]
