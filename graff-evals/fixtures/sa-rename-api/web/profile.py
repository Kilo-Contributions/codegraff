from core.users import fetch_user


def profile_card(uid):
    u = fetch_user(uid)
    if u is None or not u["active"]:
        return "unknown user"
    return f"{u['name']} <{u['email']}>"
