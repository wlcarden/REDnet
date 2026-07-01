#!/usr/bin/env bash
# Create a compartmented sub-space with invite-only rooms and scoped moderators.
#
# Usage:
#   ./create-compartment.sh "Ops Team" --rooms "ops-general,ops-planning"
#   ./create-compartment.sh "Leadership" --rooms "strategy" --moderators "@alice,@bob"
#   ./create-compartment.sh "Regional NW" --rooms "nw-general,nw-actions" --join-rule restricted
#   ./create-compartment.sh "Intel" --rooms "intel-only" --standalone
#
# Creates a sub-Space, links it to the community Space (unless --standalone), creates
# E2EE rooms inside it, and optionally sets moderator power levels. All actions logged
# to #vouch-log.
#
# Join rules:
#   invite     (default) — members must be explicitly invited to each room
#   restricted           — any member of the parent Space can join (MSC3083)
#
# Requires: jq, stack running, bootstrap-rooms.sh + bootstrap-governance.sh done.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?}"; : "${REDNET_HTTP_PORT:=8080}"; : "${REDNET_BRAND:=REDnet}"
. ./lib-access.sh
ACCESS="$API_URL"

command -v jq >/dev/null 2>&1 || { echo "ERR: jq required" >&2; exit 1; }

mas(){ docker compose exec -T mas mas-cli manage "$@" --config /config.yaml 2>&1; }
enc(){ python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }
now_iso(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
txn_id(){ printf 'comp-%s-%s' "$(date +%s%N)" "$$"; }
alias_exists(){ curl -s -H "$AUTH" "$ACCESS/_matrix/client/v3/directory/room/%23${1}%3A${REDNET_DOMAIN}" | grep -q '"room_id"'; }
get_alias_id(){ curl -s -H "$AUTH" "$ACCESS/_matrix/client/v3/directory/room/%23${1}%3A${REDNET_DOMAIN}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('room_id',''))" 2>/dev/null; }

NAME=""
ROOMS=""
MODERATORS=""
JOIN_RULE="invite"
STANDALONE=false

case "${1:-}" in
  --*) ;;
  "")  echo "Usage: $0 \"Name\" --rooms \"room1,room2\" [--moderators \"@a,@b\"] [--join-rule invite|restricted] [--standalone]" >&2; exit 1 ;;
  *)   NAME="$1"; shift ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --rooms)      ROOMS="$2"; shift 2 ;;
    --moderators) MODERATORS="$2"; shift 2 ;;
    --join-rule)  JOIN_RULE="$2"; shift 2 ;;
    --standalone) STANDALONE=true; shift ;;
    *)            echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

[ -n "$NAME" ]  || { echo "ERR: compartment name required" >&2; exit 1; }
[ -n "$ROOMS" ] || { echo "ERR: --rooms required" >&2; exit 1; }

SLUG=$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')

