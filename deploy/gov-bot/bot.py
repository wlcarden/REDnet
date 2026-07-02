#!/usr/bin/env python3
"""REDnet governance bot.

Listens in #gov-bot (non-E2EE) for !gov commands from organizers/admins.
Also creates unencrypted DM rooms with each member for private !report
commands — reports are forwarded to #gov-bot so operators see them, but
other members cannot see who reported whom.

All events are recorded to vouch.jsonl (canonical on-disk audit trail).
The bot does NOT post to E2EE rooms (#vouch-log, #welcome) since it
cannot encrypt.

Operator commands (in #gov-bot):
  !gov status                              PL 0   Bot health check
  !gov audit                               PL 50  Run canary checks
  !gov report @user --detail "..."         PL 0   Report compromised account
  !gov confirm @user [--label "desc"]      PL 75  Confirm a vouch
  !gov role @user moderator|organizer      PL 75  Set role (organizer needs PL100)
  !gov revoke @user --reason "..."         PL 100 Revoke a member
  !gov revoke-chain @voucher [--after D]   PL 100 Bulk revoke downstream vouches

Community management (in #gov-bot — see community.py / COMMUNITY-MANAGEMENT.md):
  !gov space|room|invite|rooms|members     PL 75  Create + inspect rooms/spaces
  !gov requests|approve|deny               PL 75  Member request queue
  !gov archive                             PL 75  Lock + unlink a room
  !gov delete <room> --confirm             PL 100 Purge a room from the server

Member commands (in DM with @rednet-gov):
  !report @user --detail "..."             Any    Private compromised-account report
  !report @user reason text                Any    Same, freeform detail
  !gov request room|space "Name" --why ... Any    Request a new room/space

Environment:
  REDNET_DOMAIN        Required. The Matrix server domain.
  GOV_BOT_TOKEN        Required. Compatibility token for @rednet-gov.
  SYS_TOKEN            Required. System account token for admin operations.
  REDNET_ACCESS_URL    Optional. Internal Synapse URL (default: http://synapse:8008).
  VOUCH_JSONL_PATH     Optional. Path to vouch.jsonl (default: /data/vouch.jsonl).
"""

import os
import sys
import time
import json
import re
import shlex
import hashlib
import secrets
from datetime import datetime, timezone, timedelta
from urllib.parse import quote

import requests as http

# When run as a script (python3 bot.py) this module is named __main__, so
# community.py's `import bot` would re-execute this file as a SECOND module
# and deadlock on the circular import. Alias ourselves under the module name
# first — community then binds the already-running instance, same as pytest.
if __name__ == "__main__":
    sys.modules["bot"] = sys.modules[__name__]

DOMAIN = os.environ["REDNET_DOMAIN"]
ACCESS = os.environ.get("REDNET_ACCESS_URL", "http://synapse:8008")
BOT_TOKEN = os.environ["GOV_BOT_TOKEN"]
SYS_TOKEN = os.environ["SYS_TOKEN"]
VOUCH_PATH = os.environ.get("VOUCH_JSONL_PATH", "/data/vouch.jsonl")

BOT_USER = f"@rednet-gov:{DOMAIN}"
BOT_HEADERS = {
    "Authorization": f"Bearer {BOT_TOKEN}",
    "Content-Type": "application/json",
}
SYS_HEADERS = {
    "Authorization": f"Bearer {SYS_TOKEN}",
    "Content-Type": "application/json",
}

COMMUNITY_ROOMS = [
    "community",
    "welcome",
    "announcements",
    "reference",
    "general",
]
GOVERNANCE_ROOMS = ["vouch-log", "governance"]

ROOM_IDS = {}
GOV_BOT_ROOM_ID = None

PL_MEMBER = 0
PL_MODERATOR = 50
PL_ORGANIZER = 75
PL_ADMIN = 100

ROLE_PL = {
    "member": PL_MEMBER,
    "moderator": PL_MODERATOR,
    "organizer": PL_ORGANIZER,
    "admin": PL_ADMIN,
}

BURST_THRESHOLD = 5
UNCLAIMED_RATE_THRESHOLD = 50
STALE_DAYS = 7

REPORT_DMS = {}
LAST_DM_SCAN = 0
DM_SCAN_INTERVAL = 300


