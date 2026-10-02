from api.app import add_route, route


@route("GET", "/orders")
def list_orders(req):
    return []


@route("GET", "/orders/<id>")
def get_order(req, id):
    return {}


@route("POST", "/orders/<id>/cancel")
def cancel_order(req, id):
    return {}


def refund(req, id):
    return {}


add_route("POST", "/orders/<id>/refund", refund)
