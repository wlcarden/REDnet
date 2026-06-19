#!/usr/bin/env bash
# Spike 04 — Backup -> destroy -> cold restore -> verify recoverability.
# Proves: account logs in after restore; encrypted message history survives; signing key
# preserved; and the e2e_one_time_keys_json TRUNCATE requirement is met by the exclude-dump
# (the research's silent-failure gotcha that otherwise re-issues stale keys -> decryption errors).
# Scope: Synapse + Postgres core. MAS restore (2nd DB + matched secrets.encryption) is a
# documented requirement (SPEC §9) verified by research; deferred from local spikes.
set -uo pipefail
cd "$(dirname "$0")"
BASE=http://localhost:8008
say(){ printf '\n=== %s ===\n' "$*"; }
jqpy(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
PSQL(){ docker compose exec -T postgres psql -U synapse -d synapse -tA -c "$1" 2>/dev/null | tr -d '[:space:]'; }
wait_syn(){ for i in $(seq 1 60); do curl -sf $BASE/_matrix/client/versions >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }
login(){ curl -s -XPOST $BASE/_matrix/client/v3/login -H 'Content-Type: application/json' \
  -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"bob"},"password":"password123"}' | jqpy "d.get('access_token','')"; }

rm -rf backup && mkdir -p backup
say "clean slate"; docker compose down -v >/dev/null 2>&1 || true

# ---------------- ORIGINAL ----------------
say "[orig] start + configure synapse"
docker compose up -d postgres
until docker compose exec -T postgres pg_isready -U synapse >/dev/null 2>&1; do sleep 2; done
docker compose run --rm -T synapse generate >/dev/null 2>&1
docker compose run --rm -T --entrypoint python3 synapse - <<'PY'
import yaml;p="/data/homeserver.yaml";c=yaml.safe_load(open(p))
c["database"]={"name":"psycopg2","args":{"user":"synapse","password":"synapse","database":"synapse","host":"postgres","cp_min":5,"cp_max":10}}
c["enable_registration"]=True;c["enable_registration_without_verification"]=True
c["registration_shared_secret"]="testsecret";c["report_stats"]=False
yaml.safe_dump(c,open(p,"w"));print("patched")
PY
docker compose up -d synapse; wait_syn || { echo "orig synapse failed"; docker compose logs synapse|tail -30; exit 1; }

say "[orig] create user + encrypted room + 4 messages"
docker compose exec -T synapse register_new_matrix_user -u bob -p password123 -a -k testsecret $BASE >/dev/null 2>&1 || true
TOKEN=$(login); AUTH="Authorization: Bearer $TOKEN"
ROOM=$(curl -s -XPOST $BASE/_matrix/client/v3/createRoom -H "$AUTH" -d '{"name":"recover-me"}' | jqpy "d['room_id']")
curl -s -XPUT "$BASE/_matrix/client/v3/rooms/$ROOM/state/m.room.encryption" -H "$AUTH" -d '{"algorithm":"m.megolm.v1.aes-sha2"}' >/dev/null
for i in 1 2 3 4; do curl -s -XPUT "$BASE/_matrix/client/v3/rooms/$ROOM/send/m.room.encrypted/t$i" -H "$AUTH" -d "{\"algorithm\":\"m.megolm.v1.aes-sha2\",\"ciphertext\":\"CT_$i\"}" >/dev/null; done
echo "room=$ROOM"

say "[orig] plant a stale one-time-key row (must be gone after restore)"
PSQL "SET session_replication_role=replica; INSERT INTO e2e_one_time_keys_json (user_id,device_id,algorithm,key_id,ts_added_ms,key_json) VALUES ('@bob:rednet.test','TESTDEV','signed_curve25519','AAAA',0,'{}');" >/dev/null
OTK_BEFORE=$(PSQL "SELECT count(*) FROM e2e_one_time_keys_json;")
MSGS_BEFORE=$(PSQL "SELECT count(*) FROM events WHERE room_id='$ROOM' AND type='m.room.encrypted';")
echo "stale OTK rows: $OTK_BEFORE ; encrypted msgs: $MSGS_BEFORE"

say "[backup] pg_dump (EXCLUDING e2e_one_time_keys_json data) + config + signing key"
docker compose exec -T postgres pg_dump -Fc --exclude-table-data e2e_one_time_keys_json -U synapse synapse > backup/synapse.dump
echo "db dump: $(stat -c%s backup/synapse.dump) bytes"
docker compose exec -T synapse tar c -C /data homeserver.yaml rednet.test.signing.key rednet.test.log.config > backup/data.tar
SIGN_ORIG=$(docker compose exec -T synapse sha256sum /data/rednet.test.signing.key | cut -d' ' -f1)
echo "signing.key sha (orig): ${SIGN_ORIG:0:16}..."