def enc(s):
    return quote(s, safe="")


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def txn_id(prefix="gov"):
    return f"{prefix}-{int(time.time() * 1000)}-{secrets.token_hex(4)}"


def resolve_alias(alias):
    encoded = enc(f"#{alias}:{DOMAIN}")
    r = http.get(
        f"{ACCESS}/_matrix/client/v3/directory/room/{encoded}",
        headers=BOT_HEADERS,
        timeout=10,
    )
    return r.json().get("room_id", "")


def get_power_level(room_id, user_id):
    r = http.get(
        f"{ACCESS}/_matrix/client/v3/rooms/{enc(room_id)}/state/m.room.power_levels/",
        headers=SYS_HEADERS,
        timeout=10,
    )
    data = r.json()
    users = data.get("users", {})
    return users.get(user_id, data.get("users_default", 0))


def set_power_level(room_id, user_id, level):
    r = http.get(
        f"{ACCESS}/_matrix/client/v3/rooms/{enc(room_id)}/state/m.room.power_levels/",
        headers=SYS_HEADERS,
        timeout=10,
    )
    data = r.json()
    data.setdefault("users", {})[user_id] = level
    resp = http.put(
        f"{ACCESS}/_matrix/client/v3/rooms/{enc(room_id)}/state/m.room.power_levels/",
        headers=SYS_HEADERS,
        json=data,
        timeout=10,
    )
    return "event_id" in resp.json()


def invite_user(room_id, user_id):
    resp = http.post(
        f"{ACCESS}/_matrix/client/v3/rooms/{enc(room_id)}/invite",
        headers=SYS_HEADERS,
        json={"user_id": user_id},
        timeout=10,
    )
    data = resp.json()
    err = data.get("errcode", "")
    return not err or err == "M_FORBIDDEN"


def kick_user(room_id, user_id, reason=""):
    resp = http.post(
        f"{ACCESS}/_matrix/client/v3/rooms/{enc(room_id)}/kick",
        headers=SYS_HEADERS,
        json={"user_id": user_id, "reason": reason},
        timeout=10,
    )
    return "errcode" not in resp.json()


def _md_to_html(text):
    """Convert the Markdown subset the bot uses (bold, code, em-dash, newlines) to HTML."""
    h = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    h = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", h)
    h = re.sub(r"`(.+?)`", r"<code>\1</code>", h)
    h = re.sub(r" — ", r" &mdash; ", h)
    h = h.replace("\n", "<br>\n")
    return h


def send_message(room_id, body, msgtype="m.text", extra=None, headers=None):
    content = {
        "msgtype": msgtype,
        "body": body,
        "format": "org.matrix.custom.html",
        "formatted_body": _md_to_html(body),
    }
    if extra:
        content.update(extra)
    resp = http.put(
        f"{ACCESS}/_matrix/client/v3/rooms/{enc(room_id)}/send/m.room.message/{txn_id()}",
        headers=headers or BOT_HEADERS,
        json=content,
        timeout=10,
    )
    return resp.json().get("event_id", "")


def send_notice(room_id, body, extra=None):
    return send_message(room_id, body, msgtype="m.notice", extra=extra)


def reply(room_id, text):
    send_notice(room_id, text)


def read_vouch_jsonl():
    records = []
    if not os.path.exists(VOUCH_PATH):
        return records
    with open(VOUCH_PATH) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return records


def append_vouch_jsonl(record):
    with open(VOUCH_PATH, "a") as f:
        f.write(json.dumps(record, separators=(",", ":")) + "\n")


def discover_report_dms():
    """Load existing bot DM rooms from m.direct account data."""
    r = http.get(
        f"{ACCESS}/_matrix/client/v3/user/{enc(BOT_USER)}/account_data/m.direct",
        headers=BOT_HEADERS,
        timeout=10,
    )
    if r.status_code != 200:
        return
    data = r.json()
    for user_id, room_ids in data.items():
        if isinstance(room_ids, list) and room_ids:
            REPORT_DMS[user_id] = room_ids[0]
    print(
        f"[INFO] Discovered {len(REPORT_DMS)} existing report DM rooms", file=sys.stderr
    )


def save_m_direct():
    """Persist the bot's DM room mapping as m.direct account data."""
    payload = {uid: [rid] for uid, rid in REPORT_DMS.items()}
    http.put(
        f"{ACCESS}/_matrix/client/v3/user/{enc(BOT_USER)}/account_data/m.direct",
        headers=BOT_HEADERS,
        json=payload,
        timeout=10,
    )


