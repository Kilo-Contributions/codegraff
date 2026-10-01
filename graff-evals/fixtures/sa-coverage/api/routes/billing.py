from api.app import route


@route("GET", "/invoices")
def list_invoices(req):
    return []


@route("GET", "/invoices/<id>")
def get_invoice(req, id):
    return {}


@route("POST", "/invoices/<id>/pay")
def pay_invoice(req, id):
    return {}


@route("PUT", "/billing/plan")
def change_plan(req):
    return {}
