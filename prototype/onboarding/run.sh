#!/usr/bin/env bash
# PWA milestone A runner: stand up Synapse, register a user, run the silent-bootstrap proof.
set -uo pipefail
cd "$(dirname "$0")"
BASE=http://localhost:8008
say(){ printf '\n=== %s ===\n' "$*"; }

say "clean slate"; docker compose down -v >/dev/null 2>&1 || true

say "start postgres + synapse"
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
docker compose up -d synapse
for i in $(seq 1 60); do curl -sf $BASE/_matrix/client/versions >/dev/null 2>&1 && break; sleep 2; done
curl -sf $BASE/_matrix/client/versions >/dev/null 2>&1 || { echo "synapse failed"; docker compose logs synapse|tail -30; exit 1; }
echo "synapse up"

say "register test user (native, shared secret)"
docker compose exec -T synapse register_new_matrix_user -u alice -p password123 -a -k testsecret $BASE >/dev/null 2>&1 || true

say "install matrix-js-sdk (first run only)"
[ -d node_modules/matrix-js-sdk ] || npm install --no-fund --no-audit --silent

say "run the silent-bootstrap proof"
rm -f result.json
RUST_LOG=error HS=$BASE LOCALPART=alice PASS=password123 node onboard.mjs 2>&1 | grep -vE 'FetchHttpApi|RustBackupManager|matrix_sdk_crypto|^ *(at|in) |Perf|Downloading|Initialising|Opening|Init Olm|Completed|Calling .setAccountData'
RC=${PIPESTATUS[0]}
say "result.json"
cat result.json 2>/dev/null || echo "(no result file written)"

echo
echo "(stack left up; 'docker compose down -v' to clean)"
exit $RC