def create_report_dm(user_id):
    """Create an unencrypted DM room with a member for private reporting."""
    if user_id in REPORT_DMS:
        return REPORT_DMS[user_id]

    resp = http.post(
        f"{ACCESS}/_matrix/client/v3/createRoom",
        headers=BOT_HEADERS,
        json={
            "preset": "trusted_private_chat",
            "invite": [user_id],
            "is_direct": True,
            "topic": "Private reporting channel",
            "initial_state": [],
        },
        timeout=10,
    )
    data = resp.json()
    room_id = data.get("room_id")
    if not room_id:
        print(
            f"[WARN] Failed to create report DM for {user_id}: {data}",
            file=sys.stderr,
        )
        return None

    REPORT_DMS[user_id] = room_id
    save_m_direct()

    send_notice(
        room_id,
        "**Private reporting channel**\n\n"
        "Use this room to report a compromised or suspicious account. "
        "Only organizers and admins will see your report.\n\n"
        'Usage: `!report @username --detail "describe what you observed"`\n\n'
        "You can also write the reason directly after the username:\n"
        "`!report @username suspicious login from new device`",
    )

    print(f"[INFO] Created report DM for {user_id}: {room_id}", file=sys.stderr)
    return room_id


def ensure_report_dms():
    """Scan community membership and create DM rooms for members who lack one."""
    global LAST_DM_SCAN
    LAST_DM_SCAN = time.time()

    community_rid = ROOM_IDS.get("community")
    if not community_rid:
        return

    r = http.get(
        f"{ACCESS}/_matrix/client/v3/rooms/{enc(community_rid)}/members",
        headers=SYS_HEADERS,
        params={"membership": "join"},
        timeout=30,
    )
    if r.status_code != 200:
        return

    created = 0
    for member in r.json().get("chunk", []):
        user_id = member.get("state_key", "")
        if not user_id or user_id == BOT_USER:
            continue
        if user_id.startswith("@rednet-"):
            continue
        if user_id not in REPORT_DMS:
            if create_report_dm(user_id):
                created += 1

    if created:
        print(f"[INFO] Created {created} new report DM rooms", file=sys.stderr)


def handle_report(room_id, sender, body):
    """Handle a !report command from a member's DM room."""
    if sender == BOT_USER:
        return

    parts = parse_args(body)
    if len(parts) < 2 or parts[0] != "!report":
        reply(
            room_id,
            'Usage: `!report @user --detail "describe what you observed"`\n'
            "Or: `!report @user reason text here`",
        )
        return

    args = parts[1:]
    positional, flags = parse_flags(args, "detail", "severity")

    if not positional or not positional[0].startswith("@"):
        reply(
            room_id,
            'Usage: `!report @user --detail "describe what you observed"`\n'
            "Or: `!report @user reason text here`",
        )
        return

    target = positional[0]
    detail = flags.get("detail", "")
    severity = flags.get("severity", "suspected")

    if not detail and len(positional) > 1:
        detail = " ".join(positional[1:])

    if not detail:
        reply(room_id, "Please include a description of what you observed.")
        return

    ts = now_iso()

    append_vouch_jsonl(
        {
            "type": "alert",
            "account": target,
            "reported_by": sender,
            "severity": severity,
            "detail": detail,
            "timestamp": ts,
        }
    )

    if GOV_BOT_ROOM_ID:
        alert_body = {
            "msgtype": "org.rednet.alert.compromised",
            "body": (
                f"ALERT: {target} reported as {severity} compromised"
                f" by {sender}: {detail}"
            ),
            "org.rednet.alert.compromised": {
                "account": target,
                "reported_by": sender,
                "severity": severity,
                "detail": detail,
                "timestamp": ts,
            },
        }
        send_message(
            GOV_BOT_ROOM_ID, alert_body["body"], extra=alert_body, headers=BOT_HEADERS
        )

    reply(
        room_id,
        f"Report received for `{target}`. "
        f"Organizers have been notified and will follow up.\n\n"
        f"You do not need to take further action unless contacted.",
    )


def parse_args(text):
    try:
        return shlex.split(text)
    except ValueError:
        return text.split()


