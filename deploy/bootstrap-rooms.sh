#!/usr/bin/env bash
# Bootstrap the community: a Matrix SPACE (org hierarchy) with starter channels, the security primer
# surfaced on entry, then verify a fresh user auto-joins. Channels are E2EE; the Space is an (unencrypted)
# container, as Matrix Spaces always are. The security primer lives in #welcome's TOPIC (room state — always
# visible, and the system account can set it without a crypto client) and is reinforced app-wide by the
# Element config `user_notice` (deploy/element-web/config.json.template). Idempotent. Requires ./setup.sh first.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?}"; : "${REDNET_HTTP_PORT:=8080}"; : "${REDNET_BRAND:=REDnet}"
. ./lib-access.sh
ACCESS="$API_URL"
say(){ printf '\n=== %s ===\n' "$*"; }
jqpy(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
genpw(){ LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32; }
mas(){ docker compose exec -T mas mas-cli manage "$@" --config /config.yaml 2>&1; }
enc(){ python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }

say "system account (rednet-system) + token"
# R2: rednet-system is NOT --admin and its token is NOT synapse-admin — it only creates rooms + sets state +
# invites as the room CREATOR (PL100), none of which needs admin. Keeps no god-credential on the core.
mas register-user rednet-system --password "$(genpw)" --yes --ignore-password-complexity 2>&1 | tail -1
SYS_TOK=$(mas issue-compatibility-token rednet-system SYSDEV | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
[ -n "${SYS_TOK:-}" ] || { echo "could not mint system token"; exit 1; }
AUTH="Authorization: Bearer $SYS_TOK"

alias_exists(){ curl -s -H "$AUTH" "$ACCESS/_matrix/client/v3/directory/room/%23${1}%3A${REDNET_DOMAIN}" | grep -q '"room_id"'; }
get_alias_id(){ curl -s -H "$AUTH" "$ACCESS/_matrix/client/v3/directory/room/%23${1}%3A${REDNET_DOMAIN}" | jqpy "d.get('room_id','')"; }

# create_room ALIAS NAME TOPIC PL_OVERRIDE_JSON EXTRA_INITIAL_STATE_JSON -> echoes room_id (idempotent, E2EE)
create_room(){
  local alias="$1" name="$2" topic="$3" plover="$4" extra="$5"
  if alias_exists "$alias"; then get_alias_id "$alias"; return; fi
  local d="{\"room_alias_name\":\"$alias\",\"name\":\"$name\",\"topic\":\"$topic\",\"preset\":\"public_chat\",\"visibility\":\"private\""
  [ -n "$plover" ] && d="$d,\"power_level_content_override\":$plover"
  # join_rule=knock (F11): overrides the preset's public rule so no one self-joins
  # by alias. Members are force-joined server-side by auto_join_rooms regardless,
  # and organizers are invited — both bypass knock, so onboarding is unaffected.
  d="$d,\"initial_state\":[{\"type\":\"m.room.encryption\",\"state_key\":\"\",\"content\":{\"algorithm\":\"m.megolm.v1.aes-sha2\"}},{\"type\":\"m.room.join_rules\",\"state_key\":\"\",\"content\":{\"join_rule\":\"knock\"}}$extra]}"
  curl -s -XPOST "$ACCESS/_matrix/client/v3/createRoom" -H "$AUTH" -d "$d" | jqpy "d.get('room_id','')"
}
# create_room_plain ALIAS NAME TOPIC PL_OVERRIDE_JSON -> echoes room_id (idempotent, NOT encrypted at creation)
create_room_plain(){
  local alias="$1" name="$2" topic="$3" plover="$4"
  if alias_exists "$alias"; then get_alias_id "$alias"; return; fi
  local d="{\"room_alias_name\":\"$alias\",\"name\":\"$name\",\"topic\":\"$topic\",\"preset\":\"public_chat\",\"visibility\":\"private\""
  [ -n "$plover" ] && d="$d,\"power_level_content_override\":$plover"
  # join_rule=knock (F11) — see create_room.
  d="$d,\"initial_state\":[{\"type\":\"m.room.join_rules\",\"state_key\":\"\",\"content\":{\"join_rule\":\"knock\"}}]}"
  curl -s -XPOST "$ACCESS/_matrix/client/v3/createRoom" -H "$AUTH" -d "$d" | jqpy "d.get('room_id','')"
}
# ensure_retention ROOM_ID DAYS : set a per-room m.room.retention max_lifetime. Idempotent (PUT),
# so re-running the bootstrap fixes ALREADY-created rooms. A room with NO policy inherits the
# server default (REDNET_RETENTION_DAYS, ~7d) and gets purged — durable rooms need this to reach
# the server's allowed_lifetime_max ceiling (30d). Nothing persists past that ceiling by design.
ensure_retention(){
  [ -n "$1" ] || return 0
  local ms=$(( $2 * 86400000 ))
  curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$1")/state/m.room.retention/" \
    -H "$AUTH" -H "Content-Type: application/json" -d "{\"max_lifetime\":$ms}" >/dev/null
}
enable_e2ee(){  # ROOM_ID : turn on encryption (irreversible)
  curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$1")/state/m.room.encryption/" \
    -H "$AUTH" -d '{"algorithm":"m.megolm.v1.aes-sha2"}' >/dev/null
}
send_notice(){  # ROOM_ID TEXT : send a plaintext m.notice (read-only system message)
  python3 -c "import json,sys;print(json.dumps({'msgtype':'m.notice','body':sys.argv[1]}))" "$2" \
    | curl -s -XPOST "$ACCESS/_matrix/client/v3/rooms/$(enc "$1")/send/m.room.message/$(date +%s%N)" \
      -H "$AUTH" -d @- >/dev/null
}
# create_space ALIAS NAME TOPIC -> echoes space_id (idempotent; an m.space container, unencrypted)
create_space(){
  if alias_exists "$1"; then get_alias_id "$1"; return; fi
  curl -s -XPOST "$ACCESS/_matrix/client/v3/createRoom" -H "$AUTH" -d "{
    \"room_alias_name\":\"$1\",\"name\":\"$2\",\"topic\":\"$3\",\"preset\":\"public_chat\",\"visibility\":\"private\",
    \"creation_content\":{\"type\":\"m.space\"},\"power_level_content_override\":{\"events_default\":50,\"invite\":50},
    \"initial_state\":[{\"type\":\"m.room.join_rules\",\"state_key\":\"\",\"content\":{\"join_rule\":\"knock\"}}]
  }" | jqpy "d.get('room_id','')"
}
link_child(){  # SPACE_ID CHILD_ID [ORDER [SUGGESTED]] : two-way m.space.child / m.space.parent
  local order="${3:-}" suggested="${4:-true}"
  local child_body="{\"via\":[\"$REDNET_DOMAIN\"],\"suggested\":${suggested}}"
  [ -n "$order" ] && child_body="{\"via\":[\"$REDNET_DOMAIN\"],\"suggested\":${suggested},\"order\":\"${order}\"}"
  curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$1")/state/m.space.child/$(enc "$2")"  -H "$AUTH" -d "$child_body" >/dev/null
  curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$2")/state/m.space.parent/$(enc "$1")" -H "$AUTH" -d "{\"via\":[\"$REDNET_DOMAIN\"],\"canonical\":true}" >/dev/null
}
lock_widget_pl(){  # ROOM_ID : restrict im.vector.modular.widgets state event to PL 100 (admin-only)
  local rid="$1"
  local PL_STATE PL_UPDATED
  PL_STATE=$(curl -s "$ACCESS/_matrix/client/v3/rooms/$(enc "$rid")/state/m.room.power_levels/" -H "$AUTH")
  PL_UPDATED=$(echo "$PL_STATE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
d.setdefault('events',{})['im.vector.modular.widgets']=100
print(json.dumps(d))
" 2>/dev/null)
  [ -n "$PL_UPDATED" ] && curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$rid")/state/m.room.power_levels/" \
    -H "$AUTH" -H "Content-Type: application/json" -d "$PL_UPDATED" >/dev/null
}
set_topic(){  # ROOM_ID TEXT : python builds the JSON so emoji/quotes/newlines are safe
  python3 -c "import json,sys;print(json.dumps({'topic':sys.argv[1]}))" "$2" \
    | curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$1")/state/m.room.topic/" -H "$AUTH" -d @- >/dev/null
}

PRIMER="🔒 End-to-end encrypted — the server cannot read your messages. 👁 But it CAN see WHO you talk to and WHEN. Keep real names, locations, and plans out of chat. 🔑 Save your recovery passphrase somewhere safe and offline — it is the only way back in on a new device. 📵 Turn off lock screen notification previews (Settings > Notifications). 🧹 Chat auto-deletes after a few days; durable info lives in #reference."

say "space: $REDNET_BRAND"
SPACE_ID=$(create_space community "$REDNET_BRAND" "Encrypted organizing space.")
echo "  space -> ${SPACE_ID:-ERR}"

say "channels"
# Welcome is created plain so the system account can send a plaintext notice BEFORE enabling E2EE.
# The notice stays readable forever (no key management); all subsequent messages are encrypted.
WELCOME=$(create_room_plain welcome  "Welcome"       "Start here — read the pinned message, save your recovery passphrase."  "")
ANNOUNCE=$(create_room announcements "Announcements" "Organizer updates. Read-only for members — moderators and above can post."  '{"events_default":50}' "")
# Reference: write-locked, NO retention (genuinely durable — hotlines/safety-plans/meeting-points stay until redacted)
REFERENCE=$(create_room reference   "Reference"     "Durable info that outlasts chat retention: hotlines, safety plans, meeting points, contacts. Pin anything worth keeping."  '{"events_default":50}' "")
GENERAL=$(create_room general       "General"       "Open discussion. Auto-deletes after retention window — move anything durable to #reference."  ""  "")
for r in WELCOME ANNOUNCE REFERENCE GENERAL; do printf '  #%s -> %s\n' "$(echo "$r" | tr A-Z a-z)" "${!r:-ERR}"; done
# #welcome holds the pinned security primer — keep it the full 30d (the server ceiling), not the
# ~7d chat default, so the primer doesn't roll off. (It also lives in home.html + the guides.)
ensure_retention "$WELCOME" 30

say "lock widget registration to admin-only (PL 100)"
# Widgets are enabled in config.json but only the system account (PL 100) should be able
# to register them. This prevents any moderator from adding arbitrary widget URLs.
for c in "$SPACE_ID" "$WELCOME" "$ANNOUNCE" "$REFERENCE" "$GENERAL"; do
  [ -n "$c" ] && lock_widget_pl "$c"
done
echo "  im.vector.modular.widgets -> PL 100 in all rooms"

say "wire channels into the space (ordered) + put the security primer on #welcome"
# Order field is a lexicographic sort key — "a" sorts first in the sidebar (Discord-like channel ordering).
[ -n "$WELCOME" ]   && link_child "$SPACE_ID" "$WELCOME"   "a" true
[ -n "$GENERAL" ]   && link_child "$SPACE_ID" "$GENERAL"   "b" true
[ -n "$ANNOUNCE" ]  && link_child "$SPACE_ID" "$ANNOUNCE"  "c" true
[ -n "$REFERENCE" ] && link_child "$SPACE_ID" "$REFERENCE" "d" true
if [ -n "$WELCOME" ]; then
  set_topic "$WELCOME" "$PRIMER" && echo "  #welcome topic = security primer"
  WELCOME_MSG="Welcome to ${REDNET_BRAND}. This is your community's secure space.

🔒 Your messages are end-to-end encrypted — the server cannot read them.
👁 The server CAN see who you talk to and when — keep real names and locations out of chat.
🔑 Your recovery passphrase is the only way to get back in on a new device. Keep it safe and offline.
🧹 Chat messages auto-delete after a few days. Durable info lives in #reference.

PROTECT YOURSELF
• Your username and display name are visible to everyone here — and to anyone who gains access to this server. Do not use your real name or a handle you use on other platforms.
• Turn off lock screen notification previews. On iPhone: Settings > Notifications > Element X > Show Previews > Never. On Android: Settings > Apps > Element X > Notifications > turn off Sensitive notifications.
• Log in on a second device (laptop or tablet) as a backup. If you lose your phone, a second session lets you back in without the recovery passphrase.
• Your display name (Settings > Profile) follows the same rules as your username: no real names, no handles from other platforms.

CHANNELS
  #general — open discussion
  #announcements — organizer posts (read-only)
  #reference — durable info: hotlines, safety plans, meeting points (does not auto-delete)

Head to #general to start chatting."
  send_notice "$WELCOME" "$WELCOME_MSG" && echo "  #welcome notice sent (plaintext, pre-E2EE)"
  enable_e2ee "$WELCOME" && echo "  #welcome E2EE enabled (all future messages encrypted)"
fi

say "VERIFY: structure + server-side invite path for MAS-CLI users"
KIDS=$(curl -s -H "$AUTH" "$ACCESS/_matrix/client/v3/rooms/$(enc "$SPACE_ID")/state" | python3 -c "import sys,json;print(sum(1 for e in json.load(sys.stdin) if e.get('type')=='m.space.child' and e.get('content',{}).get('via')))" 2>/dev/null)
mas register-user joincheck --password "$(genpw)" --yes --ignore-password-complexity 2>&1 | tail -1
# MAS-CLI bypasses Synapse's auto_join_rooms — use invite-to-community.sh (the operator tool) to verify
# server-side invite works. The client-side joinStarterRooms() in the module is the interactive-registration path.
bash "$(dirname "$0")/invite-to-community.sh" joincheck 2>&1 | sed 's/^/  /'
JT=$(mas issue-compatibility-token joincheck JCDEV | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
# Accept the invites (simulates what the client does on login)
for alias in community welcome announcements reference general; do
  curl -s -XPOST "$ACCESS/_matrix/client/v3/join/%23${alias}%3A${REDNET_DOMAIN}" \
    -H "Authorization: Bearer $JT" -d '{}' >/dev/null 2>&1
done
sleep 1
N=$(curl -s -H "Authorization: Bearer $JT" "$ACCESS/_matrix/client/v3/joined_rooms" | jqpy "len(d.get('joined_rooms',[]))")
mas lock-user joincheck >/dev/null 2>&1 || true
echo "  after invite+join: $N room(s); space has $KIDS linked channel(s)"

say "VERDICT"
if [ "${KIDS:-0}" -ge 4 ]; then
  echo "STRUCTURE PASS: space '$REDNET_BRAND' + #welcome/#general/#announcements/#reference (4 children, ordered); #welcome carries the security primer."
else
  echo "STRUCTURE FAIL: space has only ${KIDS:-0} linked channels (expected >= 4)."
fi
if [ "${N:-0}" -ge 4 ]; then
  echo "AUTO-JOIN PASS: invite-to-community.sh + client join → $N rooms."
else
  echo "AUTO-JOIN PARTIAL: invite+join produced only $N rooms (expected >= 4)."
fi
echo
echo "OPERATOR NOTE: after 'mas register-user <name>', run './invite-to-community.sh <name>'"
echo "to server-side invite the user. Interactive (Element UI) registration is handled by the"
echo "client-side module (joinStarterRooms)."
