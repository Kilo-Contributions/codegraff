# Orders

### GET /orders
Lists the caller's orders, newest first.

### GET /orders/<id>
One order with its line items.

#### Example
A cancelled order keeps its line items.

### POST /orders/<id>/cancel
Cancels an order that has not shipped.