def parse_flags(args, *flag_names):
    flags = {}
    i = 0
    positional = []
    while i < len(args):
        key = args[i].lstrip("-")
        if args[i].startswith("--") and key in flag_names:
            if i + 1 < len(args):
                flags[key] = args[i + 1]
                i += 2
            else:
                i += 1
        else:
            positional.append(args[i])
            i += 1
    return positional, flags


# --- Command handlers ---


def _server_health():
    """Probe Synapse for version and liveness. Uses unauthenticated client endpoints."""
    health = {"synapse": "unknown", "version": "?"}
    try:
        r = http.get(f"{ACCESS}/_matrix/client/versions", timeout=5)
        if r.status_code == 200:
            health["synapse"] = "up"
            versions = r.json().get("versions", [])
            if versions:
                health["version"] = versions[-1]
        else:
            health["synapse"] = f"error ({r.status_code})"
    except Exception:
        health["synapse"] = "unreachable"
    try:
        r = http.get(
            f"{ACCESS}/_matrix/client/v3/rooms/{enc(GOV_BOT_ROOM_ID)}/members",
            headers=SYS_HEADERS,
            params={"membership": "join"},
            timeout=10,
        )
        if r.status_code == 200:
            members = r.json().get("chunk", [])
            health["gov_members"] = len(members)
    except Exception:
        pass
    community_rid = ROOM_IDS.get("community")
    if community_rid:
        try:
            r = http.get(
                f"{ACCESS}/_matrix/client/v3/rooms/{enc(community_rid)}/members",
                headers=SYS_HEADERS,
                params={"membership": "join"},
                timeout=10,
            )
            if r.status_code == 200:
                members = [
                    m
                    for m in r.json().get("chunk", [])
                    if not m.get("state_key", "").startswith("@rednet-")
                ]
                health["community_members"] = len(members)
        except Exception:
            pass
    return health


def cmd_status(room_id, sender, args):
    records = read_vouch_jsonl()
    vouches = sum(1 for r in records if r.get("type") == "vouch")
    claimed = sum(1 for r in records if r.get("type") == "claimed")
    revoked = sum(1 for r in records if r.get("type") == "revoked")
    roles = sum(1 for r in records if r.get("type") == "role")
    alerts = sum(1 for r in records if r.get("type") == "alert")

    health = _server_health()

    lines = [
        "**Gov Bot Status**",
        f"Synapse: **{health['synapse']}** (spec {health['version']})",
        f"Domain: `{DOMAIN}`",
    ]
    if "community_members" in health:
        lines.append(f"Community members: {health['community_members']}")
    lines += [
        f"Vouch index: {vouches} minted, {claimed} confirmed, {revoked} revoked, {roles} role changes",
    ]
    if alerts:
        lines.append(f"Alerts filed: {alerts}")
    lines += [
        f"Report DMs active: {len(REPORT_DMS)}",
        f"Rooms resolved: {len(ROOM_IDS)}",
        f"Bot user: `{BOT_USER}`",
    ]
    reply(room_id, "\n".join(lines))


def cmd_audit(room_id, sender, args):
    records = read_vouch_jsonl()
    vouches = [r for r in records if r.get("type") == "vouch"]
    claims = [r for r in records if r.get("type") == "claimed"]
    alerts = []

    now = datetime.now(timezone.utc)
    day_ago = now - timedelta(days=1)
    stale_cutoff = now - timedelta(days=STALE_DAYS)

    by_voucher_day = {}
    for v in vouches:
        ts = v.get("timestamp", "")
        try:
            vtime = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except (ValueError, AttributeError):
            continue
        if vtime >= day_ago:
            key = v.get("voucher", "?")
            by_voucher_day[key] = by_voucher_day.get(key, 0) + 1

    for voucher, count in by_voucher_day.items():
        if count > BURST_THRESHOLD:
            alerts.append(
                f"**BURST** `{voucher}` minted {count} invites in 24h (threshold: {BURST_THRESHOLD})"
            )

    claimed_hashes = {c.get("token_hash") for c in claims if c.get("token_hash")}
    unclaimed = [v for v in vouches if v.get("token_hash") not in claimed_hashes]
    if len(vouches) > 2:
        rate = len(unclaimed) / len(vouches) * 100
        if rate > UNCLAIMED_RATE_THRESHOLD:
            alerts.append(
                f"**UNCLAIMED** {len(unclaimed)}/{len(vouches)} ({rate:.0f}%) invites unclaimed"
            )

    stale = []
    for v in unclaimed:
        ts = v.get("timestamp", "")
        try:
            vtime = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except (ValueError, AttributeError):
            continue
        if vtime < stale_cutoff:
            stale.append(v)

    if stale:
        labels = ", ".join(v.get("label", "?") for v in stale[:5])
        alerts.append(
            f"**STALE** {len(stale)} invite(s) unclaimed for >{STALE_DAYS} days: {labels}"
        )

    # Room canaries — the detection layer behind the creation lockdown
    # (COMMUNITY-MANAGEMENT.md): unencrypted rooms, oversized "DMs".
    alerts.extend(community.room_canaries())

    if not alerts:
        reply(
            room_id,
            f"**Audit: clean.** {len(vouches)} vouches, {len(claims)} confirmed, "
            f"{len(unclaimed)} unclaimed ({len(unclaimed) / max(len(vouches), 1) * 100:.0f}%).",
        )
    else:
        lines = ["**Audit: anomalies detected**", ""] + alerts
        reply(room_id, "\n".join(lines))


