"""User store."""
from dataclasses import dataclass

_USERS = {
    1: {"name": "Ada", "email": "ada@example.com", "active": True},
    2: {"name": "Grace", "email": "grace@example.com", "active": True},
    3: {"name": "Linus", "email": "linus@example.org", "active": False},
}


@dataclass(frozen=True)
class User:
    uid: int
    name: str
    email: str
    active: bool


def fetch_user(uid):
    """Return the user record as a dict (with its uid), or None."""
    row = _USERS.get(uid)
    return dict(row, uid=uid) if row else None


def all_ids():
    return sorted(_USERS)
