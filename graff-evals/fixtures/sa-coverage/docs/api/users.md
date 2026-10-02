# Users

All user endpoints return JSON. Use `GET /users` to page through accounts.

### GET /users
Lists users, 50 per page.

### POST /users
Creates a user from `{"name", "email"}`.

### GET /users/<id>
One user by id.

### DELETE /users/<id>
Deletes a user and their sessions.
