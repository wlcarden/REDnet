"""Community management commands — rooms, spaces, requests (COMMUNITY-MANAGEMENT.md).

Registered into bot.py's COMMANDS dict. Room creation is server-locked to the
system accounts (rednet_room_policy module), so these commands are the ONLY way
shared rooms come into existence: always E2EE, always recorded to vouch.jsonl,
linked into the space hierarchy unless --unlisted.

Organizer commands (in #gov-bot):
  !gov space "Name" [--space parent] [--topic "..."] [--unlisted]      PL 75
  !gov room "Name" [--visibility open|knock|private] [--space slug]
                   [--topic "..."] [--unlisted]                        PL 75
  !gov invite @user room                                               PL 75
  !gov rooms                                                           PL 75
  !gov members room                                                    PL 75
  !gov requests                                                        PL 75
  !gov approve REQ-id [--visibility ...] [--space slug]                PL 75
  !gov deny REQ-id reason...                                           PL 75
  !gov archive room                                                    PL 75
  !gov delete room --confirm                                           PL 100

Member command (in their bot DM, routed by handle_dm_gov):
  !gov request room|space "Name" --why "purpose"                       PL 0

Visibility tiers (all rooms E2EE — no flag to disable):
  open    join_rule=restricted scoped to the parent space
  knock   join_rule=knock — visible, "Ask to join" (DEFAULT: fails closed)
  private join_rule=invite; --unlisted also omits the m.space.child link so
          the room's NAME never appears in the hierarchy
"""

import re
import secrets
import sys

import requests as http

import admin_client
import bot

VISIBILITIES = ("open", "knock", "private")
DEFAULT_VISIBILITY = "knock"

MEGOLM = {"algorithm": "m.megolm.v1.aes-sha2"}


# --- helpers -----------------------------------------------------------------


def _slug(name):
    s = name.lower().replace(" ", "-")
    return re.sub(r"[^a-z0-9-]", "", s).strip("-")


def _log(msg):
    print(f"[INFO] community: {msg}", file=sys.stderr)


def get_state(room_id, ev_type, state_key=""):
    r = http.get(
        f"{bot.ACCESS}/_matrix/client/v3/rooms/{bot.enc(room_id)}/state/{ev_type}/{bot.enc(state_key) if state_key else ''}",
        headers=bot.SYS_HEADERS,
        timeout=10,
    )
    return r.json() if r.status_code == 200 else {}


def put_state(room_id, ev_type, state_key, content):
    r = http.put(
        f"{bot.ACCESS}/_matrix/client/v3/rooms/{bot.enc(room_id)}/state/{ev_type}/{bot.enc(state_key) if state_key else ''}",
        headers=bot.SYS_HEADERS,
        json=content,
        timeout=10,
    )
    return "event_id" in r.json()


def link_child(parent_id, child_id, suggested=True):
    ok1 = put_state(
        parent_id,
        "m.space.child",
        child_id,
        {"via": [bot.DOMAIN], "suggested": suggested},
    )
    ok2 = put_state(
        child_id,
        "m.space.parent",
        parent_id,
        {"via": [bot.DOMAIN], "canonical": True},
    )
    return ok1 and ok2


def unlink_child(parent_id, child_id):
    # Removing a space child = writing empty content to the state key.
    put_state(parent_id, "m.space.child", child_id, {})
    put_state(child_id, "m.space.parent", parent_id, {})


def resolve_room_ref(ref):
    """Accept '#alias', 'alias', or '!roomid' and return a room_id (or '')."""
    if ref.startswith("!"):
        return ref
    return bot.resolve_alias(ref.lstrip("#").split(":")[0])


def resolve_parent_space(slug_or_none):
    """Resolve --space flag to a space room_id. Default: the community space."""
    if not slug_or_none:
        return bot.ROOM_IDS.get("community", ""), "community"
    rid = resolve_room_ref(slug_or_none)
    return rid, slug_or_none


