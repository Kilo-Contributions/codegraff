from core.users import all_ids, fetch_user


def roster():
    """Every user, inactive ones marked."""
    lines = []
    for uid in all_ids():
        u = fetch_user(uid)
        mark = "" if u["active"] else " (inactive)"
        lines.append(f"{u['uid']}: {u['name']}{mark}")
    return lines