SYS_TOK=$(mas issue-compatibility-token rednet-system COMPSYS | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
[ -n "${SYS_TOK:-}" ] || { echo "ERR: no system token" >&2; exit 1; }
AUTH="Authorization: Bearer $SYS_TOK"

VOUCH_LOG_ID=$(get_alias_id vouch-log 2>/dev/null)

echo "Creating compartment: $NAME (slug: $SLUG)"
echo "  rooms:     $ROOMS"
echo "  join rule: $JOIN_RULE"
echo "  moderators: ${MODERATORS:-none}"
echo "  standalone: $STANDALONE"
echo

# --- Create the sub-Space ---
echo "=== Sub-Space ==="
SPACE_ALIAS="${SLUG}"
if alias_exists "$SPACE_ALIAS"; then
  SPACE_ID=$(get_alias_id "$SPACE_ALIAS")
  echo "  exists: $SPACE_ID"
else
  SPACE_ID=$(curl -s -XPOST "$ACCESS/_matrix/client/v3/createRoom" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg alias "$SPACE_ALIAS" \
      --arg name "$NAME" \
      --arg topic "$NAME — compartmented space" \
      --arg domain "$REDNET_DOMAIN" \
      '{
        room_alias_name: $alias,
        name: $name,
        topic: $topic,
        preset: "private_chat",
        visibility: "private",
        creation_content: {type: "m.space"},
        power_level_content_override: {events_default: 50, invite: 50, kick: 50, ban: 50, state_default: 50}
      }')" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('room_id',''))" 2>/dev/null)
  echo "  created: $SPACE_ID"
fi
[ -n "$SPACE_ID" ] || { echo "ERR: failed to create space" >&2; exit 1; }

# --- Link to community Space (unless standalone) ---
if ! $STANDALONE; then
  COMMUNITY_ID=$(get_alias_id community 2>/dev/null)
  if [ -n "$COMMUNITY_ID" ]; then
    curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$COMMUNITY_ID")/state/m.space.child/$(enc "$SPACE_ID")" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "{\"via\":[\"$REDNET_DOMAIN\"],\"suggested\":false}" >/dev/null
    curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$SPACE_ID")/state/m.space.parent/$(enc "$COMMUNITY_ID")" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "{\"via\":[\"$REDNET_DOMAIN\"],\"canonical\":true}" >/dev/null
    echo "  linked to community space (suggested: false)"
  fi
fi

# --- Create rooms ---
echo
echo "=== Rooms ==="
IFS=',' read -ra ROOM_LIST <<< "$ROOMS"
ROOM_IDS=()
for ROOM_NAME in "${ROOM_LIST[@]}"; do
  ROOM_NAME=$(echo "$ROOM_NAME" | tr -d ' ')
  ROOM_ALIAS="${SLUG}-${ROOM_NAME}"

  if alias_exists "$ROOM_ALIAS"; then
    RID=$(get_alias_id "$ROOM_ALIAS")
    echo "  #$ROOM_ALIAS exists: $RID"
  else
    INITIAL_STATE="[{\"type\":\"m.room.encryption\",\"state_key\":\"\",\"content\":{\"algorithm\":\"m.megolm.v1.aes-sha2\"}}"

    if [ "$JOIN_RULE" = "restricted" ] && [ -n "$SPACE_ID" ]; then
      INITIAL_STATE="$INITIAL_STATE,{\"type\":\"m.room.join_rules\",\"state_key\":\"\",\"content\":{\"join_rule\":\"restricted\",\"allow\":[{\"type\":\"m.room_membership\",\"room_id\":\"$SPACE_ID\"}]}}"
    fi
    INITIAL_STATE="$INITIAL_STATE]"

    PRESET="private_chat"
    RID=$(curl -s -XPOST "$ACCESS/_matrix/client/v3/createRoom" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "$(jq -n \
        --arg alias "$ROOM_ALIAS" \
        --arg name "$ROOM_NAME" \
        --arg topic "$NAME / $ROOM_NAME" \
        --argjson init_state "$INITIAL_STATE" \
        --arg preset "$PRESET" \
        '{
          room_alias_name: $alias,
          name: $name,
          topic: $topic,
          preset: $preset,
          visibility: "private",
          initial_state: $init_state
        }')" \
      | python3 -c "import sys,json;print(json.load(sys.stdin).get('room_id',''))" 2>/dev/null)
    echo "  #$ROOM_ALIAS created: $RID"
  fi

  if [ -n "$RID" ]; then
    ROOM_IDS+=("$RID")
    curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$SPACE_ID")/state/m.space.child/$(enc "$RID")" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "{\"via\":[\"$REDNET_DOMAIN\"],\"suggested\":true}" >/dev/null
    curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/state/m.space.parent/$(enc "$SPACE_ID")" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "{\"via\":[\"$REDNET_DOMAIN\"],\"canonical\":true}" >/dev/null
  fi
done

# --- Set moderators ---
if [ -n "$MODERATORS" ]; then
  echo
  echo "=== Moderators ==="
  IFS=',' read -ra MOD_LIST <<< "$MODERATORS"
  for MOD in "${MOD_LIST[@]}"; do
    MOD=$(echo "$MOD" | tr -d ' ')
    for RID in "${ROOM_IDS[@]}"; do
      # Invite the moderator
      curl -s -XPOST "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/invite" \
        -H "$AUTH" -H "Content-Type: application/json" \
        -d "{\"user_id\":\"$MOD\"}" >/dev/null 2>&1

      # Set PL 50
      PL_STATE=$(curl -s "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/state/m.room.power_levels/" -H "$AUTH")
      UPDATED_PL=$(echo "$PL_STATE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
d.setdefault('users',{})['$MOD']=50
print(json.dumps(d))
" 2>/dev/null)
      if [ -n "$UPDATED_PL" ]; then
        curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/state/m.room.power_levels/" \
          -H "$AUTH" -H "Content-Type: application/json" \
          -d "$UPDATED_PL" >/dev/null
      fi
    done
    echo "  $MOD → PL50 in ${#ROOM_IDS[@]} room(s)"
  done
fi

# --- Log to #vouch-log ---
if [ -n "$VOUCH_LOG_ID" ]; then
  echo
  echo "=== Audit log ==="
  LOG_BODY=$(jq -n \
    --arg name "$NAME" \
    --arg slug "$SLUG" \
    --arg rooms "$ROOMS" \
    --arg mods "$MODERATORS" \
    --arg jr "$JOIN_RULE" \
    --arg ts "$(now_iso)" \
    '{
      msgtype: "org.rednet.compartment.created",
      body: ("Compartment created: " + $name),
      "org.rednet.compartment.created": {
        name: $name,
        slug: $slug,
        rooms: ($rooms | split(",")),
        moderators: (if $mods == "" then [] else ($mods | split(",")) end),
        join_rule: $jr,
        timestamp: $ts
      }
    }')
  curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$VOUCH_LOG_ID")/send/m.room.message/$(txn_id)" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "$LOG_BODY" >/dev/null
  echo "  compartment creation logged to #vouch-log"

  jq -nc \
    --arg name "$NAME" \
    --arg slug "$SLUG" \
    --arg rooms "$ROOMS" \
    --arg mods "$MODERATORS" \
    --arg jr "$JOIN_RULE" \
    --arg ts "$(now_iso)" \
    '{type:"compartment", name:$name, slug:$slug, rooms:($rooms|split(",")), moderators:(if $mods=="" then [] else ($mods|split(",")) end), join_rule:$jr, timestamp:$ts}' \
    >> vouch.jsonl
fi

echo
echo "DONE: compartment \"$NAME\" ready with ${#ROOM_IDS[@]} room(s)."
[ -n "$MODERATORS" ] && echo "Moderators must accept their invites to the rooms."