def join_rules_for(visibility, parent_space_id):
    if visibility == "open":
        return {
            "join_rule": "restricted",
            "allow": [{"type": "m.room_membership", "room_id": parent_space_id}],
        }
    if visibility == "knock":
        return {"join_rule": "knock"}
    return {"join_rule": "invite"}


def create_managed_room(name, visibility, parent_space_id, topic="", alias=None):
    """Create an E2EE room via the system account. Returns (room_id, error)."""
    initial_state = [
        {"type": "m.room.encryption", "state_key": "", "content": MEGOLM},
        {
            "type": "m.room.join_rules",
            "state_key": "",
            "content": join_rules_for(visibility, parent_space_id),
        },
    ]
    body = {
        "name": name,
        "topic": topic,
        "preset": "private_chat",
        "visibility": "private",
        "initial_state": initial_state,
    }
    if alias:
        body["room_alias_name"] = alias
    r = http.post(
        f"{bot.ACCESS}/_matrix/client/v3/createRoom",
        headers=bot.SYS_HEADERS,
        json=body,
        timeout=15,
    )
    data = r.json()
    if "room_id" not in data:
        return "", data.get("error", data.get("errcode", "unknown error"))
    return data["room_id"], ""


def create_managed_space(name, topic="", alias=None):
    body = {
        "name": name,
        "topic": topic,
        "preset": "private_chat",
        "visibility": "private",
        "creation_content": {"type": "m.space"},
        "power_level_content_override": {"events_default": 50, "invite": 50},
    }
    if alias:
        body["room_alias_name"] = alias
    r = http.post(
        f"{bot.ACCESS}/_matrix/client/v3/createRoom",
        headers=bot.SYS_HEADERS,
        json=body,
        timeout=15,
    )
    data = r.json()
    if "room_id" not in data:
        return "", data.get("error", data.get("errcode", "unknown error"))
    return data["room_id"], ""


def new_request_id(existing_records):
    used = {r.get("id") for r in existing_records if r.get("type") == "room-request"}
    for _ in range(50):
        rid = f"REQ-{secrets.token_hex(3)}"
        if rid not in used:
            return rid
    return f"REQ-{secrets.token_hex(6)}"


def pending_requests(records):
    decided = {r.get("id") for r in records if r.get("type") == "room-request-decision"}
    return [
        r
        for r in records
        if r.get("type") == "room-request" and r.get("id") not in decided
    ]


def dm_user(user_id, text):
    """Send a notice to a member via their bot DM (created if missing)."""
    rid = bot.REPORT_DMS.get(user_id) or bot.create_report_dm(user_id)
    if rid:
        bot.send_notice(rid, text)
        return True
    return False


# --- organizer commands ------------------------------------------------------


def cmd_space(room_id, sender, args):
    positional, flags = bot.parse_flags(args, "space", "topic")
    unlisted = "--unlisted" in positional
    positional = [p for p in positional if p != "--unlisted"]
    if not positional:
        bot.reply(
            room_id,
            'Usage: `!gov space "Name" [--space parent] [--topic "..."] [--unlisted]`',
        )
        return
    name = positional[0]
    alias = _slug(name)
    if not alias:
        bot.reply(room_id, "Space name must contain letters or numbers.")
        return
    if bot.resolve_alias(alias):
        bot.reply(room_id, f"`#{alias}` already exists.")
        return

    parent_id, parent_ref = resolve_parent_space(flags.get("space"))
    space_id, err = create_managed_space(name, flags.get("topic", ""), alias)
    if not space_id:
        bot.reply(room_id, f"Space creation failed: {err}")
        return

    linked = False
    if not unlisted and parent_id:
        linked = link_child(parent_id, space_id, suggested=False)

    ts = bot.now_iso()
    bot.append_vouch_jsonl(
        {
            "type": "space",
            "room_id": space_id,
            "alias": alias,
            "name": name,
            "parent": parent_ref if linked else None,
            "unlisted": unlisted,
            "created_by": sender,
            "timestamp": ts,
        }
    )
    where = f"linked under `{parent_ref}`" if linked else "**unlisted**"
    bot.reply(room_id, f"Space **{name}** created (`#{alias}`), {where}.")


