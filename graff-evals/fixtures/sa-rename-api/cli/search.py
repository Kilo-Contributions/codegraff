from core.users import all_ids, fetch_user


def by_domain(domain):
    hits = []
    for uid in all_ids():
        u = fetch_user(uid)
        if u["email"].endswith("@" + domain):
            hits.append(u["name"])
    return hits
