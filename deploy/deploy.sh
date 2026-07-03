#!/usr/bin/env bash
# REDnet first-time deployment — single entry point.
#
# Chains prerequisites → setup.sh → bootstrap chain → Element Web → operator account,
# posts first-run messages to rooms, writes credentials to a file, prints next steps.
#
# Usage:
#   ./deploy.sh --operator alice     # two-host production (default)
#   ./deploy.sh --dev                # single-host dev/lab mode
#   ./deploy.sh --dev --operator alice  # non-interactive dev mode
#   ./deploy.sh --skip-element       # skip Element Web build (use Element X mobile instead)
#
# This orchestrates a first deploy, but it is idempotent-ish, NOT a wipe: setup.sh
# reuses any existing volumes rather than destroying them. REDNET_DOMAIN and the DB
# password become immutable once the postgres volume exists (a changed re-run is
# refused with instructions). To start completely fresh, wipe first:
#   docker compose down -v && rm -f deploy/.env deploy/.deployed-domain
#
# Two-host (production) is the default. Single-host requires --dev.
# You can also set REDNET_ROLE=core in rednet.env for explicit two-host mode.
#
# Requires: docker, docker compose, python3 + pyyaml, jq.
# Optional: qrencode (for printable invite QR cards).
set -uo pipefail
cd "$(dirname "$0")" || exit 1

# ── formatting ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
say()  { printf "\n${BOLD}=== %s ===${NC}\n" "$*"; }
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
warn() { printf "  ${YELLOW}⚠${NC} %s\n" "$*"; }
fail() { printf "  ${RED}✗${NC} %s\n" "$*"; }
die()  { fail "$*"; exit 1; }

# ── helpers (shared with other scripts) ─────────────────────────────────────────
mas()  { docker compose exec -T mas mas-cli manage "$@" --config /config.yaml 2>&1; }
enc()  { python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }
genpw(){ python3 -c "import secrets; print(secrets.token_urlsafe(24))"; }
now_iso(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
txn_id(){ printf 'deploy-%s-%s' "$(date +%s%N)" "$$"; }

# ── parse arguments ─────────────────────────────────────────────────────────────
OPERATOR_USERNAME=""
SKIP_ELEMENT=false
DEV_MODE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dev)           DEV_MODE=true; shift ;;
    --operator)      OPERATOR_USERNAME="$2"; shift 2 ;;
    --skip-element)  SKIP_ELEMENT=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--dev] [--operator <username>] [--skip-element]"
      echo "  --dev               Single-host dev/lab mode (default is two-host production)"
      echo "  --operator <name>   Operator username (prompted if omitted)"
      echo "  --skip-element      Skip Element Web build (use Element X mobile)"
      exit 0 ;;
    *) die "Unknown option: $1. Run $0 --help for usage." ;;
  esac
done

# ════════════════════════════════════════════════════════════════════════════════
# PHASE 0: PREREQUISITES
# ════════════════════════════════════════════════════════════════════════════════
say "prerequisites"

MISSING=0
for cmd in docker python3 jq; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd"
  else
    fail "$cmd — required"
    MISSING=1
  fi
done

if docker compose version >/dev/null 2>&1; then
  ok "docker compose"
else
  fail "docker compose — required (install Docker Compose V2)"
  MISSING=1
fi

# pyyaml — setup.sh uses it to render MAS config
if command -v uv >/dev/null 2>&1; then
  ok "pyyaml (via uv)"
elif python3 -c "import yaml" 2>/dev/null; then
  ok "pyyaml"
else
  fail "python3 pyyaml — required (pip install pyyaml, or install uv)"
  MISSING=1
fi

# optional
if command -v qrencode >/dev/null 2>&1; then
  ok "qrencode"
else
  warn "qrencode not found — invite cards will lack QR codes"
  warn "  install: apt install qrencode / brew install qrencode"
fi

[ "$MISSING" -eq 0 ] || die "install missing prerequisites and re-run"

# ════════════════════════════════════════════════════════════════════════════════
# PHASE 1: CONFIG
# ════════════════════════════════════════════════════════════════════════════════
say "config"

if [ ! -f rednet.env ]; then
  if [ -f rednet.env.example ]; then
    cp rednet.env.example rednet.env
    warn "created rednet.env from example — edit REDNET_DOMAIN before continuing"
    echo
    echo "  Open rednet.env and set REDNET_DOMAIN to your domain."
    echo "  This value is IMMUTABLE after first deploy."
    echo
    die "edit rednet.env, then re-run $0"
  else
    die "rednet.env not found and no example to copy"
  fi
fi

set -a; . ./rednet.env; set +a
: "${REDNET_DOMAIN:?set REDNET_DOMAIN in rednet.env}"
: "${REDNET_HTTP_PORT:=8080}"
: "${REDNET_BRAND:=REDnet}"
ROLE="${REDNET_ROLE:-core}"
# --dev flag on deploy.sh itself → single-host dev mode (parsed above; the arg
# list is already consumed by the parser's shifts, so key off DEV_MODE here).
$DEV_MODE && ROLE=single
ACCESS="http://localhost:${REDNET_HTTP_PORT}"
PUBLIC_BASE="${REDNET_PUBLIC_BASE:-$ACCESS}"

