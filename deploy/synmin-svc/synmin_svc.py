#!/usr/bin/env python3
"""REDnet synmin service — the ONLY component that holds Synapse admin.

Least-privilege split (bootstrap audit F2): the gov-bot is the largest attack
surface in the stack (Matrix sync + !gov command parsing + an HTTP mint
endpoint). It previously carried a SYS_TOKEN scoped with urn:synapse:admin, so a
single RCE/SSRF meant full homeserver admin — deactivate any user, purge any
room. That token now drops the admin scope; the two admin operations the bot
actually needs, plus the per-user room enumeration terminal-revoke needs, move
here, behind one secret, on the internal network only (NOT Caddy-proxied).

This mirrors mint-svc, which does the same for urn:mas:admin. Stdlib only — the
smaller this powerful surface, the easier to audit.

Endpoints (all require X-Synmin-Secret):
  POST /purge-room   {"room_id": "!id:dom"}         -> Synapse delete-v2 response
  GET  /rooms?limit=500                             -> admin room list (audit sweep)
  GET  /user-rooms?user_id=@u:dom                   -> {"joined_rooms": [...]}
  GET  /healthz                                     -> {"ok": true}   (no secret)

Env:
  SYNMIN_SVC_SECRET   shared secret the gov-bot must present (required)
  SYNMIN_TOKEN        a Synapse access token carrying urn:synapse:admin (required)
  SYNAPSE_BASE        Synapse C-S/admin base URL (default http://synapse:8008)
  SYNMIN_BIND         bind address (default 0.0.0.0:8092)
"""

import hmac
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SYNMIN_SVC_SECRET = os.environ["SYNMIN_SVC_SECRET"]
SYNMIN_TOKEN = os.environ["SYNMIN_TOKEN"]
SYNAPSE_BASE = os.environ.get("SYNAPSE_BASE", "http://synapse:8008").rstrip("/")
BIND = os.environ.get("SYNMIN_BIND", "0.0.0.0:8092")


def _req(method, path, body=None, params=None):
    """Call the Synapse admin API with the admin token. Returns (status, json).

    Non-2xx is returned as (code, parsed-body) rather than raised, so the caller
    (the gov-bot) sees Synapse's real status + error instead of an opaque 502.
    """
    url = f"{SYNAPSE_BASE}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {SYNMIN_TOKEN}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode() or "{}")
        except Exception:
            return e.code, {}


def purge_room(room_id):
    return _req(
        "DELETE",
        f"/_synapse/admin/v2/rooms/{urllib.parse.quote(room_id, safe='')}",
        body={"block": True, "purge": True},
    )


def list_rooms(limit=500):
    return _req("GET", "/_synapse/admin/v1/rooms", params={"limit": limit})


def user_rooms(user_id):
    return _req(
        "GET",
        f"/_synapse/admin/v1/users/{urllib.parse.quote(user_id, safe='')}/joined_rooms",
    )


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        payload = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):  # keep tokens/ids out of logs; path + code only
        sys.stderr.write("synmin-svc %s\n" % (fmt % args))

    def _authed(self):
        # constant-time secret check (see mint-svc for the timing rationale).
        got = self.headers.get("X-Synmin-Secret", "")
        return bool(got) and hmac.compare_digest(
            got.encode("utf-8"), SYNMIN_SVC_SECRET.encode("utf-8")
        )

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/healthz":
            return self._json(200, {"ok": True})
        if not self._authed():
            return self._json(403, {"error": "forbidden"})
        q = urllib.parse.parse_qs(parsed.query)
        try:
            if parsed.path == "/rooms":
                limit = int(q.get("limit", ["500"])[0])
                st, d = list_rooms(limit)
                return self._json(st, d)
            if parsed.path == "/user-rooms":
                uid = q.get("user_id", [""])[0]
                if not uid:
                    return self._json(400, {"error": "user_id required"})
                st, d = user_rooms(uid)
                return self._json(st, d)
        except Exception as e:
            sys.stderr.write(f"synmin-svc ERROR: {e}\n")
            return self._json(502, {"error": "upstream_failed"})
        return self._json(404, {"error": "not_found"})

    def do_POST(self):
        if self.path != "/purge-room":
            return self._json(404, {"error": "not_found"})
        if not self._authed():
            return self._json(403, {"error": "forbidden"})
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
            body = json.loads(self.rfile.read(length) or b"{}") if length else {}
        except (ValueError, json.JSONDecodeError):
            return self._json(400, {"error": "bad_request"})
        rid = body.get("room_id", "")
        if not rid:
            return self._json(400, {"error": "room_id required"})
        try:
            st, d = purge_room(rid)
            return self._json(st, d)
        except Exception as e:
            sys.stderr.write(f"synmin-svc ERROR: {e}\n")
            return self._json(502, {"error": "purge_failed"})


def main():
    host, _, port = BIND.rpartition(":")
    srv = ThreadingHTTPServer((host or "0.0.0.0", int(port)), Handler)
    sys.stderr.write(f"synmin-svc listening on {host or '0.0.0.0'}:{port}\n")
    srv.serve_forever()


if __name__ == "__main__":
    main()
