from core.users import all_ids, fetch_user


def recipients():
    """Emails of active users, in id order."""
    out = []
    for uid in all_ids():
        u = fetch_user(uid)
        if u and u["active"]:
            out.append(u["email"])
    return out
