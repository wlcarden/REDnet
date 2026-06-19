#!/usr/bin/env bash
# Mint an attributed REDnet invite: create a registration token, record the vouch
# in #vouch-log + vouch.jsonl, and produce a printable QR card.
#
# Usage:
#   ./mint-invite.sh --voucher @alice --label "Maria, Tuesday group"
#   ./mint-invite.sh --voucher @alice --label "workshop batch" --batch 5
#   ./mint-invite.sh --voucher @alice --label "existing" --token TOKEN
#   ./mint-invite.sh --voucher @alice --label "ops recruit" --compartment ops-team
#
# Every invite is attributed: who minted it, who it's for, and when. The vouch is
# recorded as an org.rednet.vouch event in #vouch-log (append-only, E2EE) and
# indexed locally in vouch.jsonl. This is the coercion canary from DESIGN.md §11:
# a burst of mints by one organizer is a visible anomaly.
#
# Requires: jq, qrencode, stack running, #vouch-log room exists (bootstrap-governance.sh).
set -uo pipefail
cd "$(dirname "$0")" || exit 1
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?set REDNET_DOMAIN in rednet.env}"
: "${REDNET_BRAND:=REDnet}"
: "${REDNET_HTTP_PORT:=8080}"
: "${REDNET_PUBLIC_BASE:=https://${REDNET_DOMAIN}}"

ACCESS="http://localhost:${REDNET_HTTP_PORT}"
JOIN_URL_BASE="${REDNET_PUBLIC_BASE}/join"
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
  mas issue-user-registration-token --config /config.yaml 2>&1 \
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
  curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$room_id")/send/m.room.message/$(txn_id)" \
    -H "$auth" -H "Content-Type: application/json" \
    -d "$body" >/dev/null
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
  local JOIN_URL="${JOIN_URL_BASE}#${TOKEN}"
  local QR_SVG
  local OUTFILE="${OUTDIR}/invite-${TOKEN}.html"

  QR_SVG=$(qrencode -t SVG -o - -l M "$JOIN_URL" 2>/dev/null)
  [ -n "$QR_SVG" ] || { echo "ERR: qrencode failed" >&2; return 1; }
  QR_SVG=$(echo "$QR_SVG" | sed '1,/^<svg/{ /^<svg/!d }')

  cat > "$OUTFILE" <<CARD_EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${REDNET_BRAND} Invite</title>
<style>
  @media print {
    @page { size: 3.5in 2.25in; margin: 0; }
    body { margin: 0; }
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: Inter, system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif;
    background: #111316;
    display: flex; align-items: center; justify-content: center;
    min-height: 100vh; padding: 24px;
  }
  .card {
    width: 3.5in; height: 2.25in; background: #16181B;
    border-radius: 12px; padding: 16px 20px;
    border: 1px solid rgba(255,255,255,0.06);
    display: flex; gap: 16px; align-items: center;
    box-shadow: 0 4px 16px rgba(0,0,0,0.3);
    overflow: hidden;
  }
  .card-left { flex: 0 0 auto; text-align: center; }
  .qr-wrapper { background: #fff; padding: 6px; border-radius: 6px; display: inline-block; }
  .qr-wrapper svg { width: 88px; height: 88px; display: block; }
  .card-right { flex: 1; min-width: 0; }
  .brand { font-size: 18px; font-weight: 700; letter-spacing: -0.5px; margin-bottom: 6px; }
  .brand-red { color: #E5484D; }
  .brand-gray { color: #8B8D98; }
  .instruction { font-size: 10px; color: #8B8D98; line-height: 1.4; margin-bottom: 8px; }
  .token-label { font-size: 8px; font-weight: 600; letter-spacing: 1px; text-transform: uppercase; color: #62646C; margin-bottom: 2px; }
  .token-value { font-family: 'SF Mono', 'Fira Code', monospace; font-size: 9px; color: #ECEDEE; letter-spacing: 0.3px; word-break: break-all; }
  .url { font-size: 8px; color: #62646C; margin-top: 6px; word-break: break-all; }
  .vouch { font-size: 8px; color: #62646C; margin-top: 4px; font-style: italic; }
</style>
</head>
<body>
<div class="card">
  <div class="card-left">
    <div class="qr-wrapper">
      ${QR_SVG}
    </div>
  </div>
  <div class="card-right">
    <div class="brand">
      <span class="brand-red">RED</span><span class="brand-gray">net</span>
    </div>
    <div class="instruction">
      Scan the QR code or visit the URL below to join.
      Your invite is single-use.
    </div>
    <div class="token-label">Token</div>
    <div class="token-value">${TOKEN}</div>
    <div class="url">${JOIN_URL}</div>
  </div>
</div>
</body>
</html>
CARD_EOF
  echo "$OUTFILE"
}

# --- CLI ---
VOUCHER=""
LABEL=""
TOKEN=""
BATCH=0
COMPARTMENT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --voucher)     VOUCHER="$2"; shift 2 ;;
    --label)       LABEL="$2"; shift 2 ;;
    --token)       TOKEN="$2"; shift 2 ;;
    --batch)       BATCH="$2"; shift 2 ;;
    --compartment) COMPARTMENT="$2"; shift 2 ;;
    *) echo "Usage: $0 --voucher @user --label \"description\" [--batch N] [--token TOKEN] [--compartment NAME]" >&2; exit 1 ;;
  esac
done

[ -n "$VOUCHER" ] || { echo "ERR: --voucher is required (who is vouching for this person?)" >&2; exit 1; }
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

  post_vouch_event "$SAUTH" "$VOUCH_LOG_ID" "$hash" "$VOUCHER" "$LABEL" "$COMPARTMENT" "$ts"
  append_local_index "$hash" "$VOUCHER" "$LABEL" "$COMPARTMENT" "$ts"

  local card
  card=$(generate_card "$token" "$VOUCHER" "$LABEL")

  if $minted; then
    echo "  minted: $token"
  else
    echo "  token:  $token (pre-existing)"
  fi
  echo "  vouch:  $VOUCHER → \"$LABEL\" (${hash:0:12}...)"
  echo "  card:   $card"
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
