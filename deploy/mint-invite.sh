#!/usr/bin/env bash
# Mint an attributed REDnet invite: create a registration token, record the vouch
# in #vouch-log + vouch.jsonl, and produce a printable QR card.
#
# Usage:
#   ./mint-invite.sh --label "Maria, Tuesday group"
#   ./mint-invite.sh --label "workshop batch" --batch 5
#   ./mint-invite.sh --label "existing" --token TOKEN
#   ./mint-invite.sh --label "ops recruit" --compartment ops-team
#   ./mint-invite.sh --label "for Bob's contact" --voucher @bob   # override: Bob is vouching
#
# The voucher defaults to REDNET_OPERATOR (set in rednet.env or your shell). Every
# invite is attributed: who minted it, who it's for, and when. The vouch is recorded
# as an org.rednet.vouch event in #vouch-log (append-only, E2EE) and indexed locally
# in vouch.jsonl. This is the coercion canary from DESIGN.md §11: a burst of mints
# by one organizer is a visible anomaly.
#
# Requires: jq, qrencode, stack running, #vouch-log room exists (bootstrap-governance.sh).
set -uo pipefail
cd "$(dirname "$0")" || exit 1
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?set REDNET_DOMAIN in rednet.env}"
: "${REDNET_BRAND:=REDnet}"
: "${REDNET_HTTP_PORT:=8080}"
: "${REDNET_PUBLIC_BASE:=https://${REDNET_DOMAIN}}"

. ./lib-access.sh
ACCESS="$API_URL"
OUTDIR="invites"
mkdir -p "$OUTDIR"

for cmd in jq qrencode python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERR: $cmd not found" >&2; exit 1; }
done

