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
# This is a FRESH-DEPLOY script. setup.sh renders configs and starts the stack from
# scratch. Do not run against an existing deployment you want to keep.
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

while [ $# -gt 0 ]; do
  case "$1" in
    --operator)      OPERATOR_USERNAME="$2"; shift 2 ;;
    --skip-element)  SKIP_ELEMENT=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--operator <username>] [--skip-element]"
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
# --dev flag on deploy.sh itself → single-host dev mode
for arg in "$@"; do [ "$arg" = "--dev" ] && ROLE=single; done
ACCESS="http://localhost:${REDNET_HTTP_PORT}"
PUBLIC_BASE="${REDNET_PUBLIC_BASE:-$ACCESS}"

ok "REDNET_DOMAIN=${REDNET_DOMAIN}"
ok "REDNET_HTTP_PORT=${REDNET_HTTP_PORT}"
ok "REDNET_ROLE=${ROLE}"
[ "$ROLE" = "core" ] && ok "CORE mode — no Element Web, no front-facing ports"

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

if [ "$ROLE" = "single" ]; then
  ./setup.sh --dev || die "setup.sh failed — check the output above"
else
  ./setup.sh || die "setup.sh failed — check the output above"
fi
ok "stack running, rooms bootstrapped"

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
if [ "$ROLE" = "core" ]; then
  warn "CORE mode — skipping Element Web (the FRONT serves it)"
elif $SKIP_ELEMENT; then
  warn "Element Web skipped (--skip-element). Use Element X on mobile to log in."
  warn "  Server address: ${REDNET_DOMAIN}"
elif docker compose --profile web ps --format '{{.Name}}' 2>/dev/null | grep -q element; then
  ok "Element Web already running"
else
  say "Element Web (soft-fork build — this takes 3-5 minutes)"
  ./element-web/build.sh || { warn "Element Web build failed — web login unavailable. Use Element X on mobile."; }
  docker compose --profile web up -d element 2>/dev/null
  # wait for element container to respond
  for _ in $(seq 1 30); do
    curl -sf "${ACCESS}/" -o /dev/null 2>/dev/null && break
    sleep 2
  done
  if curl -sf "${ACCESS}/" -o /dev/null 2>/dev/null; then
    ok "Element Web serving at ${ACCESS}/"
  else
    warn "Element Web not responding — check: docker compose logs element"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════════
# PHASE 5: OPERATOR ACCOUNT
# ════════════════════════════════════════════════════════════════════════════════
say "operator account: ${OPERATOR_USERNAME}"

OPERATOR_PW=$(genpw)

# Register via MAS (deploy.sh controls the password so it can write to credentials file)
REG_RESULT=$(mas register-user "$OPERATOR_USERNAME" --password "$OPERATOR_PW" --yes --ignore-password-complexity 2>&1)
if echo "$REG_RESULT" | grep -qi "already exists"; then
  warn "account already exists — generating a new password"
  # Set a new password for the existing account
  mas set-password "$OPERATOR_USERNAME" --password "$OPERATOR_PW" --yes 2>&1 | tail -1
