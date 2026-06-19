#!/usr/bin/env bash
# Generate a REDnet invite: mint a single-use MAS registration token, produce a
# QR code, and output a printable branded card (standalone HTML).
#
# Usage:
#   ./generate-invite.sh                     # mint + card (default)
#   ./generate-invite.sh --token TOKEN       # card for an existing token
#   ./generate-invite.sh --batch 5           # mint 5 tokens + 5 cards
#
# Requires: qrencode (apt install qrencode), stack running, rednet.env sourced.
# Output: invite cards in deploy/invites/ (one HTML file per token).
set -uo pipefail
cd "$(dirname "$0")" || exit 1
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?set REDNET_DOMAIN in rednet.env}"
: "${REDNET_BRAND:=REDnet}"
: "${REDNET_PUBLIC_BASE:=https://${REDNET_DOMAIN}}"

JOIN_URL_BASE="${REDNET_PUBLIC_BASE}/join"
OUTDIR="invites"
mkdir -p "$OUTDIR"

mas_mint() {
  docker compose exec -T mas mas-cli manage \
    issue-user-registration-token --config /config.yaml 2>&1 \
    | grep -oP '(?<=token: )\S+'
}

generate_card() {
  local TOKEN="$1"
  local JOIN_URL="${JOIN_URL_BASE}#${TOKEN}"
  local QR_SVG
  local OUTFILE="${OUTDIR}/invite-${TOKEN}.html"

  if ! command -v qrencode >/dev/null 2>&1; then
    echo "ERR: qrencode not found. Install with: apt install qrencode" >&2
    return 1
  fi

  QR_SVG=$(qrencode -t SVG -o - -l M "$JOIN_URL" 2>/dev/null)
  if [ -z "$QR_SVG" ]; then
    echo "ERR: qrencode failed for token ${TOKEN}" >&2
    return 1
  fi

  # Strip XML declaration and DOCTYPE from qrencode SVG output, keep just the <svg> element
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
  .card-left svg { width: 100px; height: 100px; }
  .qr-wrapper { background: #fff; padding: 6px; border-radius: 6px; display: inline-block; }
  .qr-wrapper svg { width: 88px; height: 88px; display: block; }
  .card-right { flex: 1; min-width: 0; }
  .brand {
    font-size: 18px; font-weight: 700; letter-spacing: -0.5px; margin-bottom: 6px;
  }
  .brand-red { color: #E5484D; }
  .brand-gray { color: #8B8D98; }
  .instruction {
    font-size: 10px; color: #8B8D98; line-height: 1.4; margin-bottom: 8px;
  }
  .token-label {
    font-size: 8px; font-weight: 600; letter-spacing: 1px;
    text-transform: uppercase; color: #62646C; margin-bottom: 2px;
  }
  .token-value {
    font-family: 'SF Mono', 'Fira Code', monospace;
    font-size: 9px; color: #ECEDEE; letter-spacing: 0.3px;
    word-break: break-all;
  }
  .url {
    font-size: 8px; color: #62646C; margin-top: 6px;
    word-break: break-all;
  }
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
TOKEN=""
BATCH=0

while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --batch) BATCH="$2"; shift 2 ;;
    *) echo "Usage: $0 [--token TOKEN] [--batch N]" >&2; exit 1 ;;
  esac
done

if [ -n "$TOKEN" ]; then
  echo "Generating card for token: ${TOKEN}"
  FILE=$(generate_card "$TOKEN")
  echo "  -> ${FILE}"
elif [ "$BATCH" -gt 0 ]; then
  echo "Minting ${BATCH} tokens and generating cards..."
  for i in $(seq 1 "$BATCH"); do
    T=$(mas_mint)
    if [ -z "$T" ]; then
      echo "  ERR: failed to mint token #${i}" >&2
      continue
    fi
    FILE=$(generate_card "$T")
    echo "  ${i}/${BATCH}: ${T} -> ${FILE}"
  done
else
  echo "Minting registration token..."
  TOKEN=$(mas_mint)
  if [ -z "$TOKEN" ]; then
    echo "ERR: failed to mint token. Is the stack running?" >&2
    exit 1
  fi
  echo "Token: ${TOKEN}"
  FILE=$(generate_card "$TOKEN")
  echo "Card:  ${FILE}"
  echo
  echo "Join URL: ${JOIN_URL_BASE}#${TOKEN}"
  echo "Open ${FILE} in a browser and print it, or share the URL."
fi
