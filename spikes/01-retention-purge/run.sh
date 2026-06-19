#!/usr/bin/env bash
# Spike 01 — GATING: does Synapse retention actually PURGE message events in an ENCRYPTED room?
# Tests BOTH the server-wide default_policy and a per-room m.room.retention override
# (the mechanism the Draupnir preset bot uses). Verdict = did m.room.encrypted events drop?
set -uo pipefail
cd "$(dirname "$0")"
BASE=http://localhost:8008
say(){ printf '\n=== %s ===\n' "$*"; }
jqpy(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

say "clean slate"
docker compose down -v >/dev/null 2>&1 || true

say "start postgres"
docker compose up -d postgres
until docker compose exec -T postgres pg_isready -U synapse >/dev/null 2>&1; do sleep 2; done
echo "postgres ready"

say "generate synapse config"
docker compose run --rm -T synapse generate >/dev/null 2>&1
echo "generated"

say "patch config: postgres + registration + aggressive retention"
docker compose run --rm -T --entrypoint python3 synapse - <<'PY'
import yaml
p="/data/homeserver.yaml"; c=yaml.safe_load(open(p))
c["database"]={"name":"psycopg2","args":{"user":"synapse","password":"synapse","database":"synapse","host":"postgres","cp_min":5,"cp_max":10}}
c["enable_registration"]=True
c["enable_registration_without_verification"]=True
c["registration_shared_secret"]="testsecret"
c["report_stats"]=False
c["retention"]={"enabled":True,
  "default_policy":{"max_lifetime":"1m"},
  "allowed_lifetime_min":"1s","allowed_lifetime_max":"30d",
  "purge_jobs":[{"interval":"10s"}]}
yaml.safe_dump(c,open(p,"w"))
print("patched: default_policy max_lifetime=1m, purge interval=10s")
PY

say "start synapse"
docker compose up -d synapse
echo "waiting for synapse http..."
for i in $(seq 1 60); do curl -sf $BASE/_matrix/client/versions >/dev/null 2>&1 && break; sleep 2; done
if ! curl -sf $BASE/_matrix/client/versions >/dev/null 2>&1; then
  echo "SYNAPSE FAILED TO START"; docker compose logs synapse | tail -50; exit 1
fi
echo "synapse up"

say "register + login test user"
docker compose exec -T synapse register_new_matrix_user -u alice -p password123 -a -k testsecret $BASE >/dev/null 2>&1 || true
TOKEN=$(curl -s -XPOST $BASE/_matrix/client/v3/login -H 'Content-Type: application/json' \
  -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"alice"},"password":"password123"}' | jqpy "d['access_token']")
[ -n "${TOKEN:-}" ] || { echo "LOGIN FAILED"; exit 1; }
AUTH="Authorization: Bearer $TOKEN"; echo "logged in"

say "create encrypted room + per-room retention override (the preset path)"
ROOM=$(curl -s -XPOST $BASE/_matrix/client/v3/createRoom -H "$AUTH" -d '{"name":"spike01"}' | jqpy "d['room_id']")
echo "room: $ROOM"
curl -s -XPUT "$BASE/_matrix/client/v3/rooms/$ROOM/state/m.room.encryption" -H "$AUTH" -d '{"algorithm":"m.megolm.v1.aes-sha2"}' >/dev/null
curl -s -XPUT "$BASE/_matrix/client/v3/rooms/$ROOM/state/m.room.retention"  -H "$AUTH" -d '{"max_lifetime":60000}' >/dev/null
echo "room encrypted; per-room m.room.retention max_lifetime=60000ms set"

say "send 6 ENCRYPTED message events"
for i in $(seq 1 6); do
  curl -s -XPUT "$BASE/_matrix/client/v3/rooms/$ROOM/send/m.room.encrypted/txn$i" -H "$AUTH" \
    -d "{\"algorithm\":\"m.megolm.v1.aes-sha2\",\"ciphertext\":\"DUMMYCIPHERTEXT_$i\",\"sender_key\":\"sk\",\"session_id\":\"si\",\"device_id\":\"DEV\"}" >/dev/null
done
echo "sent 6 m.room.encrypted events"

enccount(){ docker compose exec -T postgres psql -U synapse -d synapse -tA -c \
  "SELECT count(*) FROM events WHERE room_id='$ROOM' AND type='m.room.encrypted';" | tr -d '[:space:]'; }
bytype(){ docker compose exec -T postgres psql -U synapse -d synapse -tA -c \
  "SELECT type||' = '||count(*) FROM events WHERE room_id='$ROOM' GROUP BY type ORDER BY type;"; }

say "DB state BEFORE purge (events by type)"
bytype
BEFORE=$(enccount); echo "m.room.encrypted BEFORE: $BEFORE"

say "wait for purge (lifetime 60s + interval 10s); poll up to 150s"
AFTER=$BEFORE
for i in $(seq 1 15); do
  sleep 10; AFTER=$(enccount)
  echo "  t+$((i*10))s: m.room.encrypted = $AFTER"
  [ "${AFTER:-0}" -lt "${BEFORE:-0}" ] && break
done

say "DB state AFTER (events by type)"
bytype

say "VERDICT"
if [ "${AFTER:-0}" -lt "${BEFORE:-0}" ]; then
  echo "PASS: encrypted message events purged ($BEFORE -> $AFTER)."
  echo "Expected residue: state events (member/encryption/create/power_levels) persist by design,"
  echo "and Synapse never deletes the room's last message — so AFTER may be 0 or 1, not negative-proof."
else
  echo "FAIL: encrypted message events did NOT purge ($BEFORE -> $AFTER) within 150s."
  echo "If this reproduces, it confirms the SPEC §6 caveat — retention silently no-ops on encrypted rooms."
fi

say "synapse purge/retention log lines"
docker compose logs synapse 2>&1 | grep -iE "purg|retention" | tail -20 || echo "(none found)"

echo
echo "(leaving stack up for inspection; 'docker compose down -v' in this dir to clean up)"