def cmd_room(room_id, sender, args, requested_by=None, request_id=None):
    positional, flags = bot.parse_flags(args, "visibility", "space", "topic")
    unlisted = "--unlisted" in positional
    positional = [p for p in positional if p != "--unlisted"]
    if not positional:
        bot.reply(
            room_id,
            'Usage: `!gov room "Name" [--visibility open|knock|private] '
            '[--space slug] [--topic "..."] [--unlisted]`',
        )
        return
    name = positional[0]
    visibility = flags.get("visibility", DEFAULT_VISIBILITY)
    if visibility not in VISIBILITIES:
        bot.reply(
            room_id,
            f"Unknown visibility `{visibility}` — one of: {', '.join(VISIBILITIES)}",
        )
        return
    if unlisted and visibility != "private":
        bot.reply(room_id, "`--unlisted` only makes sense with `--visibility private`.")
        return

    parent_id, parent_ref = resolve_parent_space(flags.get("space"))
    if not parent_id:
        bot.reply(room_id, f"Parent space `{flags.get('space')}` not found.")
        return

    alias = (
        _slug(name) if not flags.get("space") else f"{_slug(parent_ref)}-{_slug(name)}"
    )
    if bot.resolve_alias(alias):
        bot.reply(room_id, f"`#{alias}` already exists.")
        return

    new_rid, err = create_managed_room(
        name, visibility, parent_id, flags.get("topic", ""), alias
    )
    if not new_rid:
        bot.reply(room_id, f"Room creation failed: {err}")
        return

    linked = False
    if not unlisted:
        linked = link_child(parent_id, new_rid, suggested=(visibility == "open"))

    if requested_by:
        bot.invite_user(new_rid, requested_by)
        bot.set_power_level(new_rid, requested_by, bot.PL_MODERATOR)

    ts = bot.now_iso()
    bot.append_vouch_jsonl(
        {
            "type": "room",
            "room_id": new_rid,
            "alias": alias,
            "name": name,
            "visibility": visibility,
            "space": parent_ref,
            "unlisted": unlisted,
            "created_by": sender,
            "requested_by": requested_by,
            "request_id": request_id,
            "timestamp": ts,
        }
    )
    lines = [
        f"Room **{name}** created (`#{alias}`) — E2EE, visibility **{visibility}**, "
        + (f"linked under `{parent_ref}`" if linked else "**unlisted**")
        + "."
    ]
    if requested_by:
        lines.append(f"`{requested_by}` invited as moderator (PL50).")
    bot.reply(room_id, "\n".join(lines))
    return new_rid


def cmd_invite(room_id, sender, args):
    if len(args) < 2 or not args[0].startswith("@"):
        bot.reply(room_id, "Usage: `!gov invite @user room-alias`")
        return
    target_user = args[0]
    if ":" not in target_user:
        target_user = f"{target_user}:{bot.DOMAIN}"
    target_rid = resolve_room_ref(args[1])
    if not target_rid:
        bot.reply(room_id, f"Room `{args[1]}` not found.")
        return
    if bot.invite_user(target_rid, target_user):
        bot.append_vouch_jsonl(
            {
                "type": "room-invite",
                "room_id": target_rid,
                "account": target_user,
                "by": sender,
                "timestamp": bot.now_iso(),
            }
        )
        bot.reply(room_id, f"Invited `{target_user}` to `{args[1]}`.")
    else:
        bot.reply(room_id, f"Invite failed for `{target_user}` → `{args[1]}`.")


def _room_records():
    """Latest managed-room state from the audit log (creation minus archive/delete)."""
    records = bot.read_vouch_jsonl()
    rooms = {}
    for r in records:
        t = r.get("type")
        if t in ("room", "space"):
            rooms[r["room_id"]] = r
        elif t in ("room-archived", "room-deleted"):
            if r.get("room_id") in rooms:
                rooms[r["room_id"]] = {**rooms[r["room_id"]], "state": t}
    return rooms


