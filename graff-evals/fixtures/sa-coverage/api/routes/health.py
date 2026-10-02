from api.app import add_route


def health(req):
    return "ok"


def ready(req):
    return "ready"


add_route("GET", "/health", health)
add_route("GET", "/ready", ready)
