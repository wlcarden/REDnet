#!/usr/bin/env bash
# Assign a moderation role (power level) to a user, scoped to specific rooms or
# an entire space. Logs the assignment to #vouch-log.
#
# Usage:
#   ./set-role.sh @alice moderator --rooms "#general,#welcome"
#   ./set-role.sh @alice moderator --space "#ops-team"
#   ./set-role.sh @alice admin --rooms "#governance"
#   ./set-role.sh @alice member --rooms "#general"    # demote back to PL0
#
# Roles:
#   member    → PL 0   (default, can send messages)
#   moderator → PL 50  (kick, ban, redact, set topic)
#   organizer → PL 75  (mint invites, confirm vouches, assign moderators)
#   admin     → PL 100 (change power levels, all room operations)
#
# Requires: jq, stack running, target rooms exist.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?}"; : "${REDNET_HTTP_PORT:=8080}"
. ./lib-access.sh
ACCESS="$API_URL"

command -v jq >/dev/null 2>&1 || { echo "ERR: jq required" >&2; exit 1; }

mas(){ docker compose exec -T mas mas-cli manage "$@" --config /config.yaml 2>&1; }
enc(){ python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }
now_iso(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
txn_id(){ printf 'role-%s-%s' "$(date +%s%N)" "$$"; }

USER=""
ROLE=""
ROOMS_ARG=""
SPACE_ARG=""

case "${1:-}" in
  @*) USER="$1"; shift ;;
  *)  echo "Usage: $0 @user moderator|admin|member --rooms \"#r1,#r2\" | --space \"#space\"" >&2; exit 1 ;;
esac

case "${1:-}" in
  moderator) ROLE="moderator"; PL=50; shift ;;
  organizer) ROLE="organizer"; PL=75; shift ;;
  admin)     ROLE="admin"; PL=100; shift ;;
  member)    ROLE="member"; PL=0; shift ;;
  *)         echo "ERR: role must be member, moderator, organizer, or admin" >&2; exit 1 ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --rooms) ROOMS_ARG="$2"; shift 2 ;;
    --space) SPACE_ARG="$2"; shift 2 ;;
    *)       echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

[ -n "$ROOMS_ARG" ] || [ -n "$SPACE_ARG" ] || { echo "ERR: --rooms or --space required" >&2; exit 1; }

SYS_TOK=$(mas issue-compatibility-token rednet-system ROLESYS | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
[ -n "${SYS_TOK:-}" ] || { echo "ERR: no system token" >&2; exit 1; }
AUTH="Authorization: Bearer $SYS_TOK"

resolve_alias(){
  local alias="${1#\#}"
  curl -s -H "$AUTH" "$ACCESS/_matrix/client/v3/directory/room/%23${alias}%3A${REDNET_DOMAIN}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('room_id',''))" 2>/dev/null
}

# Build list of room IDs to operate on
ROOM_IDS=()
ROOM_NAMES=()

if [ -n "$SPACE_ARG" ]; then
  SPACE_ALIAS="${SPACE_ARG#\#}"
  SPACE_RID=$(resolve_alias "$SPACE_ALIAS")
  [ -n "$SPACE_RID" ] || { echo "ERR: space #$SPACE_ALIAS not found" >&2; exit 1; }

  # Get all child rooms from the space
  CHILDREN=$(curl -s -H "$AUTH" "$ACCESS/_matrix/client/v3/rooms/$(enc "$SPACE_RID")/state" \
    | python3 -c "
import sys,json
events = json.load(sys.stdin)
for e in events:
  if e.get('type') == 'm.space.child' and e.get('content',{}).get('via'):
    print(e['state_key'])
" 2>/dev/null)

  while IFS= read -r child_id; do
    [ -n "$child_id" ] || continue
    ROOM_IDS+=("$child_id")
    ROOM_NAMES+=("(child of #$SPACE_ALIAS)")
  done <<< "$CHILDREN"

  echo "Space #$SPACE_ALIAS: ${#ROOM_IDS[@]} child room(s)"
fi

if [ -n "$ROOMS_ARG" ]; then
  IFS=',' read -ra ALIASES <<< "$ROOMS_ARG"
  for A in "${ALIASES[@]}"; do
    A=$(echo "$A" | tr -d ' ' | sed 's/^#//')
    RID=$(resolve_alias "$A")
    if [ -n "$RID" ]; then
      ROOM_IDS+=("$RID")
      ROOM_NAMES+=("#$A")
    else
      echo "  WARN: #$A not found, skipping"
    fi
  done
fi

[ ${#ROOM_IDS[@]} -gt 0 ] || { echo "ERR: no valid rooms found" >&2; exit 1; }

echo "Setting $USER → $ROLE (PL $PL) in ${#ROOM_IDS[@]} room(s):"

OK=0
FAIL=0
for i in "${!ROOM_IDS[@]}"; do
  RID="${ROOM_IDS[$i]}"
  RNAME="${ROOM_NAMES[$i]}"

  # Invite if not a member
  curl -s -XPOST "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/invite" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "{\"user_id\":\"$USER\"}" >/dev/null 2>&1

  # Get current PLs, update
  PL_STATE=$(curl -s "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/state/m.room.power_levels/" -H "$AUTH")
  UPDATED=$(echo "$PL_STATE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
d.setdefault('users',{})['$USER']=$PL
print(json.dumps(d))
" 2>/dev/null)

  if [ -n "$UPDATED" ]; then
    RESP=$(curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/state/m.room.power_levels/" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "$UPDATED")
    if echo "$RESP" | grep -q "event_id"; then
      echo "  $RNAME → PL $PL"
      OK=$((OK + 1))
    else
      echo "  $RNAME → FAILED: $RESP"
      FAIL=$((FAIL + 1))
    fi
  else
    echo "  $RNAME → FAILED: could not read power levels"
    FAIL=$((FAIL + 1))
  fi
done

# --- Log to #vouch-log ---
VOUCH_LOG_ID=$(resolve_alias vouch-log 2>/dev/null)
if [ -n "$VOUCH_LOG_ID" ]; then
  SCOPE="${SPACE_ARG:-$ROOMS_ARG}"
  LOG_BODY=$(jq -n \
    --arg user "$USER" \
    --arg role "$ROLE" \
    --arg pl "$PL" \
    --arg scope "$SCOPE" \
    --arg ts "$(now_iso)" \
    '{
      msgtype: "org.rednet.role.assigned",
      body: ($user + " → " + $role + " in " + $scope),
      "org.rednet.role.assigned": {
        user: $user,
        role: $role,
        power_level: ($pl | tonumber),
        scope: $scope,
        timestamp: $ts
      }
    }')
  curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$VOUCH_LOG_ID")/send/m.room.message/$(txn_id)" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "$LOG_BODY" >/dev/null
  echo
  echo "  role assignment logged to #vouch-log"

  jq -nc \
    --arg user "$USER" \
    --arg role "$ROLE" \
    --arg pl "$PL" \
    --arg scope "$SCOPE" \
    --arg ts "$(now_iso)" \
    '{type:"role", user:$user, role:$role, power_level:($pl|tonumber), scope:$scope, timestamp:$ts}' \
    >> vouch.jsonl
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "DONE: $USER is $ROLE (PL $PL) in $OK room(s)."
else
  echo "PARTIAL: $OK succeeded, $FAIL failed."
fi