# API_URL: where bootstrap curls reach Synapse's C-S API.
# Single-host: Caddy on localhost fronts everything.
# Core mode: no Caddy — reach Synapse directly on the WG interface.
if [ "$ROLE" = "core" ] && [ -f docker-compose.wg.yml ]; then
  WG_IP=$(ip -4 addr show wg0 2>/dev/null | grep -oP 'inet \K[\d.]+' || true)
  if [ -n "$WG_IP" ]; then
    API_URL="http://${WG_IP}:8008"
  else
    API_URL="http://localhost:8008"
    warn "wg0 not found — using localhost:8008 (start WireGuard before bootstrap if two-host)"
  fi
else
  API_URL="$ACCESS"
fi

ok "REDNET_DOMAIN=${REDNET_DOMAIN}"
ok "REDNET_HTTP_PORT=${REDNET_HTTP_PORT}"
ok "REDNET_ROLE=${ROLE}"
if [ "$ROLE" = "core" ]; then
  ok "CORE mode — API via ${API_URL}"
fi

# ── operator username ───────────────────────────────────────────────────────────
if [ -z "$OPERATOR_USERNAME" ]; then
  echo
  printf "  ${CYAN}Pick a username for the first admin account.${NC}\n"
  printf "  ${DIM}Same rules as for members: not your real name, not a handle${NC}\n"
  printf "  ${DIM}you use on any other service. Lowercase, no spaces.${NC}\n"
  echo
  printf "  Operator username: "
  read -r OPERATOR_USERNAME
  [ -n "$OPERATOR_USERNAME" ] || die "no username provided"
