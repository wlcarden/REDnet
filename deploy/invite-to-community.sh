#!/usr/bin/env bash
# Invite a MAS-CLI provisioned user into the REDnet community rooms.
#
# Synapse auto_join_rooms does NOT fire for users created via `mas register-user` (confirmed empirically) —
# it only fires on Synapse's own registration path. This script fills that gap: run it after provisioning a
# user to server-side invite them into the same 5 rooms the client-side joinStarterRooms() targets.
#
# Usage: ./invite-to-community.sh <username>
# Requires: rednet.env sourced (or REDNET_DOMAIN set), stack running, system account exists.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?}"
: "${REDNET_HTTP_PORT:=8080}"
. ./lib-access.sh
ACCESS="$API_URL"
mas(){ docker compose exec -T mas mas-cli manage "$@" --config /config.yaml 2>&1; }
enc(){ python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }

USERNAME="${1:?usage: $0 <username>}"
USER_ID="@${USERNAME}:${REDNET_DOMAIN}"

SYS_TOK=$(mas issue-compatibility-token rednet-system INVITE 2>/dev/null | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
if [ -z "${SYS_TOK:-}" ]; then
  echo "ERR: could not mint system token — is the stack running and rednet-system registered?" >&2
  exit 1
fi
AUTH="Authorization: Bearer $SYS_TOK"

ROOMS=(community welcome announcements reference general)
OK=0
FAIL=0
for alias in "${ROOMS[@]}"; do
  RID=$(curl -s -H "$AUTH" "$ACCESS/_matrix/client/v3/directory/room/%23${alias}%3A${REDNET_DOMAIN}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('room_id',''))" 2>/dev/null)
  if [ -z "$RID" ]; then
    echo "  SKIP #${alias} — room not found"
    FAIL=$((FAIL + 1))
    continue
  fi
  # rc_invites burst is 5 (then 0.1/s). This loop is exactly 5 invites, so a
  # single onboarding fits — but back-to-back onboards share the per-issuer
  # burst and get M_LIMIT_EXCEEDED. Retry past the throttle window so a member
  # never silently misses a room.
  ERR="?"
  for _ in 1 2 3 4 5; do
    RESP=$(curl -s -XPOST "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/invite" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "{\"user_id\":\"$USER_ID\"}")
    ERR=$(echo "$RESP" | python3 -c "import sys,json;print(json.load(sys.stdin).get('errcode',''))" 2>/dev/null)
    [ "$ERR" = "M_LIMIT_EXCEEDED" ] || break
    sleep 11
  done
  if [ -z "$ERR" ] || [ "$ERR" = "M_FORBIDDEN" ]; then
    echo "  #${alias} — invited (or already a member)"
    OK=$((OK + 1))
  else
    echo "  #${alias} — FAILED: $RESP"
    FAIL=$((FAIL + 1))
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "DONE: $USER_ID invited to $OK room(s). They will see the invites on next login."
else
  echo "PARTIAL: $OK invited, $FAIL failed."
  exit 1
fi
