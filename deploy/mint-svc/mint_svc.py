#!/usr/bin/env python3
"""REDnet mint service — the ONLY component that holds MAS-admin power.

Least-privilege split (COMMUNITY-MANAGEMENT.md / invite minting): the gov-bot
does operator auth + the vouch record, then calls this service for the two
privileged MAS-admin steps it needs — creating a registration token (minting an
invite) and locking an account (terminal revoke, F11). MAS admin is
all-or-nothing (urn:mas:admin), so we isolate that credential here, behind these
two operations, away from the gov-bot's larger attack surface (Matrix sync +
command parsing).

Reachability is defence-in-depth:
  - only on the internal docker network (NOT proxied by Caddy), and
  - every request must carry the shared secret in X-Mint-Secret.

Dependency-free (stdlib only) to keep this powerful surface small and auditable.

Endpoints (both require X-Mint-Secret):
  POST /mint   {"expires_in": 604800}
    -> 200 {"token": "...", "expires_at": "2026-07-09T...Z"}
  POST /lock   {"user": "@alice:dom"}   (MXID or bare username)
    -> 200 {"locked": true, "user_id": "01K..."}

Env:
  MINT_SVC_SECRET     shared secret the gov-bot must present (required)
  MAS_BASE            MAS base URL (default http://mas:8080)
  MINT_CLIENT_ID      OAuth client_id with client_credentials + admin_clients
  MINT_CLIENT_SECRET  its client secret
  MINT_BIND           bind address (default 0.0.0.0:8090)
  MINT_MAX_EXPIRES_IN cap on requested expiry seconds (default 2592000 = 30d)
"""

import hmac
import json
import os
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MINT_SVC_SECRET = os.environ["MINT_SVC_SECRET"]
MAS_BASE = os.environ.get("MAS_BASE", "http://mas:8080").rstrip("/")
CLIENT_ID = os.environ["MINT_CLIENT_ID"]
CLIENT_SECRET = os.environ["MINT_CLIENT_SECRET"]
MAX_EXPIRES_IN = int(os.environ.get("MINT_MAX_EXPIRES_IN", str(30 * 24 * 3600)))
DEFAULT_EXPIRES_IN = 7 * 24 * 3600

TOKEN_URL = f"{MAS_BASE}/oauth2/token"
ADMIN_TOKENS_URL = f"{MAS_BASE}/api/admin/v1/user-registration-tokens"


def _post(url, data, headers, is_json):
    body = (
        json.dumps(data).encode() if is_json else urllib.parse.urlencode(data).encode()
    )
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read().decode())


def admin_token():
    """client_credentials -> a short-lived urn:mas:admin access token."""
    resp = _post(
        TOKEN_URL,
        {
            "grant_type": "client_credentials",
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
            "scope": "urn:mas:admin",
        },
        {"Content-Type": "application/x-www-form-urlencoded"},
        is_json=False,
    )
    tok = resp.get("access_token")
    if not tok:
        raise RuntimeError(f"no admin token: {resp}")
    return tok


def mint(expires_in):
    """Create a single-use, expiring registration token. Returns (token, expires_at)."""
    expires_in = max(60, min(int(expires_in or DEFAULT_EXPIRES_IN), MAX_EXPIRES_IN))
    expires_at = (datetime.now(timezone.utc) + timedelta(seconds=expires_in)).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    resp = _post(
        ADMIN_TOKENS_URL,
        {"usage_limit": 1, "expires_at": expires_at},
        {
            "Authorization": f"Bearer {admin_token()}",
            "Content-Type": "application/json",
        },
        is_json=True,
    )
    attrs = resp.get("data", {}).get("attributes", {})
    token = attrs.get("token")
    if not token:
        raise RuntimeError(f"mint failed: {resp}")
    return token, attrs.get("expires_at", expires_at)


def lock_user(user):
    """Lock a MAS account by MXID or username. Returns the MAS user id (ULID).

    Terminal-revoke (F11) needs this and the bot can't run mas-cli, so it goes
    through the MAS admin API — verified: POST /users/{id}/lock -> 200. Lock is
    reversible and keeps the account + its data (unlike deactivate), so the
    coercion-canary investigation retains its evidence. Resolves username -> ULID
    by exact match first (search is a prefix/fuzzy filter).
    """
    username = user.lstrip("@").split(":")[0]
    hdr = {
        "Authorization": f"Bearer {admin_token()}",
        "Content-Type": "application/json",
    }
    q = urllib.parse.urlencode({"filter[search]": username})
    req = urllib.request.Request(
        f"{MAS_BASE}/api/admin/v1/users?{q}", headers=hdr, method="GET"
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        found = json.loads(r.read().decode())
    uid = next(
        (
            u["id"]
            for u in found.get("data", [])
            if u.get("attributes", {}).get("username") == username
        ),
        None,
    )
    if not uid:
        raise RuntimeError(f"user not found: {username}")
    req = urllib.request.Request(
        f"{MAS_BASE}/api/admin/v1/users/{uid}/lock", headers=hdr, method="POST"
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        if r.status != 200:
            raise RuntimeError(f"lock failed: HTTP {r.status}")
    return uid


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        payload = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):  # keep tokens out of logs; log path + code only
        sys.stderr.write("mint-svc %s\n" % (fmt % args))

    def do_GET(self):
        if self.path == "/healthz":
            self._json(200, {"ok": True})
        else:
            self._json(404, {"error": "not_found"})

    def do_POST(self):
        if self.path not in ("/mint", "/lock"):
            return self._json(404, {"error": "not_found"})
        # constant-time secret check — hmac.compare_digest avoids leaking the
        # secret's length/prefix through byte-by-byte `!=` short-circuit timing.
        # Compare as bytes: compare_digest rejects non-ASCII str, so a crafted
        # header value would otherwise raise and 500 instead of a clean 403.
        got = self.headers.get("X-Mint-Secret", "")
        if not got or not hmac.compare_digest(
            got.encode("utf-8"), MINT_SVC_SECRET.encode("utf-8")
        ):
            return self._json(403, {"error": "forbidden"})
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
            body = json.loads(self.rfile.read(length) or b"{}") if length else {}
        except (ValueError, json.JSONDecodeError):
            return self._json(400, {"error": "bad_request"})

        if self.path == "/lock":
            user = body.get("user", "")
            if not user:
                return self._json(400, {"error": "user required"})
            try:
                uid = lock_user(user)
            except Exception as e:  # never leak internals to the caller
                sys.stderr.write(f"mint-svc ERROR: {e}\n")
                return self._json(502, {"error": "lock_failed"})
            return self._json(200, {"locked": True, "user_id": uid})

        try:
            token, expires_at = mint(body.get("expires_in"))
        except Exception as e:  # never leak internals to the caller
            sys.stderr.write(f"mint-svc ERROR: {e}\n")
            return self._json(502, {"error": "mint_failed"})
        self._json(200, {"token": token, "expires_at": expires_at})


def main():
    host, _, port = os.environ.get("MINT_BIND", "0.0.0.0:8090").rpartition(":")
    srv = ThreadingHTTPServer((host or "0.0.0.0", int(port)), Handler)
    sys.stderr.write(f"mint-svc listening on {host or '0.0.0.0'}:{port}\n")
    srv.serve_forever()


if __name__ == "__main__":
    main()
