"""In-client invite minting endpoint (Option C delivery, Option B credential).

The governance-dashboard widget (operator's browser) calls this; it:
  1. verifies the operator's Matrix OpenID token via the INTERNAL userinfo
     endpoint (the `openid` listener resource; federation stays closed),
  2. requires PL >= 75 (organizer) in #governance — where `!gov role` sets it,
  3. per requested invite: calls mint-svc (the isolated MAS-admin holder) for a
     single-use expiring token, records the HASH-only vouch (vouch.jsonl +
     #vouch-log), renders the card,
  4. returns the card(s) to the browser.

The token reaches only this HTTPS response — never Matrix. #vouch-log gets the
SHA-256 hash, exactly like mint-invite.sh. Runs in a daemon thread from
bot.main(); Caddy proxies /governance/mint to it.
"""

import hashlib
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import requests as http

import bot

MINT_SVC_URL = os.environ.get("MINT_SVC_URL", "http://mint-svc:8090").rstrip("/")
MINT_SVC_SECRET = os.environ.get("MINT_SVC_SECRET", "")
RENDER_SCRIPT = os.environ.get("RENDER_SCRIPT", "/app/render-invite-card.py")
PUBLIC_BASE = os.environ.get("REDNET_PUBLIC_BASE", "") or f"https://{bot.DOMAIN}"
BRAND = os.environ.get("REDNET_BRAND", "REDnet")
BIND = os.environ.get("MINT_ENDPOINT_BIND", "0.0.0.0:8091")

FORMATS = {"print-card", "wallet", "half-sheet", "plain"}
MAX_BATCH = 25


def verify_openid(openid_token):
    """Return the operator's MXID from a Matrix OpenID token, or None.

    Uses the internal userinfo endpoint (openid listener resource). This is the
    only thing that authenticates the caller — everything downstream trusts it.
    """
    if not openid_token or not isinstance(openid_token, str):
        return None
    try:
        r = http.get(
            f"{bot.ACCESS}/_matrix/federation/v1/openid/userinfo",
            params={"access_token": openid_token},
            timeout=10,
        )
        if r.status_code == 200:
            return r.json().get("sub")
    except Exception:
        pass
    return None


def is_organizer(mxid):
    gov = bot.ROOM_IDS.get("governance")
    if not gov or not mxid:
        return False
    try:
        return bot.get_power_level(gov, mxid) >= bot.PL_ORGANIZER
    except Exception:
        return False


def call_mint(expires_in):
    r = http.post(
        f"{MINT_SVC_URL}/mint",
        headers={"X-Mint-Secret": MINT_SVC_SECRET, "Content-Type": "application/json"},
        json={"expires_in": expires_in} if expires_in else {},
        timeout=20,
    )
    d = r.json()
    if "token" not in d:
        raise RuntimeError(f"mint-svc error: {d}")
    return d["token"], d.get("expires_at", "")


def record_vouch(token, voucher, label):
    """Attribute the invite to the operator — HASH only, never the token.

    Returns (token_hash, vouch_recorded). vouch_recorded is True only when the
    #vouch-log event actually posted (Synapse returned an event_id); a swallowed
    failure would leave an admission with no room-visible provenance, so the
    caller surfaces this to the operator instead of handing out a card silently.
    """
    h = hashlib.sha256(token.encode()).hexdigest()
    ts = bot.now_iso()
    bot.append_vouch_jsonl(
        {
            "type": "vouch",
            "token_hash": h,
            "voucher": voucher,
            "label": label,
            "compartment": None,
            "timestamp": ts,
            "source": "in-client",
        }
    )
    posted = False
    vl = bot.ROOM_IDS.get("vouch-log")
    if vl:
        body = {
            "msgtype": "org.rednet.vouch",
            "body": f"Invite minted by {voucher} for {label}",
            "org.rednet.vouch": {
                "token_hash": h,
                "voucher": voucher,
                "label": label,
                "compartment": None,
                "timestamp": ts,
            },
        }
        try:
            r = http.put(
                f"{bot.ACCESS}/_matrix/client/v3/rooms/{bot.enc(vl)}/send/m.room.message/{bot.txn_id()}",
                headers=bot.SYS_HEADERS,
                json=body,
                timeout=10,
            )
            posted = r.status_code == 200 and bool((r.json() or {}).get("event_id"))
            if not posted:
                print(
                    f"[WARN] vouch-log post returned no event_id (status {r.status_code})",
                    file=sys.stderr,
                )
        except Exception as e:
            print(f"[WARN] vouch-log post failed: {e}", file=sys.stderr)
    else:
        print(
            "[WARN] vouch-log room unknown — provenance recorded locally only",
            file=sys.stderr,
        )
    return h, posted