def cmd_rooms(room_id, sender, args):
    rooms = _room_records()
    if not rooms:
        bot.reply(room_id, 'No managed rooms yet. Create one: `!gov room "Name"`')
        return
    lines = ["**Managed rooms** (from the audit log)", ""]
    for rid, rec in sorted(rooms.items(), key=lambda kv: kv[1].get("timestamp", "")):
        kind = "space" if rec.get("type") == "space" else "room"
        state = rec.get("state", "")
        flags = []
        if rec.get("unlisted"):
            flags.append("unlisted")
        if state == "room-archived":
            flags.append("ARCHIVED")
        if state == "room-deleted":
            flags.append("DELETED")
        vis = rec.get("visibility", "—")
        members = ""
        if state != "room-deleted":
            r = http.get(
                f"{bot.ACCESS}/_matrix/client/v3/rooms/{bot.enc(rid)}/joined_members",
                headers=bot.SYS_HEADERS,
                timeout=10,
            )
            if r.status_code == 200:
                members = f", {len(r.json().get('joined', {}))} members"
        suffix = f" [{' '.join(flags)}]" if flags else ""
        lines.append(f"  `#{rec.get('alias', '?')}` — {kind}, {vis}{members}{suffix}")
    bot.reply(room_id, "\n".join(lines))


def cmd_members(room_id, sender, args):
    if not args:
        bot.reply(room_id, "Usage: `!gov members room-alias`")
        return
    target_rid = resolve_room_ref(args[0])
    if not target_rid:
        bot.reply(room_id, f"Room `{args[0]}` not found.")
        return
    r = http.get(
        f"{bot.ACCESS}/_matrix/client/v3/rooms/{bot.enc(target_rid)}/joined_members",
        headers=bot.SYS_HEADERS,
        timeout=10,
    )
    joined = r.json().get("joined", {}) if r.status_code == 200 else {}
    if not joined:
        bot.reply(room_id, f"No members found for `{args[0]}` (or room unreadable).")
        return
    names = sorted(joined.keys())
    lines = [f"**{args[0]}** — {len(names)} member(s)", ""]
    lines += [f"  `{n}`" for n in names]
    bot.reply(room_id, "\n".join(lines))


def cmd_archive(room_id, sender, args):
    if not args:
        bot.reply(room_id, "Usage: `!gov archive room-alias`")
        return
    target_rid = resolve_room_ref(args[0])
    if not target_rid:
        bot.reply(room_id, f"Room `{args[0]}` not found.")
        return

    # Lock: nobody below PL100 can post; no new joins; unlink from its parent.
    pl = get_state(target_rid, "m.room.power_levels")
    pl["events_default"] = 100
    pl["invite"] = 100
    put_state(target_rid, "m.room.power_levels", "", pl)
    put_state(target_rid, "m.room.join_rules", "", {"join_rule": "invite"})

    parent = get_state_parent(target_rid)
    if parent:
        unlink_child(parent, target_rid)

    bot.append_vouch_jsonl(
        {
            "type": "room-archived",
            "room_id": target_rid,
            "by": sender,
            "timestamp": bot.now_iso(),
        }
    )
    bot.reply(
        room_id,
        f"`{args[0]}` archived: read-only, unlinked from the hierarchy, no new joins. "
        f"Members keep read access until retention purges history. "
        f"Hard-remove: `!gov delete {args[0]} --confirm` (PL100).",
    )


def get_state_parent(room_id):
    r = http.get(
        f"{bot.ACCESS}/_matrix/client/v3/rooms/{bot.enc(room_id)}/state",
        headers=bot.SYS_HEADERS,
        timeout=10,
    )
    if r.status_code != 200:
        return ""
    for ev in r.json():
        if ev.get("type") == "m.space.parent" and ev.get("content", {}).get("via"):
            return ev.get("state_key", "")
    return ""


