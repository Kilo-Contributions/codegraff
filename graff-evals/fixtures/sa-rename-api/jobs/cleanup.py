from core.users import all_ids, fetch_user


def inactive_names():
    return [fetch_user(uid)["name"] for uid in all_ids() if not fetch_user(uid)["active"]]