def render_card(token, label, expires_at, fmt):
    out = subprocess.run(
        [
            "python3",
            RENDER_SCRIPT,
            "--format",
            fmt,
            "--token",
            token,
            "--domain",
            bot.DOMAIN,
            "--brand",
            BRAND,
            "--label",
            label or "",
            "--expires",
            (expires_at or "")[:10],
            "--public-base",
            PUBLIC_BASE,
        ],
        capture_output=True,
        text=True,
        timeout=15,
    )
    if out.returncode != 0:
        raise RuntimeError(f"render failed: {out.stderr[:200]}")
    return out.stdout


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        payload = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):  # never log bodies (they carry tokens)
        sys.stderr.write("mint-endpoint %s\n" % (fmt % args))

    def do_GET(self):
        (
            self._json(200, {"ok": True})
            if self.path == "/governance/mint/healthz"
            else self._json(404, {"error": "not_found"})
        )

    def do_POST(self):
        if self.path != "/governance/mint":
            return self._json(404, {"error": "not_found"})
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
            body = json.loads(self.rfile.read(length) or b"{}") if length else {}
        except (ValueError, json.JSONDecodeError):
            return self._json(400, {"error": "bad_request"})

        mxid = verify_openid(body.get("openid_token"))
        if not mxid:
            return self._json(401, {"error": "unauthorized"})
        if not is_organizer(mxid):
            return self._json(403, {"error": "not_an_organizer"})

        label = (body.get("label") or "").strip()
        if not label:
            return self._json(400, {"error": "label_required"})
        fmt = body.get("format", "print-card")
        if fmt not in FORMATS:
            return self._json(400, {"error": "bad_format"})
        try:
            count = max(1, min(int(body.get("count", 1)), MAX_BATCH))
        except (TypeError, ValueError):
            count = 1
        expires_in = body.get("expires_in")

        invites = []
        try:
            for i in range(count):
                lbl = label if count == 1 else f"{label} #{i + 1}"
                token, exp = call_mint(expires_in)
                h, vouch_ok = record_vouch(token, mxid, lbl)
                content = render_card(token, lbl, exp, fmt)
                invites.append(
                    {
                        "label": lbl,
                        "expires_at": exp,
                        "token_hash": h,
                        "format": fmt,
                        "content": content,
                        "vouch_recorded": vouch_ok,
                    }
                )
        except Exception as e:
            print(f"[ERROR] mint endpoint: {e}", file=sys.stderr)
            # partial results are already vouched; surface what succeeded
            if not invites:
                return self._json(502, {"error": "mint_failed"})
        self._json(200, {"invites": invites, "voucher": mxid, "count": len(invites)})


def start():
    """Launch the endpoint in a daemon thread (called from bot.main())."""
    host, _, port = BIND.rpartition(":")
    srv = ThreadingHTTPServer((host or "0.0.0.0", int(port)), Handler)
    t = threading.Thread(target=srv.serve_forever, name="mint-endpoint", daemon=True)
    t.start()
    print(
        f"[INFO] mint endpoint listening on {host or '0.0.0.0'}:{port}", file=sys.stderr
    )
