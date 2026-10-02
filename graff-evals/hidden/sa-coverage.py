"""Held-out check for sa-coverage: exact endpoint coverage lists."""
import json

want = {
    "undocumented": [
        "GET /admin/stats",
        "GET /invoices/<id>",
        "GET /ready",
        "GET /search/suggest",
        "POST /admin/reindex",
        "POST /orders/<id>/refund",
    ],
    "stale_docs": [
        "DELETE /users/<id>",
        "GET /search/legacy",
        "POST /admin/flush",
        "POST /billing/coupon",
    ],
}
got = json.load(open("coverage.json"))
assert isinstance(got, dict), got
for key, value in want.items():
    assert got.get(key) == value, f"{key}: got {got.get(key)!r}, want {value!r}"
print("sa-coverage hidden OK")