# ---------------- DESTROY ----------------
say "[destroy] simulate TOTAL loss (down -v wipes both volumes)"
docker compose down -v >/dev/null 2>&1

# ---------------- RESTORE ----------------
say "[restore] fresh postgres + pg_restore"
docker compose up -d postgres
until docker compose exec -T postgres pg_isready -U synapse >/dev/null 2>&1; do sleep 2; done
docker compose exec -T postgres pg_restore --no-owner -d synapse -U synapse < backup/synapse.dump >/dev/null 2>&1 \
  || docker compose exec -T postgres pg_restore --no-owner --clean --if-exists -d synapse -U synapse < backup/synapse.dump >/dev/null 2>&1
echo "db restored"

say "[restore] provision fresh /data (perms + media_store) then overlay backup config+key"
# Real-restore pattern: provision a fresh box first (sets up /data ownership + dirs), THEN
# drop in the backed-up signing key + config as the correct runtime user. Extracting straight
# into an empty volume breaks ownership -> Synapse can't create media_store (caught on first run).
docker compose run --rm -T synapse generate >/dev/null 2>&1
DUID=$(docker compose run --rm -T --entrypoint stat synapse -c '%u' /data | tr -d '[:space:]')
docker compose run --rm -T --user "${DUID:-991}" --entrypoint tar synapse x -C /data < backup/data.tar
SIGN_REST=$(docker compose run --rm -T --entrypoint sha256sum synapse /data/rednet.test.signing.key | cut -d' ' -f1)
echo "restored as uid ${DUID:-991}; signing.key sha (restored): ${SIGN_REST:0:16}..."

say "[restore] start synapse against restored data"
docker compose up -d synapse; wait_syn || { echo "RESTORED synapse failed to start"; docker compose logs synapse|tail -40; exit 1; }

# ---------------- VERIFY ----------------
say "[verify] smoke test on restored server"
TOKEN2=$(login); LOGIN_OK=no; [ -n "${TOKEN2:-}" ] && LOGIN_OK=yes
AUTH2="Authorization: Bearer $TOKEN2"
MSGS_AFTER=$(PSQL "SELECT count(*) FROM events WHERE room_id='$ROOM' AND type='m.room.encrypted';")
OTK_AFTER=$(PSQL "SELECT count(*) FROM e2e_one_time_keys_json;")
UPCODE=$(curl -s -o /dev/null -w "%{http_code}" -XPOST "$BASE/_matrix/client/v3/keys/upload" -H "$AUTH2" -d '{"one_time_keys":{}}')
echo "login after restore: $LOGIN_OK"
echo "encrypted msgs : before=$MSGS_BEFORE after=$MSGS_AFTER"
echo "OTK rows       : before=$OTK_BEFORE after=$OTK_AFTER (expect 0)"
echo "signing.key    : $([ "$SIGN_ORIG" = "$SIGN_REST" ] && echo preserved || echo CHANGED)"
echo "keys/upload    : HTTP $UPCODE (E2EE machinery alive post-restore)"

say "VERDICT"
PASS=1
[ "$LOGIN_OK" = yes ] || { PASS=0; echo "FAIL: cannot log in after restore"; }
[ "${MSGS_AFTER:-0}" = "${MSGS_BEFORE:-x}" ] || { PASS=0; echo "FAIL: encrypted history not fully restored ($MSGS_BEFORE->$MSGS_AFTER)"; }
[ "${OTK_AFTER:-1}" = "0" ] || { PASS=0; echo "FAIL: e2e_one_time_keys_json NOT empty ($OTK_AFTER) — TRUNCATE requirement unmet"; }
[ "$SIGN_ORIG" = "$SIGN_REST" ] || { PASS=0; echo "FAIL: signing key changed across restore"; }
[ "$UPCODE" = 200 ] || { PASS=0; echo "FAIL: keys/upload broken on restored server (HTTP $UPCODE)"; }
[ "$PASS" = 1 ] && echo "PASS: account + encrypted history recovered; signing key preserved; stale one-time-keys purged by the exclude-dump; E2EE key upload works post-restore."
echo; echo "(stack left up; 'docker compose down -v' to clean)"