def cmd_report(room_id, sender, args):
    positional, flags = parse_flags(args, "detail", "severity")
    if not positional or not positional[0].startswith("@"):
        reply(room_id, 'Usage: `!gov report @user --detail "reason"`')
        return

    target = positional[0]
    detail = flags.get("detail", "")
    severity = flags.get("severity", "suspected")

    if not detail:
        reply(room_id, "Error: `--detail` is required (describe the evidence).")
        return

    ts = now_iso()

    alert_body = {
        "msgtype": "org.rednet.alert.compromised",
        "body": f"ALERT: {target} reported as {severity} compromised by {sender}: {detail}",
        "org.rednet.alert.compromised": {
            "account": target,
            "reported_by": sender,
            "severity": severity,
            "detail": detail,
            "timestamp": ts,
        },
    }
    send_message(room_id, alert_body["body"], extra=alert_body, headers=BOT_HEADERS)

    append_vouch_jsonl(
        {
            "type": "alert",
            "account": target,
            "reported_by": sender,
            "severity": severity,
            "detail": detail,
            "timestamp": ts,
        }
    )

    reply(
        room_id,
        f"Compromised account report filed for `{target}` (severity: {severity}). "
        f"All organizers and admins have been notified.\n\n"
        f'**Next steps:** An admin should `!gov revoke {target} --reason "{detail}"` '
        f"if confirmed.",
    )


def cmd_confirm(room_id, sender, args):
    positional, flags = parse_flags(args, "label", "voucher")
    if not positional or not positional[0].startswith("@"):
        reply(
            room_id,
            'Usage: `!gov confirm @user [--label "description"] [--voucher @org]`',
        )
        return

    target = positional[0]
    label = flags.get("label", "")
    voucher = flags.get("voucher", sender)

    ts = now_iso()

    claim_event = {
        "msgtype": "org.rednet.vouch.claimed",
        "body": f"{target} confirmed, vouched by {voucher}",
        "org.rednet.vouch.claimed": {
            "account": target,
            "voucher": voucher,
            "label": label or None,
            "confirmed_at": ts,
        },
    }

    append_vouch_jsonl(
        {
            "type": "claimed",
            "account": target,
            "voucher": voucher,
            "label": label,
            "confirmed_at": ts,
        }
    )

    reply(
        room_id,
        f"Vouch confirmed: `{target}` vouched by `{voucher}`.\n\n"
        f"Note: announce in #welcome from Element (E2EE) if desired.",
    )


