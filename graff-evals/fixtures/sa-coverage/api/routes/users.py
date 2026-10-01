from api.app import route


@route("GET", "/users")
def list_users(req):
    return []


@route("POST", "/users")
def create_user(req):
    return {}


@route("GET", "/users/<id>")
def get_user(req, id):
    return {}


# @route("DELETE", "/users/<id>")  # disabled until soft-delete ships
def delete_user(req, id):
    return None