def cmd_delete(room_id, sender, args):
    if not args:
        bot.reply(room_id, "Usage: `!gov delete room-alias --confirm`")
        return
    target_ref = args[0]
    if "--confirm" not in args:
        bot.reply(
            room_id,
            f"This **purges** `{target_ref}` from the server: all members kicked, "
            f"all content removed from the database, room blocked from re-join. "
            f"Client-side copies are not affected. "
            f"Re-run with `--confirm` to proceed.",
        )
        return
    target_rid = resolve_room_ref(target_ref)
    if not target_rid:
        bot.reply(room_id, f"Room `{target_ref}` not found.")
        return
    if target_rid in (bot.GOV_BOT_ROOM_ID, bot.ROOM_IDS.get("community")):
        bot.reply(room_id, "Refusing to delete a core system room.")
        return

    # Synapse-admin op — routed through synmin-svc (the gov-bot holds no admin).
    _st, data = admin_client.purge_room(target_rid)
    if "delete_id" not in data:
        bot.reply(
            room_id,
            f"Delete failed: {data.get('error', data.get('errcode', 'unknown'))} "
            f"(synmin-svc / Synapse admin issue)",
        )
        return
    bot.append_vouch_jsonl(
        {
            "type": "room-deleted",
            "room_id": target_rid,
            "by": sender,
            "delete_id": data["delete_id"],
            "timestamp": bot.now_iso(),
        }
    )
    bot.reply(
        room_id,
        f"`{target_ref}` purge started (id `{data['delete_id']}`). "
        f"Content is removed from the server; client-side copies remain until "
        f"their retention cleanup.",
    )


# --- request flow ------------------------------------------------------------


def cmd_request(room_id, sender, args):
    """Member-side, runs in their bot DM: !gov request room|space "Name" --why "..." """
    positional, flags = bot.parse_flags(args, "why", "visibility")
    if not positional or positional[0] not in ("room", "space"):
        bot.reply(
            room_id,
            'Usage: `!gov request room "Name" --why "what it\'s for"`\n'
            'Or: `!gov request space "Name" --why "..."`',
        )
        return
    kind = positional[0]
    if len(positional) < 2:
        bot.reply(
            room_id, f'Please include a name: `!gov request {kind} "Name" --why "..."`'
        )
        return
    name = positional[1]
    why = flags.get("why", "")
    if not why:
        bot.reply(
            room_id, 'Please include `--why "purpose"` so organizers have context.'
        )
        return

    records = bot.read_vouch_jsonl()
    req_id = new_request_id(records)
    bot.append_vouch_jsonl(
        {
            "type": "room-request",
            "id": req_id,
            "requester": sender,
            "kind": kind,
            "name": name,
            "why": why,
            "visibility": flags.get("visibility"),
            "timestamp": bot.now_iso(),
        }
    )
    if bot.GOV_BOT_ROOM_ID:
        bot.send_notice(
            bot.GOV_BOT_ROOM_ID,
            f"**{req_id}** — `{sender}` requests {kind} **{name}**\n"
            f"Why: {why}\n"
            f"`!gov approve {req_id}` · `!gov deny {req_id} reason...`",
        )
    bot.reply(
        room_id,
        f"Request **{req_id}** sent to the organizers — you'll hear back here "
        f"whichever way it goes.",
    )


def cmd_requests(room_id, sender, args):
    pending = pending_requests(bot.read_vouch_jsonl())
    if not pending:
        bot.reply(room_id, "No pending requests.")
        return
    lines = [f"**Pending requests** ({len(pending)})", ""]
    for r in pending:
        lines.append(
            f"  **{r['id']}** — {r.get('kind')} **{r.get('name')}** "
            f"by `{r.get('requester')}` — {r.get('why', '')}"
        )
    lines.append("")
    lines.append(
        "`!gov approve REQ-id [--visibility ...] [--space slug]` · `!gov deny REQ-id reason...`"
    )
    bot.reply(room_id, "\n".join(lines))


