import json

from core.users import all_ids, fetch_user


def export_json():
    rows = [fetch_user(uid) for uid in all_ids()]
    return json.dumps([{"id": r["uid"], "name": r["name"]} for r in rows if r["active"]])
