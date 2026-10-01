from api.app import route


@route("GET", "/search")
def search(req):
    return []


@route("GET", "/search/suggest")
def suggest(req):
    return []