def _find_request(req_id):
    records = bot.read_vouch_jsonl()
    for r in pending_requests(records):
        if r.get("id") == req_id:
            return r
    return None


def cmd_approve(room_id, sender, args):
    positional, flags = bot.parse_flags(args, "visibility", "space", "topic")
    if not positional:
        bot.reply(
            room_id, "Usage: `!gov approve REQ-id [--visibility ...] [--space slug]`"
        )
        return
    req = _find_request(positional[0])
    if not req:
        bot.reply(
            room_id, f"No pending request `{positional[0]}` — see `!gov requests`."
        )
        return

    visibility = flags.get("visibility") or req.get("visibility") or DEFAULT_VISIBILITY
    create_args = [req["name"], "--visibility", visibility]
    if flags.get("space"):
        create_args += ["--space", flags["space"]]
    if flags.get("topic"):
        create_args += ["--topic", flags["topic"]]

    if req.get("kind") == "space":
        cmd_space(
            room_id,
            sender,
            [req["name"]] + (["--space", flags["space"]] if flags.get("space") else []),
        )
        new_rid = bot.resolve_alias(_slug(req["name"]))
        if not new_rid:
            return  # creation failed; cmd_space already reported why — request stays pending
        bot.invite_user(new_rid, req["requester"])
        bot.set_power_level(new_rid, req["requester"], bot.PL_MODERATOR)
    else:
        new_rid = cmd_room(
            room_id,
            sender,
            create_args,
            requested_by=req["requester"],
            request_id=req["id"],
        )
        if not new_rid:
            return  # creation failed; cmd_room already reported why — request stays pending

    bot.append_vouch_jsonl(
        {
            "type": "room-request-decision",
            "id": req["id"],
            "decision": "approved",
            "by": sender,
            "room_id": new_rid or None,
            "timestamp": bot.now_iso(),
        }
    )
    dm_user(
        req["requester"],
        f"Your request **{req['id']}** ({req['kind']} **{req['name']}**) was "
        f"**approved** — you've been invited, and you're its moderator: you approve "
        f"join requests, invite people, and pin what matters.",
    )


def cmd_deny(room_id, sender, args):
    if len(args) < 2:
        bot.reply(room_id, "Usage: `!gov deny REQ-id reason...`")
        return
    req = _find_request(args[0])
    if not req:
        bot.reply(room_id, f"No pending request `{args[0]}` — see `!gov requests`.")
        return
    reason = " ".join(args[1:])
    bot.append_vouch_jsonl(
        {
            "type": "room-request-decision",
            "id": req["id"],
            "decision": "denied",
            "by": sender,
            "reason": reason,
            "timestamp": bot.now_iso(),
        }
    )
    bot.reply(room_id, f"**{req['id']}** denied — requester notified.")
    dm_user(
        req["requester"],
        f"Your request **{req['id']}** ({req['kind']} **{req['name']}**) was "
        f"**declined**: {reason}",
    )


# --- audit canaries ----------------------------------------------------------

# Plaintext by design: bot command rooms (bots speak HTTP, not Olm) and #welcome
# (pre-E2EE landing room). Spaces are excluded by room_type, DMs by shape.
PLAINTEXT_ALLOWED_ALIASES = {"welcome", "gov-bot", "rednet-mod", "rednet-banlist"}
SYSTEM_CREATORS = ("@rednet-system:", "@rednet-gov:", "@rednet-mod:")


def _is_system_creator(creator):
    return any(creator.startswith(p) for p in SYSTEM_CREATORS)