mas(){ docker compose exec -T mas mas-cli manage "$@" --config /config.yaml 2>&1; }
enc(){ python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }
sha256(){ printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
now_iso(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
txn_id(){ printf 'vouch-%s-%s' "$(date +%s%N)" "$$"; }

get_vouch_log_id(){
  curl -s -H "$1" "$ACCESS/_matrix/client/v3/directory/room/%23vouch-log%3A${REDNET_DOMAIN}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('room_id',''))" 2>/dev/null
}

mas_mint(){
  # Single-use (--usage-limit 1) + expiring, so a leaked token can be redeemed
  # once and then goes inert. MAS defaults usage_limit to UNLIMITED when the flag
  # is omitted — one leaked/coerced card could then register many accounts against
  # a single vouch hash, collapsing the coercion canary. Must match the in-client
  # mint-svc, which sets usage_limit:1 (mint-svc/mint_svc.py).
  mas issue-user-registration-token --usage-limit 1 --expires-in "$EXPIRES_IN" --config /config.yaml 2>&1 \
    | grep -oP '(?<=token: )\S+'
}

post_vouch_event(){
  local auth="$1" room_id="$2" token_hash="$3" voucher="$4" label="$5" compartment="$6" ts="$7"
  local body
  body=$(jq -n \
    --arg th "$token_hash" \
    --arg v "$voucher" \
    --arg l "$label" \
    --arg c "$compartment" \
    --arg ts "$ts" \
    '{
      msgtype: "org.rednet.vouch",
      body: ("Invite minted by " + $v + " for " + $l),
      "org.rednet.vouch": {
        token_hash: $th,
        voucher: $v,
        label: $l,
        compartment: (if $c == "" then null else $c end),
        timestamp: $ts
      }
    }')
  # Judge success by the returned event_id, not curl's exit code: `curl -s` exits 0
  # even on an HTTP 5xx, so discarding the body would hide a failed vouch-log post.
  local resp eid
  resp=$(curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$room_id")/send/m.room.message/$(txn_id)" \
    -H "$auth" -H "Content-Type: application/json" \
    -d "$body")
  eid=$(printf '%s' "$resp" | jq -r '.event_id // empty' 2>/dev/null)
  [ -n "$eid" ]
}

append_local_index(){
  local token_hash="$1" voucher="$2" label="$3" compartment="$4" ts="$5"
  jq -nc \
    --arg th "$token_hash" \
    --arg v "$voucher" \
    --arg l "$label" \
    --arg c "$compartment" \
    --arg ts "$ts" \
    '{type:"vouch", token_hash:$th, voucher:$v, label:$l, compartment:$c, timestamp:$ts}' \
    >> vouch.jsonl
}

generate_card(){
  local TOKEN="$1" VOUCHER="$2" LABEL="$3"
  local ext="html"; [ "$FORMAT" = "plain" ] && ext="txt"
  # Name the file by the token HASH, not the token: the filename is not a secret,
  # so `ls invites/` and any printed path no longer leak a live token (F26).
  local id; id=$(sha256 "$TOKEN"); id=${id:0:16}
  local OUTFILE="${OUTDIR}/invite-${id}.${ext}"
  # Shared renderer (also used by the in-client minting endpoint) so both paths
  # emit identical cards. Token reaches only this local file, never Matrix.
  python3 "$(dirname "$0")/render-invite-card.py" --format "$FORMAT" \
    --token "$TOKEN" --domain "$REDNET_DOMAIN" --brand "$REDNET_BRAND" \
    --label "$LABEL" --voucher "$VOUCHER" --expires "$EXPIRES_DATE" \
    --public-base "$REDNET_PUBLIC_BASE" > "$OUTFILE" || { echo "ERR: card render failed" >&2; return 1; }
  echo "$OUTFILE"
  return 0
}

# --- CLI ---
VOUCHER=""
LABEL=""
TOKEN=""
BATCH=0
COMPARTMENT=""
FORMAT="print-card"
EXPIRES_IN=$((7 * 24 * 3600))   # 7 days — an unused leaked token goes inert

while [ $# -gt 0 ]; do
  case "$1" in
    --voucher)     VOUCHER="$2"; shift 2 ;;
    --label)       LABEL="$2"; shift 2 ;;
    --token)       TOKEN="$2"; shift 2 ;;
    --batch)       BATCH="$2"; shift 2 ;;
    --compartment) COMPARTMENT="$2"; shift 2 ;;
    --format)      FORMAT="$2"; shift 2 ;;
    --expires-in)  EXPIRES_IN="$2"; shift 2 ;;
    *) echo "Usage: $0 --voucher @user --label \"description\" [--batch N] [--token TOKEN] [--compartment NAME] [--format print-card|wallet|half-sheet|plain] [--expires-in SECONDS]" >&2; exit 1 ;;
  esac
done

case "$FORMAT" in print-card|wallet|half-sheet|plain) ;; *)
  echo "ERR: --format must be one of: print-card, wallet, half-sheet, plain" >&2; exit 1 ;; esac

# Clamp expiry to the same [60s, 30d] window the in-client mint-svc enforces
# (mint_svc.py MAX_EXPIRES_IN), so the CLI can't mint a near-permanent token that
# defeats the "unused leaked token goes inert" property.
MAX_EXPIRES_IN=$((30 * 24 * 3600))
if ! printf '%s' "$EXPIRES_IN" | grep -qE '^[0-9]+$'; then
  echo "ERR: --expires-in must be a positive integer (seconds)" >&2; exit 1
fi
[ "$EXPIRES_IN" -lt 60 ] && EXPIRES_IN=60
[ "$EXPIRES_IN" -gt "$MAX_EXPIRES_IN" ] && EXPIRES_IN=$MAX_EXPIRES_IN

# Cap batch to the same ceiling the in-client path enforces (mint_endpoint.py
# MAX_BATCH=25) and reject non-numeric input, so the CLI isn't a weaker mass-mint
# path than the dashboard. The cap is logged, never silently applied.
MAX_BATCH=25
if [ "$BATCH" != "0" ]; then
  if ! printf '%s' "$BATCH" | grep -qE '^[0-9]+$'; then
    echo "ERR: --batch must be a positive integer" >&2; exit 1
  fi
  if [ "$BATCH" -gt "$MAX_BATCH" ]; then
    echo "WARN: --batch $BATCH exceeds the $MAX_BATCH cap (matches the in-client limit); minting $MAX_BATCH" >&2
    BATCH=$MAX_BATCH
  fi