fi
OPERATOR_USERNAME=$(echo "$OPERATOR_USERNAME" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
OPERATOR_ID="@${OPERATOR_USERNAME}:${REDNET_DOMAIN}"
ok "operator: ${OPERATOR_ID}"

# ════════════════════════════════════════════════════════════════════════════════
# PHASE 2: STACK + ROOMS
# ════════════════════════════════════════════════════════════════════════════════
say "stack (setup.sh → bootstrap-rooms.sh)"

if [ "$ROLE" = "core" ]; then
  if docker compose ps --format '{{.Name}}' 2>/dev/null | grep -q synapse; then
    ok "stack already running (provisioned by Ansible)"
  else
    ./setup.sh || die "setup.sh failed — check the output above"
    ok "configs rendered (core mode — Ansible brings up services)"
  fi
elif [ "$ROLE" = "single" ]; then
  ./setup.sh --dev || die "setup.sh failed — check the output above"
  ok "stack running, rooms bootstrapped"
fi

# ── pre-bootstrap sanity check ──────────────────────────────────────────────
say "sanity check — verifying Synapse is reachable before bootstrap"
SYNAPSE_OK=false
for _ in $(seq 1 30); do
  curl -sf "${API_URL}/_matrix/client/versions" >/dev/null 2>&1 && { SYNAPSE_OK=true; break; }
  sleep 2
done
if $SYNAPSE_OK; then
  ok "Synapse responding at ${API_URL}"
else
  die "Synapse not reachable at ${API_URL} — check that services are running and WireGuard is up"
fi

MAS_OK=false
for _ in $(seq 1 15); do
  # list-admin-users is a read-only liveness probe that exists in MAS 1.19.0
  # (there is no `list-users`; the bootstrap chain relies on this CLI working).
  docker compose exec -T mas mas-cli manage list-admin-users --config /config.yaml >/dev/null 2>&1 && { MAS_OK=true; break; }
  sleep 2
done
if $MAS_OK; then
  ok "MAS responding"
else
  die "MAS not reachable via docker exec — check that the MAS container is running"
fi

# ════════════════════════════════════════════════════════════════════════════════
# PHASE 3: BOOTSTRAP CHAIN
# ════════════════════════════════════════════════════════════════════════════════
say "governance infrastructure"
./bootstrap-governance.sh || die "bootstrap-governance.sh failed"
ok "#vouch-log + #governance"

say "moderation bot (Draupnir)"
./bootstrap-draupnir.sh || die "bootstrap-draupnir.sh failed"
ok "Draupnir + #rednet-mod"

say "governance bot"
./bootstrap-gov-bot.sh || die "bootstrap-gov-bot.sh failed"
ok "gov-bot + #gov-bot"

# ════════════════════════════════════════════════════════════════════════════════
# PHASE 4: ELEMENT WEB
# ════════════════════════════════════════════════════════════════════════════════
# Tracks whether a web client is actually reachable, so the summary doesn't tell
# the operator to "open <url> and log in" when the Element build/serve failed.
WEB_OK=false
if [ "$ROLE" = "core" ]; then
  warn "CORE mode — skipping Element Web (the FRONT serves it)"
elif $SKIP_ELEMENT; then
  if [ "$ROLE" = "single" ]; then
    warn "Element Web skipped (--skip-element) in dev mode — a localhost dev deploy"
    warn "  is not reachable from a phone. Drop --skip-element to log in via the browser."
  else
    warn "Element Web skipped (--skip-element). Use Element X on mobile to log in."
    warn "  Server address: ${REDNET_DOMAIN}"
  fi
elif docker compose --profile web ps --format '{{.Name}}' 2>/dev/null | grep -q element; then
  ok "Element Web already running"
  WEB_OK=true
else
  say "Element Web (soft-fork build — this takes 3-5 minutes)"
  # Pass the deploy's PUBLIC_BASE so Element's homeserver base_url matches where
  # the stack is actually served. In dev that is http://localhost:$PORT; without
  # this, build.sh defaults to https://$REDNET_DOMAIN (a placeholder that does not
  # resolve locally) and the client shows "Cannot reach homeserver".
  REDNET_PUBLIC_BASE="$PUBLIC_BASE" ./element-web/build.sh || { warn "Element Web build failed — web login unavailable. Use Element X on mobile."; }
  docker compose --profile web up -d element 2>/dev/null
  # wait for element container to respond
  for _ in $(seq 1 30); do
    curl -sf "${ACCESS}/" -o /dev/null 2>/dev/null && break
    sleep 2
  done
  if curl -sf "${ACCESS}/" -o /dev/null 2>/dev/null; then
    ok "Element Web serving at ${ACCESS}/"
    WEB_OK=true
  else
    warn "Element Web not responding — check: docker compose logs element"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════════
# PHASE 5: OPERATOR ACCOUNT
# ════════════════════════════════════════════════════════════════════════════════
say "operator account: ${OPERATOR_USERNAME}"

# The operator sets their OWN password, so no system-generated secret ever has to
# be written to disk or echoed back — there is nothing to recover from the seizable
# CORE (bootstrap audit F6). Precedence: REDNET_OPERATOR_PASSWORD env (automation)
# → interactive prompt → generated fallback (only when non-interactive with no env,
# e.g. dev/CI, where it is written to the 0600 credentials file as before).
OPERATOR_PW=""
PW_SOURCE=""
if [ -n "${REDNET_OPERATOR_PASSWORD:-}" ]; then
  OPERATOR_PW="$REDNET_OPERATOR_PASSWORD"; PW_SOURCE="env"
elif [ -t 0 ]; then
  echo
  printf "  ${CYAN}Set a password for your admin account.${NC}\n"
  printf "  ${DIM}You log in with it. It is never written to disk or shown again.${NC}\n"
  echo
  while :; do
    printf "  Password: "; read -rs OPERATOR_PW; echo
    printf "  Confirm:  "; read -rs _PW2; echo
    [ -z "$OPERATOR_PW" ] && { warn "empty password — try again"; continue; }
    [ "$OPERATOR_PW" != "$_PW2" ] && { warn "passwords didn't match — try again"; continue; }
    break
  done
  unset _PW2
  PW_SOURCE="operator"
else
  OPERATOR_PW=$(genpw); PW_SOURCE="generated"
  warn "no TTY and no REDNET_OPERATOR_PASSWORD — generated a password (dev/CI only)"
fi

# An operator-chosen password is complexity-checked (drop --ignore-password-complexity)
# so a weak choice is caught here, not silently accepted; a generated one keeps the
# bypass since genpw is already high-entropy.
register_operator(){
  if [ "$PW_SOURCE" = operator ]; then
    mas register-user "$OPERATOR_USERNAME" --password "$OPERATOR_PW" --yes 2>&1
  else
    mas register-user "$OPERATOR_USERNAME" --password "$OPERATOR_PW" --yes --ignore-password-complexity 2>&1
  fi
}
set_operator_password(){
  if [ "$PW_SOURCE" = operator ]; then
    mas set-password "$OPERATOR_USERNAME" --password "$OPERATOR_PW" --yes 2>&1 | tail -1
  else
    mas set-password "$OPERATOR_USERNAME" --password "$OPERATOR_PW" --yes --ignore-password-complexity 2>&1 | tail -1
  fi
}

REG_RESULT=$(register_operator)
# Re-prompt while MAS rejects an operator-chosen password (most often: too weak).
PW_TRIES=0
while [ "$PW_SOURCE" = operator ] && ! echo "$REG_RESULT" | grep -qiE 'registered|already exists'; do
  PW_TRIES=$((PW_TRIES + 1))
  [ "$PW_TRIES" -ge 5 ] && die "operator registration kept failing — last response: $(echo "$REG_RESULT" | tail -1)"
  warn "MAS rejected that password (usually too weak for policy):"
  echo "$REG_RESULT" | tail -2 | sed 's/^/    /'
  printf "  ${DIM}Use a long passphrase — 4+ random words, or 16+ mixed characters.${NC}\n"
  while :; do
    printf "  Password: "; read -rs OPERATOR_PW; echo
    printf "  Confirm:  "; read -rs _PW2; echo
    [ -n "$OPERATOR_PW" ] && [ "$OPERATOR_PW" = "$_PW2" ] && break
    warn "empty or mismatch — try again"
  done
  unset _PW2
  REG_RESULT=$(register_operator)
done
if echo "$REG_RESULT" | grep -qi "already exists"; then
  warn "account exists — setting its password to the one you provided"
  set_operator_password
elif echo "$REG_RESULT" | grep -qi "registered"; then
  ok "account created"
else
  warn "unexpected MAS response:"; echo "$REG_RESULT" | tail -2 | sed 's/^/    /'
fi

# Invite to rooms + set power levels via bootstrap-operator.sh
./bootstrap-operator.sh "$OPERATOR_USERNAME" --existing || warn "operator bootstrap had issues — check output above"
ok "${OPERATOR_ID} is PL100 admin in all rooms"

# Write REDNET_OPERATOR to rednet.env if not already set
if grep -q "^REDNET_OPERATOR=" rednet.env 2>/dev/null; then
  # Update existing line
  sed -i "s|^REDNET_OPERATOR=.*|REDNET_OPERATOR=${OPERATOR_ID}|" rednet.env
else
  # Uncomment and set, or append
  if grep -q "^# REDNET_OPERATOR=" rednet.env 2>/dev/null; then
    sed -i "s|^# REDNET_OPERATOR=.*|REDNET_OPERATOR=${OPERATOR_ID}|" rednet.env
  else
    echo "REDNET_OPERATOR=${OPERATOR_ID}" >> rednet.env
  fi
fi
ok "REDNET_OPERATOR=${OPERATOR_ID} written to rednet.env"

# ════════════════════════════════════════════════════════════════════════════════
# PHASE 6: FIRST-RUN MESSAGES
# ════════════════════════════════════════════════════════════════════════════════
say "first-run messages"

# Skip if already posted (marker file)
if [ -f .deploy-messages-posted ]; then
  ok "messages already posted (previous run)"
else
  SYS_TOK=$(mas issue-compatibility-token rednet-system DEPLOYMSG | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
  if [ -z "${SYS_TOK:-}" ]; then
    warn "could not get system token — skipping room messages"
  else
    SAUTH="Authorization: Bearer $SYS_TOK"
    # Track failures of the survival-critical onboarding messages (the pinned
    # #welcome founder setup and the #gov-bot checklist). The marker below is only
    # written when these landed, so a re-run retries them instead of silently
    # skipping the recovery-passphrase / second-device guidance the operator needs.
    MSG_CRITICAL_FAIL=0
    resolve_room(){
      curl -s -H "$SAUTH" "$API_URL/_matrix/client/v3/directory/room/%23${1}%3A${REDNET_DOMAIN}" \
        | jq -r '.room_id // empty' 2>/dev/null
    }
    send_msg(){
      local room_id="$1" msgtype="$2" body="$3" html="${4:-}"
      local payload
      if [ -n "$html" ]; then
        payload=$(jq -n --arg t "$msgtype" --arg b "$body" --arg h "$html" \
          '{msgtype:$t, body:$b, format:"org.matrix.custom.html", formatted_body:$h}')
      else
        payload=$(jq -n --arg t "$msgtype" --arg b "$body" '{msgtype:$t, body:$b}')
      fi
      curl -s -XPUT "$API_URL/_matrix/client/v3/rooms/$(enc "$room_id")/send/m.room.message/$(txn_id)" \
        -H "$SAUTH" -H "Content-Type: application/json" -d "$payload"
    }
    update_topic(){
      local room_id="$1" topic="$2"
      curl -s -XPUT "$API_URL/_matrix/client/v3/rooms/$(enc "$room_id")/state/m.room.topic/" \
        -H "$SAUTH" -H "Content-Type: application/json" \
        -d "$(jq -n --arg t "$topic" '{topic:$t}')" >/dev/null 2>&1
    }

    # ── #welcome: founder setup message ──
    WELCOME_ID=$(resolve_room welcome)
    if [ -n "$WELCOME_ID" ]; then
      WELCOME_BODY="Founder setup

You are the first admin. Every member of this community traces back to an invite you mint. Before you bring anyone in:

▸ Save your recovery passphrase
  Element showed it during first login. Write it on paper or store it in a password manager. Not a screenshot, not a notes app.

▸ Disable lock screen previews
  iPhone: Settings > Notifications > Element X > Show Previews > Never
  Android: Settings > Apps > Element X > Sensitive notifications off

▸ Set up a second device
  Log in on a laptop or tablet too. If your phone is seized, the second session lets you begin emergency revocation.

▸ Open #gov-bot for your operational checklist
▸ Operator guide: ${PUBLIC_BASE}/operator-guide
▸ Governance dashboard: ${PUBLIC_BASE}/governance/"

      WELCOME_HTML="<h3>Founder setup</h3>
<p>You are the first admin. Every member of this community traces back to an invite you mint. Before you bring anyone in:</p>
<p><strong>▸ Save your recovery passphrase</strong><br/>Element showed it during first login. Write it on paper or store it in a password manager. Not a screenshot, not a notes app.</p>
<p><strong>▸ Disable lock screen previews</strong><br/><em>iPhone:</em> Settings &gt; Notifications &gt; Element X &gt; Show Previews &gt; Never<br/><em>Android:</em> Settings &gt; Apps &gt; Element X &gt; Sensitive notifications off</p>
<p><strong>▸ Set up a second device</strong><br/>Log in on a laptop or tablet too. If your phone is seized, the second session lets you begin emergency revocation.</p>
<ul>
<li>Open <strong>#gov-bot</strong> for your operational checklist</li>
<li><a href=\"${PUBLIC_BASE}/operator-guide\">Operator guide</a></li>
<li><a href=\"${PUBLIC_BASE}/governance/\">Governance dashboard</a></li>
</ul>"

      WELCOME_EID=$(send_msg "$WELCOME_ID" "m.text" "$WELCOME_BODY" "$WELCOME_HTML" \
        | jq -r '.event_id // empty' 2>/dev/null)

      if [ -n "$WELCOME_EID" ]; then
        # Pin the message
        curl -s -XPUT "$API_URL/_matrix/client/v3/rooms/$(enc "$WELCOME_ID")/state/m.room.pinned_events/" \
          -H "$SAUTH" -H "Content-Type: application/json" \
          -d "$(jq -n --arg eid "$WELCOME_EID" '{pinned:[$eid]}')" >/dev/null 2>&1
        ok "#welcome — founder setup (pinned)"
      else
        warn "#welcome — message send failed"
        MSG_CRITICAL_FAIL=$((MSG_CRITICAL_FAIL + 1))
      fi
    else
      warn "#welcome room not found — founder setup not posted"
      MSG_CRITICAL_FAIL=$((MSG_CRITICAL_FAIL + 1))
    fi

    # ── #gov-bot: operational checklist ──
    GOV_BOT_ID=$(resolve_room gov-bot)
    if [ -n "$GOV_BOT_ID" ]; then
      # gov-bot was created by @rednet-gov, system may not be in it — invite first
      GOV_TOK=$(mas issue-compatibility-token rednet-gov DEPLOYMSG2 | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
      if [ -n "$GOV_TOK" ]; then
        GAUTH="Authorization: Bearer $GOV_TOK"
        curl -s -XPOST "$API_URL/_matrix/client/v3/rooms/$(enc "$GOV_BOT_ID")/invite" \
          -H "$GAUTH" -H "Content-Type: application/json" \
          -d "$(jq -n --arg u "@rednet-system:$REDNET_DOMAIN" '{user_id:$u}')" >/dev/null 2>&1
        curl -s -XPOST "$API_URL/_matrix/client/v3/join/$(enc "$GOV_BOT_ID")" \
          -H "$SAUTH" -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1
      fi

      CHECKLIST_BODY="First-run checklist

Your deployment is live. Work through these before inviting anyone.

☐ Recovery passphrase saved (pen + paper, or password manager)
☐ Lock screen previews disabled on every device
☐ Type !gov status — verify this bot responds
☐ Type !gov audit — should report \"no anomalies\"
☐ Read the operator guide: ${PUBLIC_BASE}/operator-guide
☐ Open the governance dashboard: ${PUBLIC_BASE}/governance/
☐ Mint your first invite:
    ./mint-invite.sh --label \"first organizer\"
  Hand the QR card to your first trusted organizer.

Your account: ${OPERATOR_ID} (PL100 admin)"

      # Capture the event_id: curl -s exits 0 even on an HTTP error, so the send's
      # success can only be judged by whether Synapse returned an event_id.
      CHECK_EID=$(send_msg "$GOV_BOT_ID" "m.notice" "$CHECKLIST_BODY" | jq -r '.event_id // empty' 2>/dev/null)
      if [ -n "$CHECK_EID" ]; then
        ok "#gov-bot — operational checklist"
      else
        warn "#gov-bot — message send failed"
        MSG_CRITICAL_FAIL=$((MSG_CRITICAL_FAIL + 1))
      fi
    else
      warn "#gov-bot room not found — operational checklist not posted"
      MSG_CRITICAL_FAIL=$((MSG_CRITICAL_FAIL + 1))
    fi

    # ── #governance: dashboard context ──
    GOVERNANCE_ID=$(resolve_room governance)
    if [ -n "$GOVERNANCE_ID" ]; then
      GOV_CONTEXT="This room is for organizer coordination (E2EE). For bot commands, use #gov-bot (non-E2EE).

Governance dashboard: ${PUBLIC_BASE}/governance/
The dashboard shows vouch provenance, audit alerts, and the trust graph. It populates as you mint invites and confirm vouches."

      send_msg "$GOVERNANCE_ID" "m.notice" "$GOV_CONTEXT" >/dev/null 2>&1 \
        && ok "#governance — dashboard context" \
        || warn "#governance — message send failed"
    fi

    # ── member guide notice in #welcome ──
    if [ -n "$WELCOME_ID" ]; then
      MEM_BODY="Member guide: ${PUBLIC_BASE}/member-guide

Covers messaging, encryption, privacy practices, device setup, and what to do if something goes wrong. Bookmark it."

      MEM_HTML="<p><strong>Member guide:</strong> <a href=\"${PUBLIC_BASE}/member-guide\">${PUBLIC_BASE}/member-guide</a></p>
<p>Covers messaging, encryption, privacy practices, device setup, and what to do if something goes wrong. Bookmark it.</p>"

      send_msg "$WELCOME_ID" "m.notice" "$MEM_BODY" "$MEM_HTML" >/dev/null 2>&1 \
        && ok "#welcome — member guide link" \
        || warn "#welcome — member guide message failed"
    fi

    # ── update room topics with links ──

    COMMUNITY_ID=$(resolve_room community)
    [ -n "$COMMUNITY_ID" ] && update_topic "$COMMUNITY_ID" \
      "Encrypted organizing space. Member guide: ${PUBLIC_BASE}/member-guide" \
      && ok "space topic updated"

    [ -n "$WELCOME_ID" ] && update_topic "$WELCOME_ID" \
      "Start here — read the pinned message, save your recovery passphrase. Guide: ${PUBLIC_BASE}/member-guide" \
      && ok "#welcome topic updated"

    ANNOUNCEMENTS_ID=$(resolve_room announcements)
    [ -n "$ANNOUNCEMENTS_ID" ] && update_topic "$ANNOUNCEMENTS_ID" \
      "Organizer updates. Read-only for members — moderators and above can post." \
      && ok "#announcements topic updated"

    REFERENCE_ID=$(resolve_room reference)
    [ -n "$REFERENCE_ID" ] && update_topic "$REFERENCE_ID" \
      "Durable info that outlasts chat retention: hotlines, safety plans, meeting points, contacts. Pin anything worth keeping." \
      && ok "#reference topic updated"

    GENERAL_ID=$(resolve_room general)
    [ -n "$GENERAL_ID" ] && update_topic "$GENERAL_ID" \
      "Open discussion. Auto-deletes after retention window — move anything durable to #reference." \
      && ok "#general topic updated"

    [ -n "$GOVERNANCE_ID" ] && update_topic "$GOVERNANCE_ID" \
      "Organizer coordination (E2EE). Dashboard: ${PUBLIC_BASE}/governance/ · Operator guide: ${PUBLIC_BASE}/operator-guide" \
      && ok "#governance topic updated"

    # #gov-bot was created by @rednet-gov, not @rednet-system — use gov token for topic
    if [ -n "$GOV_BOT_ID" ] && [ -n "${GOV_TOK:-}" ]; then
      curl -s -XPUT "$API_URL/_matrix/client/v3/rooms/$(enc "$GOV_BOT_ID")/state/m.room.topic/" \
        -H "Authorization: Bearer $GOV_TOK" -H "Content-Type: application/json" \
        -d "$(jq -n --arg t "Bot commands — type !gov help. Dashboard: ${PUBLIC_BASE}/governance/ · Non-E2EE by design (bot can't decrypt)." '{topic:$t}')" >/dev/null 2>&1 \
        && ok "#gov-bot topic updated"
    fi

    VOUCHLOG_ID=$(resolve_room vouch-log)
    [ -n "$VOUCHLOG_ID" ] && update_topic "$VOUCHLOG_ID" \
      "Append-only audit trail: vouches, claims, role changes, revocations. Retention-exempt — do not delete events." \
      && ok "#vouch-log topic updated"

    if [ "$MSG_CRITICAL_FAIL" -eq 0 ]; then
      touch .deploy-messages-posted
    else
      warn "${MSG_CRITICAL_FAIL} critical onboarding message(s) did not post — NOT marking messages done"
      warn "  re-run ./deploy.sh to retry (the founder needs the pinned #welcome + #gov-bot guidance)"
    fi
  fi
fi

# ════════════════════════════════════════════════════════════════════════════════
# PHASE 7: CREDENTIALS
# ════════════════════════════════════════════════════════════════════════════════
say "credentials"

LOGIN_URL="$PUBLIC_BASE"
[ "$ROLE" = "single" ] && LOGIN_URL="$ACCESS"

CRED_FILE=".first-run-credentials"
if [ "$PW_SOURCE" = generated ]; then
  # Dev/CI fallback only (no TTY, no env password): record the generated one so
  # the automated run can retrieve it. Interactive/production deploys never hit
  # this branch, so no operator-chosen secret is ever written to disk.
  cat > "$CRED_FILE" <<CREDS
REDnet first-run credentials (dev/CI fallback)
Generated: $(now_iso)
DELETE THIS FILE after your first login.

Username:  ${OPERATOR_USERNAME}
User ID:   ${OPERATOR_ID}
Password:  ${OPERATOR_PW}   (auto-generated — no operator was at the keyboard)
Login URL: ${LOGIN_URL}

After login:
  - Element will show a RECOVERY PASSPHRASE — write it down separately
  - The password above proves your identity (can be changed later)
  - The passphrase unlocks your message history (cannot be changed)
  - You need BOTH

Guides:
  Operator guide:          ${PUBLIC_BASE}/operator-guide
  Governance dashboard:    ${PUBLIC_BASE}/governance/
  Member guide:            ${PUBLIC_BASE}/member-guide
  Moderator guide:         ${PUBLIC_BASE}/moderator-guide
CREDS
  chmod 600 "$CRED_FILE"
  warn "credentials → ${CRED_FILE} — holds a generated password; delete after first login"
else
  # Operator set their own password: nothing secret to persist. The file is only
  # a pointer, so no plaintext credential rests on the seizable CORE (F6).
  cat > "$CRED_FILE" <<CREDS
REDnet first-run info
Generated: $(now_iso)

Username:  ${OPERATOR_USERNAME}
User ID:   ${OPERATOR_ID}
Login URL: ${LOGIN_URL}
Password:  the one you set during deploy — not stored anywhere.
           Forgot it? Reset it from the CORE:
           docker compose exec mas mas-cli manage set-password ${OPERATOR_USERNAME}

After login:
  - Element will show a RECOVERY PASSPHRASE — write it down separately
  - Your password proves your identity (can be changed later)
  - The passphrase unlocks your message history (cannot be changed)
  - You need BOTH

Guides:
  Operator guide:          ${PUBLIC_BASE}/operator-guide
  Governance dashboard:    ${PUBLIC_BASE}/governance/
  Member guide:            ${PUBLIC_BASE}/member-guide
  Moderator guide:         ${PUBLIC_BASE}/moderator-guide
CREDS
  chmod 600 "$CRED_FILE"
  ok "first-run info → ${CRED_FILE} (no password stored)"
fi

# ════════════════════════════════════════════════════════════════════════════════
# POST-DEPLOY SMOKE TEST
# ════════════════════════════════════════════════════════════════════════════════
say "smoke test"

SMOKE_PASS=0
SMOKE_FAIL=0
smoke_check(){
  local label="$1" alias="$2"
  local rid
  rid=$(curl -sf -H "$SAUTH" "$API_URL/_matrix/client/v3/directory/room/%23${alias}%3A${REDNET_DOMAIN}" 2>/dev/null \
    | jq -r '.room_id // empty' 2>/dev/null)
  if [ -n "$rid" ]; then
    ok "$label"
    SMOKE_PASS=$((SMOKE_PASS + 1))
  else
    fail "$label"
    SMOKE_FAIL=$((SMOKE_FAIL + 1))
  fi
}

op_room_check(){
  # Verify the operator was actually provisioned into a room, not just that the
  # room exists. Reads the operator's own m.room.member state event (the pattern
  # bootstrap-operator uses) rather than /joined_members: a freshly-provisioned
  # operator is in `invite` state until first login, so /joined_members would be
  # empty on every healthy deploy and couldn't tell "invited OK" from "never
  # invited". A missing/leave/ban membership, or a PL that isn't 100, is a real
  # provisioning failure and counts against the smoke test.
  local alias="$1" rid member pl
  rid=$(curl -sf -H "$SAUTH" "$API_URL/_matrix/client/v3/directory/room/%23${alias}%3A${REDNET_DOMAIN}" 2>/dev/null \
    | jq -r '.room_id // empty' 2>/dev/null)
  if [ -z "$rid" ]; then
    fail "operator #${alias}: room not found"
    SMOKE_FAIL=$((SMOKE_FAIL + 1))
    return
  fi
  member=$(curl -sf -H "$SAUTH" \
    "$API_URL/_matrix/client/v3/rooms/$(enc "$rid")/state/m.room.member/${OPERATOR_ID}" 2>/dev/null \
    | jq -r '.membership // empty' 2>/dev/null)
  pl=$(curl -sf -H "$SAUTH" \
    "$API_URL/_matrix/client/v3/rooms/$(enc "$rid")/state/m.room.power_levels/" 2>/dev/null \
    | jq -r --arg u "$OPERATOR_ID" '.users[$u] // "none"' 2>/dev/null)
  if { [ "$member" = "invite" ] || [ "$member" = "join" ]; } && [ "$pl" = "100" ]; then
    ok "operator #${alias} (${member}, PL${pl})"
    SMOKE_PASS=$((SMOKE_PASS + 1))
  else
    fail "operator #${alias}: membership='${member:-none}' PL='${pl:-none}' (want invite|join + PL100)"
    SMOKE_FAIL=$((SMOKE_FAIL + 1))
  fi
}

SMOKE_TOK=$(mas issue-compatibility-token rednet-system SMOKE 2>/dev/null | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
if [ -n "$SMOKE_TOK" ]; then
  SAUTH="Authorization: Bearer $SMOKE_TOK"
  for room in community welcome announcements reference general governance vouch-log gov-bot; do
    smoke_check "#$room" "$room"
  done

  GOV_BOT_JOINED=$(curl -sf -H "$SAUTH" \
    "$API_URL/_matrix/client/v3/directory/room/%23gov-bot%3A${REDNET_DOMAIN}" 2>/dev/null \
    | jq -r '.room_id // empty' 2>/dev/null)
  if [ -n "$GOV_BOT_JOINED" ]; then
    GOV_MEMBERS=$(curl -sf -H "$SAUTH" \
      "$API_URL/_matrix/client/v3/rooms/$(enc "$GOV_BOT_JOINED")/joined_members" 2>/dev/null \
      | jq '.joined | keys[]' 2>/dev/null | grep -c 'rednet-gov' || true)
    if [ "$GOV_MEMBERS" -gt 0 ]; then
      ok "gov-bot account joined #gov-bot"
      SMOKE_PASS=$((SMOKE_PASS + 1))
    else
      fail "gov-bot account not in #gov-bot"
      SMOKE_FAIL=$((SMOKE_FAIL + 1))
    fi
  fi

  # Operator provisioning: the exact incident class the old check missed (operator
  # created but missing from rooms / lacking PL) now counts against the smoke test
  # instead of a single #community warn that always fired on a healthy deploy.
  for room in community welcome announcements reference general governance vouch-log gov-bot; do
    op_room_check "$room"
  done

  echo
  if [ "$SMOKE_FAIL" -eq 0 ]; then
    ok "smoke test: ${SMOKE_PASS}/${SMOKE_PASS} passed"
  else
    warn "smoke test: ${SMOKE_PASS}/$((SMOKE_PASS + SMOKE_FAIL)) passed, ${SMOKE_FAIL} failed"
    warn "  re-run the relevant bootstrap script to fix missing rooms"
  fi
else
  warn "smoke test skipped — could not mint system token"
fi

# ════════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════════════════════════
echo
printf "${BOLD}════════════════════════════════════════════════════${NC}\n"
printf "${BOLD}  ${RED}RED${NC}${DIM}net${NC}${BOLD} deployed${NC}\n"
printf "${BOLD}════════════════════════════════════════════════════${NC}\n"
echo
# In single/dev mode the login URL is a localhost address served only by Element
# Web; if that build/serve failed there is no client there, so don't present a
# dead URL as the way in.
WEB_UNAVAILABLE=false
{ [ "$ROLE" = "single" ] && ! $WEB_OK; } && WEB_UNAVAILABLE=true
if $WEB_UNAVAILABLE; then
  printf "  ${YELLOW}Login:     Element Web is not serving at ${ACCESS}${NC}\n"
  printf "  ${DIM}           build/serve failed — see: docker compose logs element${NC}\n"
else
  printf "  Login:     ${CYAN}${LOGIN_URL}${NC}\n"
fi
printf "  Account:   ${BOLD}${OPERATOR_ID}${NC}  (PL100 admin)\n"
if [ "$PW_SOURCE" = generated ]; then
  printf "  Password:  ${BOLD}${OPERATOR_PW}${NC}  ${DIM}(generated — dev/CI)${NC}\n"
elif [ "$PW_SOURCE" = env ]; then
  printf "  Password:  ${DIM}the one supplied via REDNET_OPERATOR_PASSWORD${NC}\n"
else
  printf "  Password:  ${DIM}the one you just set — not stored anywhere${NC}\n"
fi
echo
printf "  ${YELLOW}⚠ TWO SECRETS TO SAVE:${NC}\n"
if [ "$PW_SOURCE" = generated ]; then
  printf "    ${BOLD}1.${NC} The generated password above — log in with it now\n"
else
  printf "    ${BOLD}1.${NC} Your password — the one you set (only you know it)\n"
fi
printf "    ${BOLD}2.${NC} A ${BOLD}RECOVERY PASSPHRASE${NC} — Element shows it\n"
printf "       on first login. Write it on paper or put\n"
printf "       it in a password manager.\n"
echo
if [ "$PW_SOURCE" = generated ]; then
  printf "  Credentials saved to: ${DIM}${CRED_FILE}${NC} ${DIM}(delete after first login)${NC}\n"
else
  printf "  First-run info: ${DIM}${CRED_FILE}${NC} ${DIM}(no password stored)${NC}\n"
fi
echo
printf "  ${BOLD}NEXT:${NC}\n"
if $WEB_UNAVAILABLE; then
  printf "    1. ${YELLOW}Bring up a web client first:${NC} docker compose --profile web up -d element\n"
  printf "       then open ${CYAN}${ACCESS}${NC} and log in ${DIM}(dev is localhost-only — a phone can't reach it)${NC}\n"
else
  printf "    1. Open ${CYAN}${LOGIN_URL}${NC} and log in\n"
fi
printf "    2. Save the recovery passphrase when prompted\n"
printf "    3. Accept the room invites\n"
printf "    4. Open ${BOLD}#gov-bot${NC} and type: ${CYAN}!gov status${NC}\n"
printf "    5. Read the operator guide: ${CYAN}${PUBLIC_BASE}/operator-guide${NC}\n"
printf "    6. Open the dashboard: ${CYAN}${PUBLIC_BASE}/governance/${NC}\n"
echo
if [ "$ROLE" = "core" ]; then
  FRONT_OK=false
  curl -sfk "${PUBLIC_BASE}/_matrix/client/versions" --max-time 5 >/dev/null 2>&1 && FRONT_OK=true
  if $FRONT_OK; then
    printf "  ${GREEN}Front reachable at ${PUBLIC_BASE}${NC}\n"
  else
    printf "  ${YELLOW}Front not yet reachable at ${PUBLIC_BASE}${NC}\n"
    printf "    If the front isn't deployed yet:\n"
    printf "      ansible-playbook -i inventory.ini site.yml --limit front\n"
    printf "    If already deployed, verify WireGuard + Caddy on the front host.\n"
  fi
  echo
fi
if [ "$ROLE" = "single" ]; then
  printf "  ${YELLOW}⚠ Single-host mode is NOT production-hardened.${NC}\n"
  printf "    MAS metadata scrubbing + off-box backups run only on the two-host\n"
  printf "    Ansible deploy. On this box, account-creation IPs accumulate in MAS\n"
  printf "    unbounded (F33). For a real at-risk community, deploy two-host.\n"
  echo
fi
printf "${BOLD}════════════════════════════════════════════════════${NC}\n"
