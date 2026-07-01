#!/usr/bin/env bash
# Stand up the REDnet governance bot against the running stack.
# Creates @rednet-gov account, #gov-bot command room (non-E2EE), wires the bot
# into governance rooms with appropriate PLs, renders config, and starts the
# Docker service.
#
# Why non-E2EE for #gov-bot: the Widget API (MSC2762) cannot send events in E2EE
# rooms. The governance widget in #governance needs to help compose commands that
# the user sends here. Same pattern as Draupnir's #rednet-mod.
#
# Idempotent. Requires ./setup.sh + ./bootstrap-rooms.sh + ./bootstrap-governance.sh first.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?}"; : "${REDNET_HTTP_PORT:=8080}"; : "${REDNET_BRAND:=REDnet}"
. ./lib-access.sh
ACCESS="$API_URL"
say(){ printf '\n=== %s ===\n' "$*"; }
genpw(){ LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32; }
mas(){ docker compose exec -T mas mas-cli manage "$@" --config /config.yaml 2>&1; }
enc(){ python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }
roomid_of(){ python3 -c "import sys,json;print(json.load(sys.stdin).get('room_id',''))" 2>/dev/null; }
resolve_alias(){ curl -s -H "$1" "$ACCESS/_matrix/client/v3/directory/room/%23${2}%3A$REDNET_DOMAIN" | roomid_of; }

