#!/usr/bin/env bash
# Build the REDnet Element Web soft fork. HEAVY (full webpack build) — run at deploy time.
# Renders config.json from rednet.env, then builds the `element` image via Compose.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1   # -> deploy/
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?}"; : "${REDNET_BRAND:=REDnet}"; : "${ELEMENT_VERSION:=v1.11.86}"
: "${REDNET_PUBLIC_BASE:=https://${REDNET_DOMAIN}}"
: "${REDNET_CALLS_ENABLED:=false}"
say(){ printf '\n=== %s ===\n' "$*"; }

say "render element-web/config.json + home.html (homeserver + brand from rednet.env)"
RENDER_SED=(
  -e "s#__REDNET_DOMAIN__#${REDNET_DOMAIN}#g"
  -e "s#__REDNET_BRAND__#${REDNET_BRAND}#g"
  -e "s#__REDNET_PUBLIC_BASE__#${REDNET_PUBLIC_BASE}#g"
  -e "s#__REDNET_CALLS_ENABLED__#${REDNET_CALLS_ENABLED}#g"
)
sed "${RENDER_SED[@]}" element-web/config.json.template > element-web/config.json
sed "${RENDER_SED[@]}" element-web/branding/home.html.template > element-web/branding/home.html
echo "config.json -> ${REDNET_PUBLIC_BASE}, brand=${REDNET_BRAND}, calls=${REDNET_CALLS_ENABLED}, element=${ELEMENT_VERSION}"
echo "home.html   -> rendered (domain=${REDNET_DOMAIN})"

say "build (compose profile 'web')"
ELEMENT_VERSION="$ELEMENT_VERSION" docker compose --profile web build element
echo
echo "Built. Start: docker compose --profile web up -d element"
echo "The front (Caddy) reverse-proxies / to this container. Validate silent onboarding by logging"
echo "in on a fresh account: NO recovery-key dialog should appear and cross-signing should be green."
