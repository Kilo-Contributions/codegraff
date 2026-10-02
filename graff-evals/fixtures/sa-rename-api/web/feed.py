from core import users


def greeting(uid):
    user = users.fetch_user(uid)
    name = user.get("name") if user else None
    return f"Welcome back, {name}!" if name and user.get("active") else "Welcome!"
