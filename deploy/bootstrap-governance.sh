#!/usr/bin/env bash
# Bootstrap governance infrastructure: vouch log room, governance room, and local
# vouch index. Run after bootstrap-rooms.sh (needs the system account).
#
# Creates:
#   #vouch-log   — append-only audit trail of invite vouches, claims, role changes,
#                  and revocations. Invite-only, retention-exempt (the audit trail
#                  must outlive the 7-day message default). E2EE.
#   #governance  — organizer coordination (who's minting, policy discussion).
#                  Invite-only, E2EE.
#   vouch.jsonl  — local index for fast CLI queries (gitignored).
#
# Idempotent. Requires ./setup.sh + ./bootstrap-rooms.sh first.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?}"; : "${REDNET_HTTP_PORT:=8080}"; : "${REDNET_BRAND:=REDnet}"
. ./lib-access.sh
ACCESS="$API_URL"
say(){ printf '\n=== %s ===\n' "$*"; }
jqpy(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
mas(){ docker compose exec -T mas mas-cli manage "$@" --config /config.yaml 2>&1; }
enc(){ python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }

say "system token"
SYS_TOK=$(mas issue-compatibility-token rednet-system GOVSYS | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
[ -n "${SYS_TOK:-}" ] || { echo "ERR: no system token — run bootstrap-rooms.sh first"; exit 1; }
AUTH="Authorization: Bearer $SYS_TOK"

alias_exists(){ curl -s -H "$AUTH" "$ACCESS/_matrix/client/v3/directory/room/%23${1}%3A${REDNET_DOMAIN}" | grep -q '"room_id"'; }
get_alias_id(){ curl -s -H "$AUTH" "$ACCESS/_matrix/client/v3/directory/room/%23${1}%3A${REDNET_DOMAIN}" | jqpy "d.get('room_id','')"; }

create_private_room(){
  local alias="$1" name="$2" topic="$3" plover="$4" retention="$5"
  if alias_exists "$alias"; then get_alias_id "$alias"; return; fi
  local initial_state="[{\"type\":\"m.room.encryption\",\"state_key\":\"\",\"content\":{\"algorithm\":\"m.megolm.v1.aes-sha2\"}}"
  if [ -n "$retention" ]; then
    initial_state="$initial_state,{\"type\":\"m.room.retention\",\"state_key\":\"\",\"content\":{\"max_lifetime\":$retention}}"
  fi
  initial_state="$initial_state]"
  local body="{\"room_alias_name\":\"$alias\",\"name\":\"$name\",\"topic\":\"$topic\",\"preset\":\"private_chat\",\"visibility\":\"private\""
  [ -n "$plover" ] && body="$body,\"power_level_content_override\":$plover"
  body="$body,\"initial_state\":$initial_state}"
  curl -s -XPOST "$ACCESS/_matrix/client/v3/createRoom" -H "$AUTH" -H "Content-Type: application/json" -d "$body" | jqpy "d.get('room_id','')"
}

say "#vouch-log (append-only audit trail)"
# events_default:50 = only organizers (PL50+) can post; invite:50 = only organizers can invite.
# No retention override — vouch records must persist indefinitely.
VOUCH_LOG=$(create_private_room vouch-log \
  "${REDNET_BRAND} — Vouch Log" \
  "Append-only audit trail: vouches, claims, role changes, revocations. Retention-exempt — do not delete events." \
  '{"events_default":50,"invite":50,"kick":50,"ban":50,"state_default":50}' \
  "")
echo "  #vouch-log -> ${VOUCH_LOG:-ERR}"

say "#governance (organizer coordination)"
GOVERNANCE=$(create_private_room governance \
  "${REDNET_BRAND} — Governance" \
  "Organizer coordination (E2EE). Admission policy, moderation decisions, incident response." \
  '{"invite":50,"kick":50,"ban":50,"state_default":50}' \
  "")
echo "  #governance -> ${GOVERNANCE:-ERR}"

say "lock widget registration to admin-only (PL 100)"
lock_widget_pl(){
  local rid="$1" PL_STATE PL_UPDATED
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
for c in "$VOUCH_LOG" "$GOVERNANCE"; do [ -n "$c" ] && lock_widget_pl "$c"; done
echo "  im.vector.modular.widgets -> PL 100 in governance rooms"

say "Organizing sub-space (Discord-like category for organizer-only channels)"
# Sub-spaces render as collapsible sections in Element's sidebar.
# 'suggested: false' + 'order: z' = sorts last, hidden from regular members' suggested rooms list.
create_space(){
  if alias_exists "$1"; then get_alias_id "$1"; return; fi
  curl -s -XPOST "$ACCESS/_matrix/client/v3/createRoom" -H "$AUTH" -H "Content-Type: application/json" -d "{
    \"room_alias_name\":\"$1\",\"name\":\"$2\",\"topic\":\"$3\",\"preset\":\"private_chat\",\"visibility\":\"private\",
    \"creation_content\":{\"type\":\"m.space\"},\"power_level_content_override\":{\"events_default\":50,\"invite\":50}
  }" | jqpy "d.get('room_id','')"
}
ORGANIZING=$(create_space organizing "${REDNET_BRAND} — Organizing" "Organizer-only channels: governance, vouching, bot commands.")
echo "  #organizing -> ${ORGANIZING:-ERR}"

say "link governance rooms into the Organizing sub-space"
SPACE_ID=$(get_alias_id community 2>/dev/null)
if [ -n "$SPACE_ID" ] && [ -n "$ORGANIZING" ]; then
  # Link Organizing sub-space to the top-level community space (sorted last, not suggested)
  curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$SPACE_ID")/state/m.space.child/$(enc "$ORGANIZING")" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "{\"via\":[\"$REDNET_DOMAIN\"],\"suggested\":false,\"order\":\"z\"}" >/dev/null
  curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$ORGANIZING")/state/m.space.parent/$(enc "$SPACE_ID")" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "{\"via\":[\"$REDNET_DOMAIN\"],\"canonical\":true}" >/dev/null
  echo "  linked Organizing -> community space (order: z, suggested: false)"

  # Link governance rooms as children of the Organizing sub-space (not the top-level space)
  for CHILD in "$VOUCH_LOG" "$GOVERNANCE"; do
    [ -n "$CHILD" ] || continue
    curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$ORGANIZING")/state/m.space.child/$(enc "$CHILD")" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "{\"via\":[\"$REDNET_DOMAIN\"],\"suggested\":true}" >/dev/null
    curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$CHILD")/state/m.space.parent/$(enc "$ORGANIZING")" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "{\"via\":[\"$REDNET_DOMAIN\"],\"canonical\":true}" >/dev/null
  done
  echo "  linked #vouch-log + #governance -> Organizing sub-space"
else
  echo "  SKIP: community space or Organizing sub-space not found"
fi

say "initialize local vouch index"
touch vouch.jsonl
echo "  vouch.jsonl ready ($(wc -l < vouch.jsonl) existing records)"

say "VERDICT"
if [ -n "$VOUCH_LOG" ] && [ -n "$GOVERNANCE" ]; then
  echo "PASS: governance infrastructure ready."
  echo "  #vouch-log:  $VOUCH_LOG (invite organizers to this room)"
  echo "  #governance: $GOVERNANCE (invite organizers to this room)"
  echo "  vouch.jsonl: local index for CLI queries"
  echo
  echo "NEXT: invite organizers to both rooms, then use mint-invite.sh to create attributed invites."
else
  echo "FAIL: one or more rooms not created."
  exit 1
fi
