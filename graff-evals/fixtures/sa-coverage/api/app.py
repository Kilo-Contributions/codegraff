"""Tiny router: endpoints register with @route(METHOD, PATH) or add_route(METHOD, PATH, handler)."""
ROUTES = {}


def add_route(method, path, handler):
    ROUTES[(method, path)] = handler
    return handler


def route(method, path):
    def wrap(handler):
        return add_route(method, path, handler)
    return wrap