fi

# Human date shown on the card. --token (pre-existing) has an unknown/other expiry, so omit it there.
if [ -n "$TOKEN" ]; then EXPIRES_DATE=""; else EXPIRES_DATE=$(date -u -d "+${EXPIRES_IN} seconds" +%Y-%m-%d 2>/dev/null || echo ""); fi

if [ -z "$VOUCHER" ]; then
  VOUCHER="${REDNET_OPERATOR:-}"
fi
[ -n "$VOUCHER" ] || { echo "ERR: no voucher identity. Set REDNET_OPERATOR in rednet.env or pass --voucher." >&2; exit 1; }
[ -n "$LABEL" ]   || { echo "ERR: --label is required (who is this invite for?)" >&2; exit 1; }

SYS_TOK=$(mas issue-compatibility-token rednet-system MINTSYS | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
[ -n "${SYS_TOK:-}" ] || { echo "ERR: no system token — is the stack running?" >&2; exit 1; }
SAUTH="Authorization: Bearer $SYS_TOK"

VOUCH_LOG_ID=$(get_vouch_log_id "$SAUTH")
[ -n "$VOUCH_LOG_ID" ] || { echo "ERR: #vouch-log room not found — run bootstrap-governance.sh first" >&2; exit 1; }

mint_and_record(){
  local token="$1"
  local minted=false
  if [ -z "$token" ]; then
    token=$(mas_mint)
    [ -n "$token" ] || { echo "ERR: failed to mint token" >&2; return 1; }
    minted=true
  fi

  local ts
  ts=$(now_iso)
  local hash
  hash=$(sha256 "$token")

  local vouch_ok=true
  post_vouch_event "$SAUTH" "$VOUCH_LOG_ID" "$hash" "$VOUCHER" "$LABEL" "$COMPARTMENT" "$ts" || vouch_ok=false
  append_local_index "$hash" "$VOUCHER" "$LABEL" "$COMPARTMENT" "$ts"

  local card
  card=$(generate_card "$token" "$VOUCHER" "$LABEL")

  # Don't echo the raw token: it lives in the card the operator hands off, so a
  # stdout copy is redundant residue in scrollback / tmux / CI logs (F34). The
  # hash prefix is enough to correlate with #vouch-log.
  if $minted; then
    echo "  minted: single-use invite (${hash:0:12}…)"
  else
    echo "  token:  pre-existing (${hash:0:12}…)"
  fi
  echo "  vouch:  $VOUCHER → \"$LABEL\""
  echo "  card:   $card"
  echo "          ⚠ contains a LIVE token — after handing it off: shred -u \"$card\"  (F26)"
  if ! $vouch_ok; then
    echo "  ⚠ PROVENANCE NOT RECORDED: the #vouch-log event did not post." >&2
    echo "    Recorded locally in vouch.jsonl only — the room-visible coercion canary is blind to this invite." >&2
    echo "    Re-post the vouch before distributing this card, or treat it as unattributed." >&2
  fi
}

echo "Voucher: $VOUCHER"
echo "Label:   $LABEL"
[ -n "$COMPARTMENT" ] && echo "Compartment: $COMPARTMENT"
echo

if [ -n "$TOKEN" ]; then
  echo "Recording vouch for existing token..."
  mint_and_record "$TOKEN"
elif [ "$BATCH" -gt 0 ]; then
  echo "Minting $BATCH attributed invites..."
  for i in $(seq 1 "$BATCH"); do
    echo "[$i/$BATCH]"
    mint_and_record ""
  done
else
  echo "Minting attributed invite..."
  mint_and_record ""
fi

echo
echo "Vouches recorded in #vouch-log + vouch.jsonl."
echo "Open the card in a browser and print, or share the join URL."
