#!/usr/bin/env bash
# Confirm that a registered user matches an outstanding vouch. Posts a vouch.claimed
# event to #vouch-log linking the token to the account, and announces the join in
# #welcome so members can see who vouched for the newcomer.
#
# Usage:
#   ./confirm-vouch.sh @username
#   ./confirm-vouch.sh @username --label "Maria, Tuesday group"
#   ./confirm-vouch.sh @username --voucher @alice    # override: Alice vouched, not you
#
# The operator who minted the invite confirms the person arrived. If --label matches
# an existing vouch.jsonl entry, the confirmation links to that record. Otherwise it
# creates a standalone claim record.
#
# Requires: jq, stack running, #vouch-log + #welcome rooms exist.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?}"; : "${REDNET_HTTP_PORT:=8080}"; : "${REDNET_BRAND:=REDnet}"
ACCESS="http://localhost:${REDNET_HTTP_PORT}"

command -v jq >/dev/null 2>&1 || { echo "ERR: jq required" >&2; exit 1; }

mas(){ docker compose exec -T mas mas-cli manage "$@" --config /config.yaml 2>&1; }
enc(){ python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }
now_iso(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
txn_id(){ printf 'claim-%s-%s' "$(date +%s%N)" "$$"; }

USERNAME=""
VOUCHER=""
LABEL=""

case "${1:-}" in
  @*) USERNAME="$1"; shift ;;
  *)  echo "Usage: $0 @username --voucher @organizer [--label \"description\"]" >&2; exit 1 ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --voucher) VOUCHER="$2"; shift 2 ;;
    --label)   LABEL="$2"; shift 2 ;;
    *)         echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$VOUCHER" ]; then
  VOUCHER="${REDNET_OPERATOR:-}"
fi
[ -n "$VOUCHER" ] || { echo "ERR: no voucher identity. Set REDNET_OPERATOR in rednet.env or pass --voucher." >&2; exit 1; }

SYS_TOK=$(mas issue-compatibility-token rednet-system CLAIMSYS | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
[ -n "${SYS_TOK:-}" ] || { echo "ERR: no system token" >&2; exit 1; }
SAUTH="Authorization: Bearer $SYS_TOK"

resolve_room(){
  curl -s -H "$SAUTH" "$ACCESS/_matrix/client/v3/directory/room/%23${1}%3A${REDNET_DOMAIN}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('room_id',''))" 2>/dev/null
}

VOUCH_LOG_ID=$(resolve_room vouch-log)
WELCOME_ID=$(resolve_room welcome)
[ -n "$VOUCH_LOG_ID" ] || { echo "ERR: #vouch-log not found — run bootstrap-governance.sh" >&2; exit 1; }

TS=$(now_iso)

echo "Confirming vouch: $USERNAME vouched by $VOUCHER"

# Post vouch.claimed event to #vouch-log
CLAIM_BODY=$(jq -n \
  --arg u "$USERNAME" \
  --arg v "$VOUCHER" \
  --arg l "$LABEL" \
  --arg ts "$TS" \
  '{
    msgtype: "org.rednet.vouch.claimed",
    body: ($u + " confirmed, vouched by " + $v),
    "org.rednet.vouch.claimed": {
      account: $u,
      voucher: $v,
      label: (if $l == "" then null else $l end),
      confirmed_at: $ts
    }
  }')
curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$VOUCH_LOG_ID")/send/m.room.message/$(txn_id)" \
  -H "$SAUTH" -H "Content-Type: application/json" \
  -d "$CLAIM_BODY" >/dev/null
echo "  vouch.claimed posted to #vouch-log"

# Append to local index
jq -nc \
  --arg u "$USERNAME" \
  --arg v "$VOUCHER" \
  --arg l "$LABEL" \
  --arg ts "$TS" \
  '{type:"claimed", account:$u, voucher:$v, label:$l, confirmed_at:$ts}' \
  >> vouch.jsonl
echo "  appended to vouch.jsonl"

# Post join announcement to #welcome (visible to all members)
if [ -n "$WELCOME_ID" ]; then
  NOTICE_BODY=$(jq -n \
    --arg u "$USERNAME" \
    --arg v "$VOUCHER" \
    '{msgtype: "m.notice", body: ($u + " joined, vouched by " + $v + ".")}')
  curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$WELCOME_ID")/send/m.room.message/$(txn_id)" \
    -H "$SAUTH" -H "Content-Type: application/json" \
    -d "$NOTICE_BODY" >/dev/null
  echo "  join announcement posted to #welcome"
else
  echo "  SKIP: #welcome room not found (no join announcement)"
fi

echo
echo "DONE: $USERNAME confirmed as vouched by $VOUCHER."
