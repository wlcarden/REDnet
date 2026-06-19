#!/usr/bin/env bash
# Bootstrap the group-calls module (LiveKit SFU + JWT auth service).
# Run AFTER setup.sh. Generates secrets, renders configs, starts the calls profile.
#
# Usage: ./bootstrap-calls.sh
# Prerequisites: stack running (setup.sh completed), rednet.env sourced.
set -euo pipefail
cd "$(dirname "$0")"
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?set REDNET_DOMAIN in rednet.env}"
: "${REDNET_PUBLIC_BASE:=http://localhost:${REDNET_HTTP_PORT:-8080}}"

SECRETS_FILE="livekit/livekit.secrets.yaml"
ENV_FILE="livekit/.env"

echo "=== REDnet group calls bootstrap ==="

# 1. Generate LiveKit API key + secret (if not already present)
if [ -f "$SECRETS_FILE" ]; then
  echo "LiveKit secrets already exist at $SECRETS_FILE"
else
  LK_API_KEY="API$(openssl rand -hex 8)"
  LK_API_SECRET="$(openssl rand -hex 32)"

  cat > "$SECRETS_FILE" <<EOF
keys:
  ${LK_API_KEY}: ${LK_API_SECRET}
EOF
  chmod 600 "$SECRETS_FILE"
  echo "Generated LiveKit API keys -> $SECRETS_FILE"

  cat > "$ENV_FILE" <<EOF
LIVEKIT_API_KEY=${LK_API_KEY}
LIVEKIT_API_SECRET=${LK_API_SECRET}
LIVEKIT_URL=ws://livekit:7880
EOF
  chmod 600 "$ENV_FILE"
  echo "Generated JWT service env -> $ENV_FILE"
fi

# 2. Render the well-known call discovery
CALL_WELLKNOWN="caddy/well-known-call.json"
cat > "$CALL_WELLKNOWN" <<EOF
{
  "type": "livekit",
  "livekit_service_url": "${REDNET_PUBLIC_BASE}/_livekit/jwt"
}
EOF
echo "Rendered call discovery -> $CALL_WELLKNOWN"

# 3. Start the calls profile
echo "Starting calls profile..."
docker compose --profile calls up -d

echo ""
echo "=== Group calls module running ==="
echo "LiveKit SFU:    ws://livekit:7880 (internal)"
echo "JWT service:    ${REDNET_PUBLIC_BASE}/_livekit/jwt"
echo "Well-known:     ${REDNET_PUBLIC_BASE}/.well-known/element/call.json"
echo ""
echo "Element Web must be rebuilt with call support enabled."
echo "Re-run: ./element-web/build.sh"