def cmd_role(room_id, sender, args):
    positional, flags = parse_flags(args, "rooms", "space")
    if len(positional) < 2 or not positional[0].startswith("@"):
        reply(
            room_id,
            "Usage: `!gov role @user moderator|organizer|member|admin "
            '[--rooms "#general,#welcome"] [--space "#ops-team"]`',
        )
        return

    target = positional[0]
    role = positional[1]

    if role not in ROLE_PL:
        reply(room_id, f"Unknown role `{role}`. Must be: {', '.join(ROLE_PL.keys())}")
        return

    sender_pl = get_power_level(room_id, sender)
    target_pl = ROLE_PL[role]

    if role in ("organizer", "admin") and sender_pl < PL_ADMIN:
        reply(room_id, f"Only admins (PL100) can assign the `{role}` role.")
        return

    rooms_arg = flags.get("rooms", "")
    space_arg = flags.get("space", "")
    target_rooms = []

    if rooms_arg:
        for alias in rooms_arg.replace("#", "").split(","):
            alias = alias.strip()
            rid = ROOM_IDS.get(alias) or resolve_alias(alias)
            if rid:
                target_rooms.append((alias, rid))
    elif space_arg:
        space_alias = space_arg.replace("#", "").strip()
        space_rid = ROOM_IDS.get(space_alias) or resolve_alias(space_alias)
        if space_rid:
            r = http.get(
                f"{ACCESS}/_matrix/client/v3/rooms/{enc(space_rid)}/state",
                headers=SYS_HEADERS,
                timeout=10,
            )
            for ev in r.json() if isinstance(r.json(), list) else []:
                if ev.get("type") == "m.space.child" and ev.get("content", {}).get(
                    "via"
                ):
                    target_rooms.append(("(child)", ev["state_key"]))
    else:
        for alias in COMMUNITY_ROOMS + GOVERNANCE_ROOMS:
            rid = ROOM_IDS.get(alias)
            if rid:
                target_rooms.append((alias, rid))

    ok = 0
    fail = 0
    for alias, rid in target_rooms:
        invite_user(rid, target)
        if set_power_level(rid, target, target_pl):
            ok += 1
        else:
            fail += 1

    ts = now_iso()
    scope = rooms_arg or space_arg or "all community + governance"

    append_vouch_jsonl(
        {
            "type": "role",
            "user": target,
            "role": role,
            "power_level": target_pl,
            "scope": scope,
            "assigned_by": sender,
            "timestamp": ts,
        }
    )

    reply(room_id, f"`{target}` set to **{role}** (PL{target_pl}) in {ok} room(s).")


def cmd_revoke(room_id, sender, args):
    positional, flags = parse_flags(args, "reason")
    if not positional or not positional[0].startswith("@"):
        reply(room_id, 'Usage: `!gov revoke @user --reason "why"`')
        return

    target = positional[0]
    reason = flags.get("reason", "")
    if not reason:
        reply(room_id, "Error: `--reason` is required (document why).")
        return

    username = target.split(":")[0].lstrip("@")

    kicked = 0
    all_rooms = list(ROOM_IDS.values())
    for rid in all_rooms:
        if kick_user(rid, target, reason):
            kicked += 1

    # Lock via MAS — the bot can't call mas-cli directly, so we set PL to -1
    # in all rooms (prevents messaging even if the session persists) and
    # log the event. Full MAS account lock requires CLI access.
    for rid in all_rooms:
        set_power_level(rid, target, -1)

    ts = now_iso()
    revoke_event = {
        "msgtype": "org.rednet.member.revoked",
        "body": f"{target} revoked: {reason}",
        "org.rednet.member.revoked": {
            "account": target,
            "reason": reason,
            "revoked_by": sender,
            "timestamp": ts,
        },
    }

    send_message(room_id, revoke_event["body"], extra=revoke_event, headers=BOT_HEADERS)

    append_vouch_jsonl(
        {
            "type": "revoked",
            "account": target,
            "reason": reason,
            "triggered_by": sender,
            "timestamp": ts,
        }
    )

    reply(
        room_id,
        f"**Revoked** `{target}`: kicked from {kicked} room(s), PL set to -1.\n"
        f"Reason: {reason}\n\n"
        f"**Note:** Full MAS account lock requires CLI: "
        f"`docker compose exec -T mas mas-cli manage lock-user {username}`",
    )


def cmd_revoke_chain(room_id, sender, args):
    positional, flags = parse_flags(args, "reason", "after")
    if not positional or not positional[0].startswith("@"):
        reply(
            room_id,
            'Usage: `!gov revoke-chain @voucher --reason "why" [--after 2026-01-01]`',
        )
        return

    voucher = positional[0]
    reason = flags.get("reason", "")
    after = flags.get("after", "")

    if not reason:
        reply(room_id, "Error: `--reason` is required.")
        return

    records = read_vouch_jsonl()
    targets = []
    for r in records:
        if r.get("type") == "claimed" and r.get("voucher") == voucher:
            if after:
                confirmed_at = r.get("confirmed_at", "")
                if confirmed_at < f"{after}T00:00:00Z":
                    continue
            targets.append(r.get("account"))

    if not targets:
        reply(
            room_id,
            f"No confirmed members found vouched by `{voucher}`{' after ' + after if after else ''}.",
        )
        return

    target_list = ", ".join(f"`{t}`" for t in targets)
    reply(
        room_id,
        f"Found **{len(targets)}** member(s) vouched by `{voucher}`"
        f"{' after ' + after if after else ''}: {target_list}\n\n"
        f"To proceed, revoke each individually:\n"
        + "\n".join(f'`!gov revoke {t} --reason "{reason}"`' for t in targets),
    )


