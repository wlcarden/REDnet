#!/usr/bin/env bash
# Shared API_URL detection for bootstrap scripts.
# Source this after loading rednet.env. Sets API_URL to where Synapse's C-S API is reachable:
#   - Two-host production (docker-compose.wg.yml exists): Synapse on the WG interface directly
#   - Everything else (dev, single-host): Caddy on localhost:$REDNET_HTTP_PORT fronts everything
: "${REDNET_HTTP_PORT:=8080}"
ROLE="${REDNET_ROLE:-core}"

if [ "$ROLE" = "core" ] && [ -f "$(dirname "${BASH_SOURCE[0]:-$0}")/docker-compose.wg.yml" ]; then
  _WG_IP=$(ip -4 addr show wg0 2>/dev/null | grep -oP 'inet \K[\d.]+' || true)
  if [ -n "$_WG_IP" ]; then
    API_URL="http://${_WG_IP}:8008"
  else
    API_URL="http://localhost:8008"
  fi
else
  API_URL="http://localhost:${REDNET_HTTP_PORT}"
fi
