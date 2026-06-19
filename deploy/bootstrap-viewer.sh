#!/usr/bin/env bash
# Bootstrap the matrix-viewer public preview module.
# ⚠️ SECURITY TRADEOFF: matrix-viewer requires world_readable rooms, which CANNOT be E2EE.
# Only expose intentionally public, non-sensitive rooms (e.g. a public lobby or announcements).
# NEVER expose member rooms.
#
# Usage: ./bootstrap-viewer.sh [ROOM_ALIAS]
# Example: ./bootstrap-viewer.sh "#public-lobby:rednet.example"
set -euo pipefail
cd "$(dirname "$0")"
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?set REDNET_DOMAIN in rednet.env}"
: "${REDNET_PUBLIC_BASE:=http://localhost:${REDNET_HTTP_PORT:-8080}}"

ROOM_ALIAS="${1:-}"

echo "=== REDnet matrix-viewer bootstrap ==="
echo ""
echo "⚠️  SECURITY WARNING"
echo "matrix-viewer exposes room content WITHOUT authentication."
echo "world_readable rooms CANNOT be end-to-end encrypted."
echo "Only use this for intentionally public, non-sensitive content."
echo ""

if [ -z "$ROOM_ALIAS" ]; then
  echo "Usage: $0 '#room-alias:${REDNET_DOMAIN}'"
  echo ""
  echo "The room must be created with:"
  echo "  - history_visibility: world_readable"
  echo "  - join_rules: public"
  echo "  - encryption: DISABLED (world_readable rooms cannot be E2EE)"
  echo ""
  echo "No rooms are exposed by default. Specify a room alias to continue."
  exit 1
fi

echo "Exposing room: ${ROOM_ALIAS}"
echo "Public URL: ${REDNET_PUBLIC_BASE}/viewer/"
echo ""

docker compose --profile viewer up -d

echo "=== matrix-viewer running ==="
echo "Viewer URL: ${REDNET_PUBLIC_BASE}/viewer/"
echo ""
echo "To create a world_readable room (from synapse-admin or API):"
echo "  1. Create a room with encryption DISABLED"
echo "  2. Set history_visibility to world_readable"
echo "  3. Set join_rules to public"
echo "  4. The room will appear in the viewer at its alias"
