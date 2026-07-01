#!/usr/bin/env bash
# Verify security hardening claims against a RUNNING instance.
# Checks that config-level security properties are actually enforced at runtime.
#
# Usage: ./verify-hardening.sh
# Requires: stack running, jq, curl.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?}"
: "${REDNET_HTTP_PORT:=8080}"
. ./lib-access.sh
ACCESS="$API_URL"

PASS=0
FAIL=0
WARN=0

ok()   { printf "  \033[0;32m✓\033[0m %s\n" "$*"; PASS=$((PASS + 1)); }
fail() { printf "  \033[0;31m✗\033[0m %s\n" "$*"; FAIL=$((FAIL + 1)); }
warn() { printf "  \033[1;33m⚠\033[0m %s\n" "$*"; WARN=$((WARN + 1)); }

enc(){ python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }

SYS_TOK=$(docker compose exec -T mas mas-cli manage issue-compatibility-token rednet-system VERIFY 2>/dev/null \
  | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
if [ -z "${SYS_TOK:-}" ]; then
  echo "ERROR: could not mint system token — is the stack running?" >&2
  exit 1
fi
AUTH="Authorization: Bearer $SYS_TOK"

echo "Verifying hardening against ${API_URL} (domain: ${REDNET_DOMAIN})"
echo

# ── 1. Federation disabled ──────────────────────────────────────────────────
echo "=== Federation ==="
FED_RESP=$(curl -sf "${ACCESS}/_matrix/federation/v1/version" 2>/dev/null || true)
if [ -z "$FED_RESP" ]; then
  ok "federation endpoint not reachable (expected)"
else
  FED_ERR=$(echo "$FED_RESP" | jq -r '.errcode // empty' 2>/dev/null)
  if [ "$FED_ERR" = "M_UNAUTHORIZED" ] || [ "$FED_ERR" = "M_FORBIDDEN" ]; then
    ok "federation endpoint returns $FED_ERR (blocked)"
  elif echo "$FED_RESP" | jq -e '.server' >/dev/null 2>&1; then
    fail "federation endpoint is RESPONDING — federation may not be disabled"
  else
    ok "federation endpoint returned non-federation response"
  fi
fi

FED_WK=$(curl -sf "${ACCESS}/.well-known/matrix/server" 2>/dev/null || true)
if [ -z "$FED_WK" ]; then
  ok "no .well-known/matrix/server (federation discovery disabled)"
else
  fail ".well-known/matrix/server exists — federation may be discoverable"
fi

# ── 2. Guest access disabled ────────────────────────────────────────────────
echo
echo "=== Guest Access ==="
GUEST_RESP=$(curl -sf -XPOST "${ACCESS}/_matrix/client/v3/register" \
  -H "Content-Type: application/json" \
  -d '{"kind":"guest"}' 2>/dev/null || true)
GUEST_ERR=$(echo "$GUEST_RESP" | jq -r '.errcode // empty' 2>/dev/null)
if [ "$GUEST_ERR" = "M_GUEST_ACCESS_FORBIDDEN" ] || [ "$GUEST_ERR" = "M_FORBIDDEN" ]; then
  ok "guest registration forbidden"
elif [ "$GUEST_ERR" = "M_UNKNOWN" ]; then
  ok "guest registration rejected ($GUEST_ERR)"
elif echo "$GUEST_RESP" | jq -e '.user_id' >/dev/null 2>&1; then
  fail "guest registration SUCCEEDED — guest access is enabled"
else
  ok "guest registration rejected (${GUEST_ERR:-no response})"
fi

# ── 3. Password auth disabled (MAS delegation) ──────────────────────────────
echo
echo "=== MAS Delegation ==="
LOGIN_RESP=$(curl -sf "${ACCESS}/_matrix/client/v3/login" 2>/dev/null || true)
PW_FLOW=$(echo "$LOGIN_RESP" | jq '[.flows[]? | select(.type == "m.login.password")] | length' 2>/dev/null)
SSO_FLOW=$(echo "$LOGIN_RESP" | jq '[.flows[]? | select(.type == "m.login.sso")] | length' 2>/dev/null)
if [ "${PW_FLOW:-0}" = "0" ]; then
  ok "m.login.password flow not advertised"
else
  fail "m.login.password flow IS advertised — password_config may not be disabled"
fi
if [ "${SSO_FLOW:-0}" != "0" ]; then
  ok "m.login.sso flow active (MAS OIDC delegation)"
else
  warn "m.login.sso flow not found (check MAS delegation config)"
fi

# ── 4. E2EE on all community rooms ──────────────────────────────────────────
echo
echo "=== Room Encryption ==="
for alias in community welcome announcements reference general governance vouch-log; do
  RID=$(curl -sf -H "$AUTH" "${ACCESS}/_matrix/client/v3/directory/room/%23${alias}%3A${REDNET_DOMAIN}" 2>/dev/null \
    | jq -r '.room_id // empty' 2>/dev/null)
  if [ -z "$RID" ]; then
    warn "#${alias} — room not found (skip)"
    continue
  fi
  ENC_STATE=$(curl -sf -H "$AUTH" \
    "${ACCESS}/_matrix/client/v3/rooms/$(enc "$RID")/state/m.room.encryption/" 2>/dev/null || true)
  ENC_ALG=$(echo "$ENC_STATE" | jq -r '.algorithm // empty' 2>/dev/null)
  if [ "$ENC_ALG" = "m.megolm.v1.aes-sha2" ]; then
    ok "#${alias} — E2EE (megolm)"
  elif [ -n "$ENC_ALG" ]; then
    warn "#${alias} — encrypted with ${ENC_ALG} (expected megolm)"
  else
    fail "#${alias} — NOT ENCRYPTED"
  fi
done

GOV_BOT_RID=$(curl -sf -H "$AUTH" "${ACCESS}/_matrix/client/v3/directory/room/%23gov-bot%3A${REDNET_DOMAIN}" 2>/dev/null \
  | jq -r '.room_id // empty' 2>/dev/null)
if [ -n "$GOV_BOT_RID" ]; then
  GOV_ENC=$(curl -sf -H "$AUTH" \
    "${ACCESS}/_matrix/client/v3/rooms/$(enc "$GOV_BOT_RID")/state/m.room.encryption/" 2>/dev/null || true)
  GOV_ALG=$(echo "$GOV_ENC" | jq -r '.algorithm // empty' 2>/dev/null)
  if [ -z "$GOV_ALG" ]; then
    ok "#gov-bot — unencrypted (correct: bot cannot decrypt)"
  else
    fail "#gov-bot — encrypted with ${GOV_ALG} (should be unencrypted for bot access)"
  fi
fi

# ── 5. Retention configured ─────────────────────────────────────────────────
echo
echo "=== Retention ==="
HS_YAML=$(docker compose exec -T synapse sh -c 'cat /data/homeserver.yaml' 2>/dev/null)
RET_ENABLED=$(echo "$HS_YAML" | python3 -c "
import sys, yaml
c = yaml.safe_load(sys.stdin)
r = c.get('retention', {})
print('true' if r.get('enabled') else 'false')
" 2>/dev/null)
if [ "$RET_ENABLED" = "true" ]; then
  ok "retention enabled in homeserver.yaml"
else
  fail "retention NOT enabled"
fi

# ── 6. Presence disabled ────────────────────────────────────────────────────
echo
echo "=== Presence ==="
PRES_ENABLED=$(echo "$HS_YAML" | python3 -c "
import sys, yaml
c = yaml.safe_load(sys.stdin)
p = c.get('presence', {})
print('true' if p.get('enabled', True) else 'false')
" 2>/dev/null)
if [ "$PRES_ENABLED" = "false" ]; then
  ok "presence disabled"
else
  fail "presence is ENABLED (leaks online/offline status)"
fi

# ── 7. URL previews disabled ────────────────────────────────────────────────
echo
echo "=== URL Previews ==="
URL_PREV=$(echo "$HS_YAML" | python3 -c "
import sys, yaml
c = yaml.safe_load(sys.stdin)
print('true' if c.get('url_preview_enabled', False) else 'false')
" 2>/dev/null)
if [ "$URL_PREV" = "false" ]; then
  ok "URL previews disabled (no outbound link fetching)"
else
  fail "URL previews ENABLED (server fetches linked URLs — metadata leak)"
fi

# ── 8. User IP retention ────────────────────────────────────────────────────
echo
echo "=== IP Retention ==="
USER_IPS=$(echo "$HS_YAML" | python3 -c "
import sys, yaml
c = yaml.safe_load(sys.stdin)
d = c.get('user_ips_max_age', 'default')
print(d)
" 2>/dev/null)
if [ "$USER_IPS" != "default" ] && [ -n "$USER_IPS" ]; then
  ok "user_ips_max_age = ${USER_IPS}"
else
  warn "user_ips_max_age not explicitly set (Synapse default: 28 days)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "\033[0;32m  PASS: %d/%d checks passed\033[0m" "$PASS" "$TOTAL"
else
  printf "\033[0;31m  FAIL: %d/%d checks passed (%d failed)\033[0m" "$PASS" "$TOTAL" "$FAIL"
fi
[ "$WARN" -gt 0 ] && printf ", %d warnings" "$WARN"
echo
echo "════════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ]