say "bot account @rednet-gov"
mas register-user rednet-gov --password "$(genpw)" --yes --ignore-password-complexity 2>&1 | tail -1
GOV_TOK=$(mas issue-compatibility-token rednet-gov GOVDEV | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
[ -n "${GOV_TOK:-}" ] || { echo "ERR: no gov bot token"; exit 1; }
GAUTH="Authorization: Bearer $GOV_TOK"

say "system token"
SYS_TOK=$(mas issue-compatibility-token rednet-system GOVSYS2 | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
[ -n "${SYS_TOK:-}" ] || { echo "ERR: no system token — run bootstrap-rooms.sh first"; exit 1; }
SAUTH="Authorization: Bearer $SYS_TOK"

say "#gov-bot (NON-E2EE command channel — same pattern as #rednet-mod)"
GOV_BOT_ROOM=$(curl -s -H "$GAUTH" "$ACCESS/_matrix/client/v3/directory/room/%23gov-bot%3A$REDNET_DOMAIN" | roomid_of)
if [ -z "$GOV_BOT_ROOM" ]; then
  GOV_BOT_ROOM=$(curl -s -XPOST "$ACCESS/_matrix/client/v3/createRoom" -H "$GAUTH" -H "Content-Type: application/json" -d '{
    "room_alias_name":"gov-bot","name":"'"$REDNET_BRAND"' — Gov Bot",
    "topic":"Bot commands — type !gov help. Dashboard: '"${REDNET_PUBLIC_BASE:-http://localhost:${REDNET_HTTP_PORT}}"'/governance/ · Non-E2EE by design (bot can'"'"'t decrypt).",
    "preset":"private_chat","visibility":"private",
    "power_level_content_override":{"invite":50,"kick":50,"ban":50,"state_default":50,"events_default":0}
  }' | roomid_of)
  echo "  created: $GOV_BOT_ROOM"
else
  echo "  exists: $GOV_BOT_ROOM"
fi
[ -n "$GOV_BOT_ROOM" ] || { echo "ERR: #gov-bot room not created"; exit 1; }

say "link #gov-bot into the Organizing sub-space"
ORGANIZING_ID=$(resolve_alias "$SAUTH" organizing 2>/dev/null)
if [ -n "$ORGANIZING_ID" ]; then
  # Link into the Organizing sub-space (created by bootstrap-governance.sh), not the top-level space
  curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$ORGANIZING_ID")/state/m.space.child/$(enc "$GOV_BOT_ROOM")" \
    -H "$SAUTH" -H "Content-Type: application/json" \
    -d "{\"via\":[\"$REDNET_DOMAIN\"],\"suggested\":true}" >/dev/null
  curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$GOV_BOT_ROOM")/state/m.space.parent/$(enc "$ORGANIZING_ID")" \
    -H "$GAUTH" -H "Content-Type: application/json" \
    -d "{\"via\":[\"$REDNET_DOMAIN\"],\"canonical\":true}" >/dev/null
  echo "  linked to Organizing sub-space"
else
  # Fallback: link directly to community space if Organizing sub-space not found
  SPACE_ID=$(resolve_alias "$SAUTH" community 2>/dev/null)
  if [ -n "$SPACE_ID" ]; then
    curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$SPACE_ID")/state/m.space.child/$(enc "$GOV_BOT_ROOM")" \
      -H "$SAUTH" -H "Content-Type: application/json" \
      -d "{\"via\":[\"$REDNET_DOMAIN\"],\"suggested\":false}" >/dev/null
    curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$GOV_BOT_ROOM")/state/m.space.parent/$(enc "$SPACE_ID")" \
      -H "$GAUTH" -H "Content-Type: application/json" \
      -d "{\"via\":[\"$REDNET_DOMAIN\"],\"canonical\":true}" >/dev/null
    echo "  FALLBACK: linked to community space (run bootstrap-governance.sh first for sub-space)"
  else
    echo "  SKIP: neither Organizing sub-space nor community space found"
  fi
fi

say "register governance widget in #gov-bot"
WIDGET_URL="${REDNET_PUBLIC_BASE:-http://localhost:${REDNET_HTTP_PORT}}/governance/?widgetId=\$matrix_widget_id&parentUrl=\$matrix_room_id&commandRoom=gov-bot"
curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$GOV_BOT_ROOM")/state/im.vector.modular.widgets/governance-widget" \
  -H "$GAUTH" -H "Content-Type: application/json" \
  -d "{\"type\":\"m.custom\",\"url\":\"$WIDGET_URL\",\"name\":\"Governance\",\"id\":\"governance-widget\",\"creatorUserId\":\"@rednet-gov:${REDNET_DOMAIN}\",\"data\":{}}" >/dev/null
# Pin widget to timeline (Element Web needs io.element.widgets.layout to render it)
curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$GOV_BOT_ROOM")/state/io.element.widgets.layout/" \
  -H "$GAUTH" -H "Content-Type: application/json" \
  -d '{"widgets":{"governance-widget":{"container":"top","height":50,"width":100,"index":0}}}' >/dev/null
echo "  governance widget registered + pinned in #gov-bot"

say "wire bot into governance rooms (PL 100 — needs full admin for revocation)"
GOVERNANCE_ROOMS=(vouch-log governance)
for alias in "${GOVERNANCE_ROOMS[@]}"; do
  RID=$(resolve_alias "$SAUTH" "$alias" 2>/dev/null)
  if [ -n "$RID" ]; then
    curl -s -XPOST "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/invite" \
      -H "$SAUTH" -H "Content-Type: application/json" \
      -d "{\"user_id\":\"@rednet-gov:$REDNET_DOMAIN\"}" >/dev/null 2>&1
    curl -s -XPOST "$ACCESS/_matrix/client/v3/join/$(enc "$RID")" \
      -H "$GAUTH" -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1
    # Set PL via system account
    PL_STATE=$(curl -s "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/state/m.room.power_levels/" -H "$SAUTH")
    UPDATED=$(echo "$PL_STATE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
d.setdefault('users',{})['@rednet-gov:$REDNET_DOMAIN']=100
print(json.dumps(d))
" 2>/dev/null)
    [ -n "$UPDATED" ] && curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/state/m.room.power_levels/" \
      -H "$SAUTH" -H "Content-Type: application/json" -d "$UPDATED" >/dev/null
    echo "  #$alias -> bot joined, PL 100"
  else
    echo "  #$alias -> room not found"
  fi
done

say "wire bot into community rooms (PL 100 — for kick/ban/PL operations)"
COMMUNITY_ROOMS=(community welcome announcements reference general)
for alias in "${COMMUNITY_ROOMS[@]}"; do
  RID=$(resolve_alias "$SAUTH" "$alias" 2>/dev/null)
  if [ -n "$RID" ]; then
    curl -s -XPOST "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/invite" \
      -H "$SAUTH" -H "Content-Type: application/json" \
      -d "{\"user_id\":\"@rednet-gov:$REDNET_DOMAIN\"}" >/dev/null 2>&1
    curl -s -XPOST "$ACCESS/_matrix/client/v3/join/$(enc "$RID")" \
      -H "$GAUTH" -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1
    PL_STATE=$(curl -s "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/state/m.room.power_levels/" -H "$SAUTH")
    UPDATED=$(echo "$PL_STATE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
d.setdefault('users',{})['@rednet-gov:$REDNET_DOMAIN']=100
print(json.dumps(d))
" 2>/dev/null)
    [ -n "$UPDATED" ] && curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/state/m.room.power_levels/" \
      -H "$SAUTH" -H "Content-Type: application/json" -d "$UPDATED" >/dev/null
    echo "  #$alias -> bot joined, PL 100"
  else
    echo "  #$alias -> room not found"
  fi
done

say "grant rednet-system the Synapse admin flag (!gov delete uses the admin purge API)"
# Same direct-psql pattern as scrub-metadata.sh. MAS-managed accounts still row in
# synapse's users table; the admin API checks this flag on the requesting token's user.
docker compose exec -T postgres psql -U synapse -d synapse -q \
  -c "UPDATE users SET admin = 1 WHERE name = '@rednet-system:${REDNET_DOMAIN}';" \
  && echo "  rednet-system is a Synapse admin" \
  || echo "  WARN: could not set admin flag — !gov delete will fail until it is set"

say "render gov-bot config (tokens injected — gitignored)"
mkdir -p gov-bot
cat > gov-bot/.env <<ENVEOF
REDNET_DOMAIN=$REDNET_DOMAIN
GOV_BOT_TOKEN=$GOV_TOK
SYS_TOKEN=$SYS_TOK
REDNET_ACCESS_URL=http://synapse:8008
VOUCH_JSONL_PATH=/data/vouch.jsonl
ENVEOF
echo "  gov-bot/.env rendered (tokens ${GOV_TOK:0:8}... / ${SYS_TOK:0:8}...)"

say "start gov-bot"
docker compose --profile governance up -d gov-bot
echo "  Gov bot starting..."

say "VERIFY: bot synced and posted startup notice"
LIVE=0
for _ in $(seq 1 15); do
  sleep 3
  N=$(curl -s -H "$GAUTH" "$ACCESS/_matrix/client/v3/rooms/$(enc "$GOV_BOT_ROOM")/messages?dir=b&limit=10" \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(sum(1 for e in d.get('chunk',[]) if e.get('sender')=='@rednet-gov:$REDNET_DOMAIN' and e.get('type')=='m.room.message'))
" 2>/dev/null)
  if [ "${N:-0}" -ge 1 ]; then LIVE=1; break; fi
done

say "VERDICT"
if [ "$LIVE" = 1 ]; then
  echo "PASS: Gov bot is online, listening in #gov-bot."
  echo "  Bot: @rednet-gov:$REDNET_DOMAIN (PL 100 in all rooms)"
  echo "  Command room: #gov-bot:$REDNET_DOMAIN ($GOV_BOT_ROOM)"
  echo
  echo "USAGE:"
  echo "  1. Open Element and join #gov-bot"
  echo "  2. Type: !gov help"
  echo "  3. Commands: !gov status | !gov audit | !gov confirm | !gov revoke | !gov role | !gov report"
  echo
  echo "NEXT: invite organizers to #gov-bot via bootstrap-operator.sh"
else
  echo "FAIL: no startup notice from @rednet-gov. Check logs:"
  echo "  docker compose logs gov-bot"
fi
