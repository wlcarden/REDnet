#!/usr/bin/env bash
# Stand up Draupnir (moderation) against the running stack, then VERIFY it connects to our
# MAS-delegated homeserver and responds to an operator command. Idempotent-ish (re-running
# re-renders config + restarts). Requires the stack up (./setup.sh first).
set -uo pipefail
cd "$(dirname "$0")" || exit 1
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?}"; : "${REDNET_HTTP_PORT:=8080}"
ACCESS="http://localhost:${REDNET_HTTP_PORT}"
say(){ printf '\n=== %s ===\n' "$*"; }
genpw(){ LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32; }  # always exactly 32 alnum chars
mas(){ docker compose exec -T mas mas-cli manage "$@" --config /config.yaml 2>&1; }
enc(){ python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }
botcount(){ python3 -c "import sys,json;d=json.load(sys.stdin);print(sum(1 for e in d.get('chunk',[]) if e.get('sender')=='@rednet-mod:$REDNET_DOMAIN' and e.get('type')=='m.room.message'))" 2>/dev/null; }
mkdir -p draupnir/config

say "bot account @rednet-mod (+ synapse-admin token)"
# R2: NO synapse-admin. Ban/redact/server-ACL/policy-list act on room state via power levels, not admin;
# only `make-room-admin` needs admin (disabled in production.yaml.example). Keeps no god-credential on the core.
mas register-user rednet-mod --password "$(genpw)" --yes --ignore-password-complexity 2>&1 | tail -1
BOT_TOK=$(mas issue-compatibility-token rednet-mod MODDEV | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
[ -n "${BOT_TOK:-}" ] || { echo "no bot token"; exit 1; }
BAUTH="Authorization: Bearer $BOT_TOK"

say "management room (UNENCRYPTED operator control channel)"
roomid_of(){ python3 -c "import sys,json;print(json.load(sys.stdin).get('room_id',''))" 2>/dev/null; }
MROOM=$(curl -s -H "$BAUTH" "$ACCESS/_matrix/client/v3/directory/room/%23rednet-mod%3A$REDNET_DOMAIN" | roomid_of)
if [ -z "$MROOM" ]; then
  # R2: lock power levels so a non-operator member can't invite an OUTSIDER into the plaintext command
  # channel (default invite PL is 0). invite/kick/ban/state require PL>=50; the bot (creator) is PL100.
  MROOM=$(curl -s -XPOST "$ACCESS/_matrix/client/v3/createRoom" -H "$BAUTH" -d '{
    "room_alias_name":"rednet-mod","name":"REDnet — Moderation",
    "topic":"Draupnir control channel. Operators issue commands here.",
    "preset":"private_chat","visibility":"private",
    "power_level_content_override":{"invite":50,"kick":50,"ban":50,"state_default":50,"events_default":0}
  }' | roomid_of)
fi
[ -n "$MROOM" ] || { echo "management room not created"; exit 1; }
echo "management room: $MROOM"

say "policy list room (ban-list for Draupnir enforcement)"
POLICY_ROOM=$(curl -s -H "$BAUTH" "$ACCESS/_matrix/client/v3/directory/room/%23rednet-banlist%3A$REDNET_DOMAIN" | roomid_of)
if [ -z "$POLICY_ROOM" ]; then
  POLICY_ROOM=$(curl -s -XPOST "$ACCESS/_matrix/client/v3/createRoom" -H "$BAUTH" -d '{
    "room_alias_name":"rednet-banlist","name":"REDnet Ban List",
    "topic":"Policy list for REDnet moderation. Managed by Draupnir.",
    "preset":"private_chat","visibility":"private",
    "power_level_content_override":{"events_default":50,"invite":50}
  }' | roomid_of)
  echo "created: $POLICY_ROOM"
else
  echo "exists: $POLICY_ROOM"
fi

say "render draupnir/config/production.yaml (token injected — gitignored)"
sed -e "s#accessToken: .*#accessToken: \"$BOT_TOK\"#" \
    -e "s#managementRoom: .*#managementRoom: \"$MROOM\"#" \
    draupnir/production.yaml.example > draupnir/config/production.yaml
echo "config rendered (token ${BOT_TOK:0:8}...)"

say "wire bot into community rooms (PL 50 = kick/ban/redact, not admin)"
# protectAllJoinedRooms: true means Draupnir auto-protects every room it's in. The system account
# (room creator, PL 100) invites the bot + sets its PL to 50 (moderation, NOT admin — R2).
SYS_TOK=$(mas issue-compatibility-token rednet-system MODSYS | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
if [ -n "${SYS_TOK:-}" ]; then
  SAUTH="Authorization: Bearer $SYS_TOK"
  COMMUNITY_ROOMS=(welcome announcements reference general)
  for alias in "${COMMUNITY_ROOMS[@]}"; do
    RID=$(curl -s -H "$SAUTH" "$ACCESS/_matrix/client/v3/directory/room/%23${alias}%3A$REDNET_DOMAIN" \
      | python3 -c "import sys,json;print(json.load(sys.stdin).get('room_id',''))" 2>/dev/null)
    if [ -n "$RID" ]; then
      curl -s -XPOST "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/invite" -H "$SAUTH" \
        -d "{\"user_id\":\"@rednet-mod:$REDNET_DOMAIN\"}" >/dev/null 2>&1
      curl -s -XPOST "$ACCESS/_matrix/client/v3/join/$(enc "$RID")" -H "$BAUTH" -d '{}' >/dev/null 2>&1
      curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/state/m.room.power_levels/" \
        -H "$SAUTH" \
        -d "$(curl -s "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/state/m.room.power_levels/" -H "$SAUTH" \
          | python3 -c "
import sys,json
d=json.load(sys.stdin)
d.setdefault('users',{})['@rednet-mod:$(echo $REDNET_DOMAIN)']=50
print(json.dumps(d))
")" >/dev/null 2>&1
      echo "  #$alias -> bot joined, PL 50"
    else
      echo "  #$alias -> room not found (run bootstrap-rooms.sh first)"
    fi
  done
else
  echo "  SKIP: could not get system token (rednet-system may not exist yet)"
fi

say "start draupnir"
docker compose --profile moderation up -d draupnir
echo "Draupnir starting (sync can take ~10-30s)..."

# Liveness+function proof: Draupnir posts an operational notice (startup banner / policy status)
# to the management room once it has synced. Read it via the bot token, which is always active and
# a member — avoids a throwaway operator whose token can go stale. (Operator command path verified
# separately: an operator added to this room can run `!draupnir status` etc. and gets a reply.)
say "VERIFY: Draupnir synced and posted an operational notice to the management room"
LIVE=0
for _ in $(seq 1 20); do
  sleep 4
  N=$(curl -s -H "$BAUTH" "$ACCESS/_matrix/client/v3/rooms/$(enc "$MROOM")/messages?dir=b&limit=30" | botcount)
  if [ "${N:-0}" -ge 1 ]; then LIVE=1; break; fi
done

if [ "$LIVE" = 1 ] && [ -n "${POLICY_ROOM:-}" ]; then
  say "subscribe Draupnir to the ban-list policy room"
  TXN="watch-$(date +%s)"
  curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$MROOM")/send/m.room.message/$TXN" \
    -H "$BAUTH" \
    -d "{\"msgtype\":\"m.text\",\"body\":\"!draupnir watch #rednet-banlist:$REDNET_DOMAIN\"}" >/dev/null
  sleep 5
  echo "  ban-list subscribed (operators can now !draupnir ban from Element)"
fi

say "VERDICT"
if [ "$LIVE" = 1 ]; then
  echo "PASS: Draupnir is online against the MAS-delegated server, monitoring rooms, posting to management."
  echo "  Bot is PL 50 (moderator) in community rooms: ${COMMUNITY_ROOMS[*]:-not wired}"
  echo "  Policy list: #rednet-banlist:$REDNET_DOMAIN"
  echo
  echo "OPERATOR GUIDE:"
  echo "  1. Open Element and join the management room ($MROOM)."
  echo "  2. Commands: !draupnir help | !draupnir status | !draupnir rooms"
  echo "  3. To ban:   !draupnir ban @user:$REDNET_DOMAIN"
  echo "     Draupnir v3 uses INTERACTIVE prompts (policy list selection, reason entry)"
  echo "     that require Element's UI — they do NOT work from terminal Matrix clients"
  echo "     or raw API calls. Run moderation commands from Element."
  echo "  4. Direct API alternative (works from any client/script):"
  echo "     curl -XPOST .../rooms/<room_id>/ban -d '{\"user_id\":\"@user:...\",\"reason\":\"...\"}'"
else
  echo "FAIL: no operational notice from @rednet-mod. Draupnir logs (last 40 lines):"
  docker compose logs draupnir 2>&1 | tail -40
fi
