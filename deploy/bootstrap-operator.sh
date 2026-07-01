#!/usr/bin/env bash
# Bootstrap an organizer/operator account. Run after setup.sh + bootstrap-rooms.sh.
#
# Creates (or reuses) a MAS account, invites them to all community + governance
# rooms, sets their power level, and optionally adds them to the Draupnir
# management room. The first operator bootstrapped after deploy has no one to
# invite them — this script uses the system account to do it all in one pass.
#
# Usage:
#   ./bootstrap-operator.sh alice                    # create + full admin setup
#   ./bootstrap-operator.sh alice --role moderator   # scoped moderator (PL50)
#   ./bootstrap-operator.sh alice --existing         # skip account creation (already registered)
#   ./bootstrap-operator.sh alice --no-draupnir      # skip Draupnir management room
#
# After this script, the operator can:
#   - Log in via Element and see all community + governance rooms
#   - Mint attributed invites with mint-invite.sh
#   - Open the governance dashboard at /governance/
#   - Issue Draupnir commands in #rednet-mod (if admin + Draupnir running)
#
# Requires: stack running, rednet-system account exists (bootstrap-rooms.sh).
set -uo pipefail
cd "$(dirname "$0")" || exit 1
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?set REDNET_DOMAIN in rednet.env}"
: "${REDNET_HTTP_PORT:=8080}"
. ./lib-access.sh
ACCESS="$API_URL"
say(){ printf '\n=== %s ===\n' "$*"; }
mas(){ docker compose exec -T mas mas-cli manage "$@" --config /config.yaml 2>&1; }
enc(){ python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }
genpw(){ python3 -c "import secrets; print(secrets.token_urlsafe(24))"; }

USERNAME=""
ROLE="admin"
EXISTING=false
DRAUPNIR=true

case "${1:-}" in
  "") echo "Usage: $0 <username> [--role admin|moderator] [--existing] [--no-draupnir]" >&2; exit 1 ;;
  -*) echo "ERR: first argument must be a username, not a flag" >&2; exit 1 ;;
  *)  USERNAME="$1"; shift ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --role)         ROLE="$2"; shift 2 ;;
    --existing)     EXISTING=true; shift ;;
    --no-draupnir)  DRAUPNIR=false; shift ;;
    *)              echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

USER_ID="@${USERNAME}:${REDNET_DOMAIN}"
PL=100
case "$ROLE" in
  admin)     PL=100 ;;
  organizer) PL=75 ;;
  moderator) PL=50 ;;
  *)         echo "ERR: --role must be admin, organizer, or moderator" >&2; exit 1 ;;
esac

say "system token"
SYS_TOK=$(mas issue-compatibility-token rednet-system OPSYS | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
[ -n "${SYS_TOK:-}" ] || { echo "ERR: no system token — run bootstrap-rooms.sh first" >&2; exit 1; }
AUTH="Authorization: Bearer $SYS_TOK"

resolve_room(){
  curl -s -H "$AUTH" "$ACCESS/_matrix/client/v3/directory/room/%23${1}%3A${REDNET_DOMAIN}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('room_id',''))" 2>/dev/null
}

invite_user(){
  local room_id="$1"
  [ -n "$room_id" ] || return 1
  local resp
  resp=$(curl -s -XPOST "$ACCESS/_matrix/client/v3/rooms/$(enc "$room_id")/invite" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "{\"user_id\":\"$USER_ID\"}")
  local err
  err=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('errcode',''))" 2>/dev/null)
  [ -z "$err" ] || [ "$err" = "M_FORBIDDEN" ]
}

