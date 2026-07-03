"""Client for the two isolated admin services (bootstrap audit F2).

The gov-bot no longer holds urn:synapse:admin or urn:mas:admin. Privileged
operations go through internal, secret-gated services instead:
  - synmin-svc (urn:synapse:admin): purge a room, list all rooms, a user's rooms
  - mint-svc   (urn:mas:admin):     lock an account (also mints invites)

So a compromise of the network-facing bot can only *request* these scoped ops,
never wield raw admin. Each call carries a shared secret; the services listen on
the internal docker network only (not Caddy-proxied).
"""

import os

import requests as http

SYNMIN_SVC_URL = os.environ.get("SYNMIN_SVC_URL", "http://synmin-svc:8092").rstrip("/")
SYNMIN_SVC_SECRET = os.environ.get("SYNMIN_SVC_SECRET", "")
MINT_SVC_URL = os.environ.get("MINT_SVC_URL", "http://mint-svc:8090").rstrip("/")
MINT_SVC_SECRET = os.environ.get("MINT_SVC_SECRET", "")


def _synmin_headers():
    return {"X-Synmin-Secret": SYNMIN_SVC_SECRET, "Content-Type": "application/json"}


def _mint_headers():
    return {"X-Mint-Secret": MINT_SVC_SECRET, "Content-Type": "application/json"}


def _json(r):
    try:
        return r.json()
    except Exception:
        return {}


def purge_room(room_id, timeout=35):
    """Delete + block a room via synmin-svc. Returns (status, json)."""
    r = http.post(
        f"{SYNMIN_SVC_URL}/purge-room",
        headers=_synmin_headers(),
        json={"room_id": room_id},
        timeout=timeout,
    )
    return r.status_code, _json(r)


def list_rooms(limit=500, timeout=35):
    """List all rooms (the audit sweep) via synmin-svc. Returns (status, json)."""
    r = http.get(
        f"{SYNMIN_SVC_URL}/rooms",
        headers=_synmin_headers(),
        params={"limit": limit},
        timeout=timeout,
    )
    return r.status_code, _json(r)


def user_rooms(user_id, timeout=20):
    """Room ids a user is joined to (for terminal revoke). Empty list on failure."""
    r = http.get(
        f"{SYNMIN_SVC_URL}/user-rooms",
        headers=_synmin_headers(),
        params={"user_id": user_id},
        timeout=timeout,
    )
    if r.status_code != 200:
        return []
    return _json(r).get("joined_rooms", [])


def lock_account(user, timeout=20):
    """Lock a MAS account via mint-svc. Returns True on success, False otherwise."""
    try:
        r = http.post(
            f"{MINT_SVC_URL}/lock",
            headers=_mint_headers(),
            json={"user": user},
            timeout=timeout,
        )
        return r.status_code == 200 and _json(r).get("locked") is True
    except Exception:
        return False