COMMANDS = {
    "status": (PL_MEMBER, cmd_status),
    "audit": (PL_MODERATOR, cmd_audit),
    "report": (PL_MEMBER, cmd_report),
    "confirm": (PL_ORGANIZER, cmd_confirm),
    "role": (PL_ORGANIZER, cmd_role),
    "revoke": (PL_ADMIN, cmd_revoke),
    "revoke-chain": (PL_ADMIN, cmd_revoke_chain),
}

# Community management (rooms/spaces/requests — COMMUNITY-MANAGEMENT.md).
# Imported here, not at the top: community.py reads the PL_* constants at
# import time, so bot's module globals must exist first.
import community  # noqa: E402

COMMANDS.update(community.COMMANDS)


def handle_command(room_id, sender, body):
    if sender == BOT_USER:
        return

    parts = parse_args(body)
    if len(parts) < 2 or parts[0] != "!gov":
        return

    cmd_name = parts[1]
    cmd_args = parts[2:]

    if cmd_name == "help":
        sender_pl = get_power_level(room_id, sender)
        descs = {
            "status": "Network summary (members, vouches, alerts)",
            "audit": "Run coercion canary checks",
            "report": "Flag an account as compromised",
            "confirm": "Confirm a pending vouch",
            "role": "Assign moderation role (moderator/organizer)",
            "revoke": "Revoke a member (PL -1, kick from all rooms)",
            "revoke-chain": "List members introduced by a voucher for bulk revoke",
        }
        descs.update(community.DESCRIPTIONS)
        lines = ["**Gov Bot Commands**", ""]
        for name, (min_pl, _) in sorted(COMMANDS.items()):
            avail = "✓" if sender_pl >= min_pl else "✗"
            desc = descs.get(name, "")
            lines.append(f"  {avail} `!gov {name}` — {desc} (PL{min_pl}+)")
        lines.append("")
        lines.append(
            f"Your PL: **{sender_pl}**. Use `!gov <command>` with no args for usage."
        )
        reply(room_id, "\n".join(lines))
        return

    if cmd_name not in COMMANDS:
        reply(room_id, f"Unknown command `{cmd_name}`. Try `!gov help`.")
        return

    min_pl, handler = COMMANDS[cmd_name]
    sender_pl = get_power_level(room_id, sender)

    if sender_pl < min_pl:
        reply(
            room_id,
            f"Insufficient permissions: `{cmd_name}` requires PL{min_pl}+, "
            f"you are PL{sender_pl}.",
        )
        return

    try:
        handler(room_id, sender, cmd_args)
    except Exception as e:
        reply(room_id, f"Error executing `{cmd_name}`: {e}")
        print(f"[ERROR] {cmd_name} from {sender}: {e}", file=sys.stderr)


def resolve_rooms():
    global GOV_BOT_ROOM_ID

    for alias in COMMUNITY_ROOMS + GOVERNANCE_ROOMS + ["gov-bot", "organizing"]:
        rid = resolve_alias(alias)
        if rid:
            ROOM_IDS[alias] = rid

    GOV_BOT_ROOM_ID = ROOM_IDS.get("gov-bot")