else
  ok "account created"
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
    resolve_room(){
      curl -s -H "$SAUTH" "$ACCESS/_matrix/client/v3/directory/room/%23${1}%3A${REDNET_DOMAIN}" \
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
      curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$room_id")/send/m.room.message/$(txn_id)" \
        -H "$SAUTH" -H "Content-Type: application/json" -d "$payload"
    }
    update_topic(){
      local room_id="$1" topic="$2"
      curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$room_id")/state/m.room.topic/" \
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
        curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$WELCOME_ID")/state/m.room.pinned_events/" \
          -H "$SAUTH" -H "Content-Type: application/json" \
          -d "$(jq -n --arg eid "$WELCOME_EID" '{pinned:[$eid]}')" >/dev/null 2>&1
        ok "#welcome — founder setup (pinned)"
      else
        warn "#welcome — message send failed"
      fi
    fi

    # ── #gov-bot: operational checklist ──
    GOV_BOT_ID=$(resolve_room gov-bot)
    if [ -n "$GOV_BOT_ID" ]; then
      # gov-bot was created by @rednet-gov, system may not be in it — invite first
      GOV_TOK=$(mas issue-compatibility-token rednet-gov DEPLOYMSG2 | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
      if [ -n "$GOV_TOK" ]; then
        GAUTH="Authorization: Bearer $GOV_TOK"
        curl -s -XPOST "$ACCESS/_matrix/client/v3/rooms/$(enc "$GOV_BOT_ID")/invite" \
          -H "$GAUTH" -H "Content-Type: application/json" \
          -d "$(jq -n --arg u "@rednet-system:$REDNET_DOMAIN" '{user_id:$u}')" >/dev/null 2>&1
        curl -s -XPOST "$ACCESS/_matrix/client/v3/join/$(enc "$GOV_BOT_ID")" \
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

      send_msg "$GOV_BOT_ID" "m.notice" "$CHECKLIST_BODY" >/dev/null 2>&1 \
        && ok "#gov-bot — operational checklist" \
        || warn "#gov-bot — message send failed"
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
      curl -s -XPUT "$ACCESS/_matrix/client/v3/rooms/$(enc "$GOV_BOT_ID")/state/m.room.topic/" \
        -H "Authorization: Bearer $GOV_TOK" -H "Content-Type: application/json" \
        -d "$(jq -n --arg t "Bot commands — type !gov help. Dashboard: ${PUBLIC_BASE}/governance/ · Non-E2EE by design (bot can't decrypt)." '{topic:$t}')" >/dev/null 2>&1 \
        && ok "#gov-bot topic updated"
    fi

    VOUCHLOG_ID=$(resolve_room vouch-log)
    [ -n "$VOUCHLOG_ID" ] && update_topic "$VOUCHLOG_ID" \
      "Append-only audit trail: vouches, claims, role changes, revocations. Retention-exempt — do not delete events." \
      && ok "#vouch-log topic updated"

    touch .deploy-messages-posted
  fi
fi

# ════════════════════════════════════════════════════════════════════════════════
# PHASE 7: CREDENTIALS
# ════════════════════════════════════════════════════════════════════════════════
say "credentials"

CRED_FILE=".first-run-credentials"
cat > "$CRED_FILE" <<CREDS
REDnet first-run credentials
Generated: $(now_iso)
DELETE THIS FILE after your first login.

Username:  ${OPERATOR_USERNAME}
User ID:   ${OPERATOR_ID}
Password:  ${OPERATOR_PW}
Login URL: ${ACCESS}

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
ok "credentials → ${CRED_FILE}"

# ════════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════════════════════════
echo
printf "${BOLD}════════════════════════════════════════════════════${NC}\n"
printf "${BOLD}  ${RED}RED${NC}${DIM}net${NC}${BOLD} deployed${NC}\n"
printf "${BOLD}════════════════════════════════════════════════════${NC}\n"
echo
printf "  Login:     ${CYAN}${ACCESS}${NC}\n"
printf "  Account:   ${BOLD}${OPERATOR_ID}${NC}  (PL100 admin)\n"
printf "  Password:  ${BOLD}${OPERATOR_PW}${NC}\n"
echo
printf "  ${YELLOW}⚠ TWO SECRETS TO SAVE:${NC}\n"
printf "    ${BOLD}1.${NC} The password above — log in with it now\n"
printf "    ${BOLD}2.${NC} A ${BOLD}RECOVERY PASSPHRASE${NC} — Element shows it\n"
printf "       on first login. Write it on paper or put\n"
printf "       it in a password manager.\n"
echo
printf "  Credentials saved to: ${DIM}${CRED_FILE}${NC}\n"
printf "  ${DIM}(delete after first login)${NC}\n"
echo
printf "  ${BOLD}NEXT:${NC}\n"
printf "    1. Open ${CYAN}${ACCESS}${NC} and log in\n"
printf "    2. Save the recovery passphrase when prompted\n"
printf "    3. Accept the room invites\n"
printf "    4. Open ${BOLD}#gov-bot${NC} and type: ${CYAN}!gov status${NC}\n"
printf "    5. Read the operator guide: ${CYAN}${PUBLIC_BASE}/operator-guide${NC}\n"
printf "    6. Open the dashboard: ${CYAN}${PUBLIC_BASE}/governance/${NC}\n"
echo
if [ "$ROLE" = "core" ]; then
  printf "  ${YELLOW}CORE MODE — next steps:${NC}\n"
  printf "    • Set up WireGuard between CORE and FRONT\n"
  printf "    • Deploy the FRONT (Caddy + Element Web + TLS)\n"
  printf "    • Log in via the FRONT's public URL\n"
  echo
fi
printf "${BOLD}════════════════════════════════════════════════════${NC}\n"
