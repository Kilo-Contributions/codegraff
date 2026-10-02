from api.app import add_route, route


@route("GET", "/admin/stats")
def stats(req):
    return {}


@route("POST", "/admin/reindex")
def reindex(req):
    return {}


def flush(req):
    return {}


# add_route("POST", "/admin/flush", flush)  # removed: flush runs from cron now