def room_canaries():
    """Sweep every room on the server for lockdown violations.

    The detection layer behind rednet_room_policy: unencrypted shared rooms,
    and DM-shaped rooms that grew past 2 members (the module's accepted
    residual risk). Uses the admin list API — sees rooms the system account
    is not a member of. Returns alert strings for cmd_audit.
    """
    alerts = []
    # Synapse-admin op — routed through synmin-svc (the gov-bot holds no admin).
    try:
        st, data = admin_client.list_rooms(500)
    except Exception as e:
        return [f"**SWEEP SKIPPED** room sweep unreachable: {e}"]
    if st != 200:
        alerts.append(
            "**SWEEP SKIPPED** room sweep needs the admin API "
            f"(HTTP {st}) — synmin-svc / Synapse admin issue"
        )
        return alerts
    rooms = data.get("rooms", [])
    if data.get("total_rooms", 0) > len(rooms):
        alerts.append(
            f"**SWEEP PARTIAL** {len(rooms)}/{data['total_rooms']} rooms swept"
        )

    for room in rooms:
        alias = (room.get("canonical_alias") or "").lstrip("#").split(":")[0]
        members = room.get("joined_members", 0)
        is_space = room.get("room_type") == "m.space"
        is_dm_shaped = not room.get("canonical_alias") and members <= 2
        label = f"`#{alias}`" if alias else f"`{room.get('room_id')}`"

        if (
            not room.get("encryption")
            and not is_space
            and not is_dm_shaped
            and alias not in PLAINTEXT_ALLOWED_ALIASES
        ):
            alerts.append(f"**UNENCRYPTED** {label} — {members} members, no E2EE")

        # F28: the room-policy DM carve-out admits is_direct rooms without requiring
        # encryption, and this sweep otherwise exempts DM-shaped rooms above. But a
        # real Element DM IS E2EE, so an unencrypted 1:1 is an anomalous plaintext
        # side-channel — flag it rather than let it hide behind the carve-out.
        if (
            not room.get("encryption")
            and is_dm_shaped
            and not is_space
            and alias not in PLAINTEXT_ALLOWED_ALIASES
        ):
            alerts.append(
                f"**UNENCRYPTED DM** {label} — 1:1 room with no E2EE. A real Element "
                "DM is encrypted; this is a plaintext side-channel."
            )

        if (
            not room.get("canonical_alias")
            and not is_space
            and members > 2
            and not _is_system_creator(room.get("creator", ""))
        ):
            alerts.append(
                f"**UNMANAGED** {label} — {members} members, created by "
                f"`{room.get('creator', '?')}` outside the hierarchy"
            )
    return alerts


def handle_dm_gov(room_id, sender, body):
    """!gov commands arriving in a member's DM — only `request` is meaningful there."""
    parts = bot.parse_args(body)
    if len(parts) >= 2 and parts[1] == "request":
        cmd_request(room_id, sender, parts[2:])
    else:
        bot.reply(
            room_id,
            "In this DM you can request a room or space:\n"
            '`!gov request room "Name" --why "what it\'s for"`\n\n'
            'Reports: `!report @user --detail "..."`',
        )


COMMANDS = {
    "space": (bot.PL_ORGANIZER, cmd_space),
    "room": (bot.PL_ORGANIZER, cmd_room),
    "invite": (bot.PL_ORGANIZER, cmd_invite),
    "rooms": (bot.PL_ORGANIZER, cmd_rooms),
    "members": (bot.PL_ORGANIZER, cmd_members),
    "requests": (bot.PL_ORGANIZER, cmd_requests),
    "approve": (bot.PL_ORGANIZER, cmd_approve),
    "deny": (bot.PL_ORGANIZER, cmd_deny),
    "archive": (bot.PL_ORGANIZER, cmd_archive),
    "delete": (bot.PL_ADMIN, cmd_delete),
}

DESCRIPTIONS = {
    "space": "Create a sub-space in the hierarchy",
    "room": "Create an E2EE room (open/knock/private)",
    "invite": "Invite a member to a managed room",
    "rooms": "List managed rooms incl. unlisted",
    "members": "List members of a room",
    "requests": "List pending room/space requests",
    "approve": "Approve a request (requester becomes moderator)",
    "deny": "Deny a request with a reason",
    "archive": "Lock a room read-only + unlink it",
    "delete": "Purge a room from the server",
}
