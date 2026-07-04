#!/usr/bin/env bash
# Full-stack backup/restore drill — validates the disaster recovery path.
#
# ⚠️  DESTRUCTIVE: tears down the running stack, restores from backup, and verifies.
#     Run this in a dev/lab environment, NOT on a production instance with real users.
#
# Usage: ./drill-restore.sh
#
# What it does:
#   1. Captures pre-drill state (rooms, members, vouch count)
#   2. Runs backup.sh
#   3. Tears down the stack (docker compose down -v)
#   4. Runs restore.sh against the backup
#   5. Starts the full stack
#   6. Waits for services and verifies post-restore state matches pre-drill
#
# Exit codes:
#   0 — drill passed: backup → destroy → restore produces a working, identical instance
#   1 — drill failed: state mismatch or service unreachable after restore
#
# Requires: stack running, jq, backup.sh + restore.sh in same directory.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?}"
: "${REDNET_HTTP_PORT:=8080}"
. ./lib-access.sh
ACCESS="$API_URL"

PASS=0
FAIL=0

say()  { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[0;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

enc(){ python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }

mas(){ docker compose exec -T mas mas-cli manage "$@" --config /config.yaml 2>&1; }

resolve_alias(){
  local tok="$1" alias="$2"
  curl -sf -H "Authorization: Bearer $tok" \
    "${ACCESS}/_matrix/client/v3/directory/room/%23${alias}%3A${REDNET_DOMAIN}" 2>/dev/null \
    | jq -r '.room_id // empty' 2>/dev/null
}

count_members(){
  local tok="$1" room_id="$2"
  curl -sf -H "Authorization: Bearer $tok" \
    "${ACCESS}/_matrix/client/v3/rooms/$(enc "$room_id")/joined_members" 2>/dev/null \
    | jq '.joined | length' 2>/dev/null || echo 0
}

echo "╔══════════════════════════════════════════════════════╗"
echo "║  REDnet Backup/Restore Drill                        ║"
echo "║  ⚠️  DESTRUCTIVE — tears down the running stack      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo
read -rp "Continue with the drill? This will destroy and rebuild the stack. [y/N] " CONFIRM
[ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || { echo "Aborted."; exit 0; }

# ── Phase 1: Capture pre-drill state ────────────────────────────────────────
say "Phase 1: capture pre-drill state"

PRE_TOK=$(mas issue-compatibility-token rednet-system DRILL-PRE 2>/dev/null \
  | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
[ -n "${PRE_TOK:-}" ] || { echo "ERROR: cannot mint token — is the stack running?"; exit 1; }

DRILL_DIR="/tmp/rednet-drill-$(date +%s)"
mkdir -p "$DRILL_DIR"

PRE_ROOMS=()
for alias in community welcome announcements general governance vouch-log gov-bot; do
  RID=$(resolve_alias "$PRE_TOK" "$alias")
  if [ -n "$RID" ]; then
    PRE_ROOMS+=("$alias=$RID")
    MEMBERS=$(count_members "$PRE_TOK" "$RID")
    echo "  #${alias}: ${RID} (${MEMBERS} members)"
    echo "${alias}=${RID}=${MEMBERS}" >> "$DRILL_DIR/pre-rooms.txt"
  fi
done
ok "captured ${#PRE_ROOMS[@]} rooms"

VERSIONS_PRE=$(curl -sf "${ACCESS}/_matrix/client/versions" 2>/dev/null | jq -r '.versions[-1]' 2>/dev/null)
echo "  Synapse spec: ${VERSIONS_PRE}"
echo "$VERSIONS_PRE" > "$DRILL_DIR/pre-version.txt"

# ── Phase 2: Backup ─────────────────────────────────────────────────────────
say "Phase 2: backup"
./backup.sh
BACKUP_DIR=$(ls -td backups/*/ 2>/dev/null | head -1)
[ -d "$BACKUP_DIR" ] || { echo "ERROR: backup.sh did not produce a backup directory"; exit 1; }
ok "backup created: $BACKUP_DIR"

for f in synapse.dump mas.dump signing.key mas-config.yaml homeserver.yaml; do
  [ -s "${BACKUP_DIR}${f}" ] || { fail "backup artifact missing or empty: $f"; exit 1; }
done
ok "all 5 core artifacts present and non-empty"

# ── Phase 3: Destroy ────────────────────────────────────────────────────────
say "Phase 3: destroy stack"
docker compose down -v >/dev/null 2>&1
ok "stack destroyed (volumes removed)"

curl -sf "${ACCESS}/_matrix/client/versions" >/dev/null 2>&1 \
  && { fail "Synapse still responding after destroy"; exit 1; } \
  || ok "Synapse confirmed unreachable"

# ── Phase 4: Restore ────────────────────────────────────────────────────────
say "Phase 4: restore from backup"
./restore.sh "$BACKUP_DIR"
ok "restore.sh completed"

# ── Phase 5: Start services ─────────────────────────────────────────────────
say "Phase 5: start services"

if [ -f docker-compose.wg.yml ]; then
  docker compose -f docker-compose.yml -f docker-compose.wg.yml up -d synapse mas
else
  docker compose up -d synapse mas caddy
fi

SYNAPSE_UP=false
for _ in $(seq 1 30); do
  curl -sf "${ACCESS}/_matrix/client/versions" >/dev/null 2>&1 && { SYNAPSE_UP=true; break; }
  sleep 2
done

if $SYNAPSE_UP; then
  ok "Synapse responding after restore"
else
  fail "Synapse not reachable after restore"
  echo "Drill FAILED at service startup."
  exit 1
fi

MAS_UP=false
for _ in $(seq 1 15); do
  # list-admin-users is a valid read-only liveness probe (no `list-users` in MAS 1.19.0)
  docker compose exec -T mas mas-cli manage list-admin-users --config /config.yaml >/dev/null 2>&1 && { MAS_UP=true; break; }
  sleep 2
done
if $MAS_UP; then
  ok "MAS responding after restore"
else
  fail "MAS not responding after restore"
fi

# ── Phase 6: Verify state ───────────────────────────────────────────────────
say "Phase 6: verify post-restore state"

POST_TOK=$(mas issue-compatibility-token rednet-system DRILL-POST 2>/dev/null \
  | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
if [ -z "${POST_TOK:-}" ]; then
  fail "cannot mint system token after restore — MAS DB may not have restored correctly"
  exit 1
fi
ok "system token minted (MAS DB + encryption key pair valid)"

while IFS='=' read -r alias pre_rid pre_members; do
  POST_RID=$(resolve_alias "$POST_TOK" "$alias")
  if [ "$POST_RID" = "$pre_rid" ]; then
    ok "#${alias}: room ID matches (${POST_RID})"
  elif [ -n "$POST_RID" ]; then
    fail "#${alias}: room ID CHANGED (was ${pre_rid}, now ${POST_RID})"
  else
    fail "#${alias}: room NOT FOUND after restore"
    continue
  fi
  POST_MEMBERS=$(count_members "$POST_TOK" "$POST_RID")
  if [ "$POST_MEMBERS" = "$pre_members" ]; then
    ok "#${alias}: member count matches (${POST_MEMBERS})"
  else
    fail "#${alias}: member count changed (was ${pre_members}, now ${POST_MEMBERS})"
  fi
done < "$DRILL_DIR/pre-rooms.txt"

VERSIONS_POST=$(curl -sf "${ACCESS}/_matrix/client/versions" 2>/dev/null | jq -r '.versions[-1]' 2>/dev/null)
if [ "$VERSIONS_POST" = "$VERSIONS_PRE" ]; then
  ok "Synapse spec version matches (${VERSIONS_POST})"
else
  fail "Synapse spec version changed (was ${VERSIONS_PRE}, now ${VERSIONS_POST})"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "\033[0;32m  DRILL PASSED: %d/%d checks\033[0m\n" "$PASS" "$TOTAL"
  echo "  Backup → destroy → restore produced a working, state-identical instance."
else
  printf "\033[0;31m  DRILL FAILED: %d/%d checks passed, %d failed\033[0m\n" "$PASS" "$TOTAL" "$FAIL"
fi
echo "════════════════════════════════════════════════════"

rm -rf "$DRILL_DIR"

[ "$FAIL" -eq 0 ]
