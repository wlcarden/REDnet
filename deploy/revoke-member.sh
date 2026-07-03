#!/usr/bin/env bash
# Revoke a member or bulk-revoke all members vouched by a compromised organizer.
# Locks the MAS account(s), bans from all known rooms, and logs to #vouch-log.
#
# Usage:
#   ./revoke-member.sh @username --reason "compromised"
#   ./revoke-member.sh --minted-by @organizer --reason "organizer compromised"
#   ./revoke-member.sh --minted-by @organizer --after 2026-06-01 --reason "post-compromise"
#
# --minted-by mode: revokes every confirmed member whose vouch traces back to the
# named organizer. With --after, only those vouched after the given date. This is the
# "bulk-revoke-by-mint-time" from DESIGN.md §11.
#
# Requires: jq, stack running, vouch.jsonl exists.
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
txn_id(){ printf 'revoke-%s-%s' "$(date +%s%N)" "$$"; }

TARGET_USER=""
MINTED_BY=""
AFTER=""
REASON=""

while [ $# -gt 0 ]; do
  case "$1" in
    @*)          TARGET_USER="$1"; shift ;;
    --minted-by) MINTED_BY="$2"; shift 2 ;;
    --after)     AFTER="$2"; shift 2 ;;
    --reason)    REASON="$2"; shift 2 ;;
    *)           echo "Usage: $0 @user --reason \"...\" | --minted-by @org [--after DATE] --reason \"...\"" >&2; exit 1 ;;
  esac
done

[ -n "$REASON" ] || { echo "ERR: --reason is required (document why)" >&2; exit 1; }
[ -n "$TARGET_USER" ] || [ -n "$MINTED_BY" ] || { echo "ERR: specify @user or --minted-by @organizer" >&2; exit 1; }

SYS_TOK=$(mas issue-compatibility-token rednet-system REVOKESYS | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
[ -n "${SYS_TOK:-}" ] || { echo "ERR: no system token" >&2; exit 1; }
AUTH="Authorization: Bearer $SYS_TOK"

resolve_alias(){
  curl -s -H "$AUTH" "$ACCESS/_matrix/client/v3/directory/room/%23${1}%3A${REDNET_DOMAIN}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('room_id',''))" 2>/dev/null
}

VOUCH_LOG_ID=$(resolve_alias vouch-log 2>/dev/null)

# Build the list of users to revoke
USERS_TO_REVOKE=()

if [ -n "$TARGET_USER" ]; then
  USERS_TO_REVOKE+=("$TARGET_USER")
elif [ -n "$MINTED_BY" ]; then
  [ -f vouch.jsonl ] || { echo "ERR: vouch.jsonl not found — can't resolve --minted-by" >&2; exit 1; }

  FILTER=".type==\"claimed\" and .voucher==\"$MINTED_BY\""
  [ -n "$AFTER" ] && FILTER="$FILTER and .confirmed_at > \"${AFTER}T00:00:00Z\""

  while IFS= read -r user; do
    [ -n "$user" ] && USERS_TO_REVOKE+=("$user")
  done < <(jq -r "select($FILTER) | .account" vouch.jsonl 2>/dev/null)

  echo "Members vouched by $MINTED_BY${AFTER:+ after $AFTER}: ${#USERS_TO_REVOKE[@]}"
  if [ ${#USERS_TO_REVOKE[@]} -eq 0 ]; then
    echo "  No matching members found."
    exit 0
  fi
  echo "  ${USERS_TO_REVOKE[*]}"
  echo
  read -rp "Revoke all ${#USERS_TO_REVOKE[@]} member(s)? [y/N] " CONFIRM
  [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || { echo "Aborted."; exit 0; }
fi

revoke_one(){
  local user="$1"
  local username
  local tmp="${user#@}"
  local username="${tmp%%:*}"

  echo "Revoking $user..."

  # Lock the MAS account (prevents login)
  mas lock-user "$username" 2>&1 | sed 's/^/  /' || true

  # BAN (not kick) from all known rooms — a ban blocks re-join even from a public
  # room (F11). The MAS lock above is the terminal control; bans force-remove any
  # live session and prevent re-entry in the rooms we can reach.
  local COMMUNITY_ROOMS
  COMMUNITY_ROOMS=(community welcome announcements reference general governance vouch-log)

  # Also check vouch.jsonl for compartment memberships
  if [ -f vouch.jsonl ]; then
    while IFS= read -r slug; do
      [ -n "$slug" ] && COMMUNITY_ROOMS+=("$slug")
    done < <(jq -r 'select(.type=="compartment") | .rooms[]' vouch.jsonl 2>/dev/null | sort -u)
  fi

  local banned=0
  for alias in "${COMMUNITY_ROOMS[@]}"; do
    RID=$(resolve_alias "$alias" 2>/dev/null)
    [ -n "$RID" ] || continue
    RESP=$(curl -s -XPOST "$ACCESS/_matrix/client/v3/rooms/$(enc "$RID")/ban" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "$(jq -n --arg u "$user" --arg r "$REASON" '{user_id:$u, reason:$r}')")
    if echo "$RESP" | grep -qv "errcode"; then
      banned=$((banned + 1))
    fi
  done
  echo "  banned from $banned room(s), MAS account locked"

  # Log to #vouch-log
  if [ -n "$VOUCH_LOG_ID" ]; then
    LOG_BODY=$(jq -n \
      --arg user "$user" \
      --arg reason "$REASON" \
      --arg by "${MINTED_BY:-manual}" \
      --arg ts "$(now_iso)" \
      '{
        msgtype: "org.rednet.member.revoked",
        body: ($user + " revoked: " + $reason),
        "org.rednet.member.revoked": {
          account: $user,
          reason: $reason,
          triggered_by: $by,
          timestamp: $ts
        }
      }')
    curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$VOUCH_LOG_ID")/send/m.room.message/$(txn_id)" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "$LOG_BODY" >/dev/null
  fi

  # Append to local index
  jq -nc \
    --arg user "$user" \
    --arg reason "$REASON" \
    --arg by "${MINTED_BY:-manual}" \
    --arg ts "$(now_iso)" \
    '{type:"revoked", account:$user, reason:$reason, triggered_by:$by, timestamp:$ts}' \
    >> vouch.jsonl
}

for U in "${USERS_TO_REVOKE[@]}"; do
  revoke_one "$U"
  echo
done

echo "DONE: ${#USERS_TO_REVOKE[@]} member(s) revoked."
echo "  Reason: $REASON"
[ -n "$MINTED_BY" ] && echo "  Triggered by: voucher $MINTED_BY compromise"
echo "  Accounts locked in MAS, banned from known rooms, logged to #vouch-log."