set_power_level(){
  local room_id="$1" level="$2"
  [ -n "$room_id" ] || return 1
  local current
  current=$(curl -s -H "$AUTH" "$ACCESS/_matrix/client/v3/rooms/$(enc "$room_id")/state/m.room.power_levels/")
  local updated
  updated=$(echo "$current" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d.setdefault('users', {})['$USER_ID'] = $level
json.dump(d, sys.stdout)
" 2>/dev/null)
  [ -n "$updated" ] || return 1
  curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$room_id")/state/m.room.power_levels/" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "$updated" >/dev/null
}

# --- 1. Create account ---
say "account: $USERNAME ($ROLE)"
if $EXISTING; then
  echo "  skipping creation (--existing)"
else
  PW=$(genpw)
  RESULT=$(mas register-user "$USERNAME" --password "$PW" --yes --ignore-password-complexity 2>&1)
  if echo "$RESULT" | grep -qi "already exists"; then
    echo "  account already exists — continuing"
  elif echo "$RESULT" | grep -qi "registered"; then
    echo "  account created"
    echo "  temporary password: $PW"
    echo "  (operator should change it on first login)"
  else
    echo "  MAS response: $RESULT"
    echo "  continuing anyway (account may already exist)"
  fi
fi

# --- 2. Invite to community rooms ---
say "invite to community rooms"
COMMUNITY_ROOMS=(community welcome announcements reference general)
for alias in "${COMMUNITY_ROOMS[@]}"; do
  rid=$(resolve_room "$alias")
  if [ -z "$rid" ]; then
    echo "  SKIP #${alias} — not found"
    continue
  fi
  if invite_user "$rid"; then
    echo "  #${alias} — invited"
  else
    echo "  #${alias} — invite failed (may already be a member)"
  fi
done

# --- 3. Invite to governance rooms + Organizing sub-space ---
say "invite to governance rooms"
for alias in organizing vouch-log governance gov-bot; do
  rid=$(resolve_room "$alias")
  if [ -z "$rid" ]; then
    echo "  SKIP #${alias} — not found (run bootstrap-governance.sh)"
    continue
  fi
  if invite_user "$rid"; then
    echo "  #${alias} — invited"
  else
    echo "  #${alias} — invite failed (may already be a member)"
  fi
done

# --- 4. Set power levels ---
say "set power levels (${ROLE} = PL${PL})"
ALL_ROOMS=(community welcome announcements reference general organizing vouch-log governance gov-bot)
for alias in "${ALL_ROOMS[@]}"; do
  rid=$(resolve_room "$alias")
  if [ -z "$rid" ]; then
    continue
  fi
  if set_power_level "$rid" "$PL"; then
    echo "  #${alias} — PL${PL}"
  else
    echo "  #${alias} — failed to set PL"
  fi
done

# --- 5. Draupnir management room ---
if $DRAUPNIR; then
  say "Draupnir management room"
  MOD_RID=$(resolve_room "rednet-mod")
  if [ -n "$MOD_RID" ]; then
    if invite_user "$MOD_RID"; then
      echo "  #rednet-mod — invited"
    else
      echo "  #rednet-mod — invite failed (may already be a member)"
    fi
    if [ "$ROLE" = "admin" ]; then
      set_power_level "$MOD_RID" "$PL" && echo "  #rednet-mod — PL${PL}"
    fi
  else
    echo "  SKIP: #rednet-mod not found (run bootstrap-draupnir.sh first)"
  fi
fi

# --- 6. Summary ---
say "DONE"
echo "$USER_ID bootstrapped as $ROLE."

# When called with --existing (e.g. from deploy.sh), the caller handles credentials
# and next-steps. Only print the interactive summary for standalone use.
if ! $EXISTING; then
  echo
  GUIDE_BASE="${REDNET_PUBLIC_BASE:-http://localhost:${REDNET_HTTP_PORT}}"
  case "$ROLE" in
    admin|organizer) GUIDE_URL="${GUIDE_BASE}/operator-guide" ;;
    moderator)       GUIDE_URL="${GUIDE_BASE}/moderator-guide" ;;
  esac

  echo "The $ROLE should now:"
  echo "  1. Log in with username '$USERNAME' and the password above"
  echo "  2. Accept the room invites they'll see on first login"
  if [ "$ROLE" = "admin" ]; then
    echo "  3. Set REDNET_OPERATOR=$USER_ID in their rednet.env"
    if $DRAUPNIR && [ -n "$(resolve_room rednet-mod 2>/dev/null)" ]; then
      echo "  4. Open #rednet-mod and verify Draupnir responds to !draupnir status"
    fi
  fi
  echo "  Read the guide: $GUIDE_URL"
  if [ "$ROLE" = "admin" ] || [ "$ROLE" = "organizer" ]; then
    echo
    echo "Gov bot commands (in #gov-bot):"
    echo "  !gov help           — list all commands"
    echo "  !gov confirm @user  — confirm a vouch"
    echo "  !gov audit          — run canary checks"
    echo "  !gov report @user   — report compromised account"
  fi
  echo
  echo "To add more operators: ./bootstrap-operator.sh <username>"
fi