def sync_loop():
    since = None

    initial = http.get(
        f"{ACCESS}/_matrix/client/v3/sync",
        headers=BOT_HEADERS,
        params={"timeout": "0", "filter": '{"room":{"timeline":{"limit":0}}}'},
        timeout=30,
    )
    if initial.status_code == 200:
        since = initial.json().get("next_batch")
    else:
        print(f"[WARN] Initial sync failed: {initial.status_code}", file=sys.stderr)

    print(f"[INFO] Sync loop started, since={since}", file=sys.stderr)

    while True:
        try:
            params = {"timeout": "30000"}
            if since:
                params["since"] = since
            params["filter"] = json.dumps(
                {
                    "room": {
                        "timeline": {"limit": 50},
                        "state": {"lazy_load_members": True},
                    }
                }
            )

            r = http.get(
                f"{ACCESS}/_matrix/client/v3/sync",
                headers=BOT_HEADERS,
                params=params,
                timeout=60,
            )

            if r.status_code != 200:
                print(f"[WARN] Sync error {r.status_code}", file=sys.stderr)
                time.sleep(5)
                continue

            data = r.json()
            since = data.get("next_batch", since)

            for rid in data.get("rooms", {}).get("invite", {}):
                try:
                    http.post(
                        f"{ACCESS}/_matrix/client/v3/join/{enc(rid)}",
                        headers=BOT_HEADERS,
                        json={},
                        timeout=10,
                    )
                    print(f"[INFO] Auto-joined room {rid}", file=sys.stderr)
                except Exception as e:
                    print(f"[WARN] Failed to auto-join {rid}: {e}", file=sys.stderr)

            rooms = data.get("rooms", {}).get("join", {})
            for rid, room_data in rooms.items():
                for event in room_data.get("timeline", {}).get("events", []):
                    if event.get("type") != "m.room.message":
                        continue
                    content = event.get("content", {})
                    body = content.get("body", "")
                    sender = event.get("sender", "")
                    if rid == GOV_BOT_ROOM_ID and body.startswith("!gov"):
                        handle_command(rid, sender, body)
                    elif body.startswith("!report"):
                        handle_report(rid, sender, body)
                    elif (
                        body.startswith("!gov")
                        and sender != BOT_USER
                        and rid in REPORT_DMS.values()
                    ):
                        # Members aren't in #gov-bot — their DM is where they
                        # can !gov request a room/space (COMMUNITY-MANAGEMENT.md).
                        community.handle_dm_gov(rid, sender, body)

            if time.time() - LAST_DM_SCAN > DM_SCAN_INTERVAL:
                ensure_report_dms()

        except http.exceptions.ConnectionError:
            print("[WARN] Connection lost, retrying in 5s...", file=sys.stderr)
            time.sleep(5)
        except Exception as e:
            print(f"[ERROR] Sync loop: {e}", file=sys.stderr)
            time.sleep(5)


def main():
    print(f"[INFO] REDnet Gov Bot starting", file=sys.stderr)
    print(f"[INFO] Domain: {DOMAIN}", file=sys.stderr)
    print(f"[INFO] Access URL: {ACCESS}", file=sys.stderr)
    print(f"[INFO] Bot user: {BOT_USER}", file=sys.stderr)

    print("[INFO] Resolving room aliases...", file=sys.stderr)
    for attempt in range(12):
        resolve_rooms()
        if GOV_BOT_ROOM_ID:
            break
        print(
            f"[INFO] Waiting for rooms (attempt {attempt + 1}/12)...", file=sys.stderr
        )
        time.sleep(5)

    if not GOV_BOT_ROOM_ID:
        print(
            "[FATAL] Could not resolve #gov-bot room. Run bootstrap-gov-bot.sh first.",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"[INFO] #gov-bot: {GOV_BOT_ROOM_ID}", file=sys.stderr)
    print(f"[INFO] Rooms resolved: {len(ROOM_IDS)}", file=sys.stderr)

    http.post(
        f"{ACCESS}/_matrix/client/v3/join/{enc(GOV_BOT_ROOM_ID)}",
        headers=BOT_HEADERS,
        json={},
        timeout=10,
    )

    print("[INFO] Setting up report DM rooms...", file=sys.stderr)
    discover_report_dms()
    ensure_report_dms()

    # In-client invite minting endpoint (COMMUNITY-MANAGEMENT.md). Best-effort:
    # if mint-svc isn't configured, governance still works — only minting is off.
    try:
        import mint_endpoint

        mint_endpoint.start()
    except Exception as e:
        print(f"[WARN] mint endpoint not started: {e}", file=sys.stderr)

    send_notice(GOV_BOT_ROOM_ID, "Gov Bot online. Type `!gov help` for commands.")

    sync_loop()


if __name__ == "__main__":
    if "--check-imports" in sys.argv:
        # Exercised by test_community.py: proves the script-execution path
        # (module named __main__) survives the bot<->community import cycle.
        print("imports ok")
        sys.exit(0)
    main()
