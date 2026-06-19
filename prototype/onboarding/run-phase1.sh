#!/usr/bin/env bash
# Phase-1 recovery proof runner. Reuses the milestone-A password-login Synapse harness
# (auth is orthogonal to 4S recovery — MAS delegation is proven separately in onboarding-mas/).
set -uo pipefail
cd "$(dirname "$0")"
BASE=http://localhost:8008
say(){ printf '\n=== %s ===\n' "$*"; }

if ! curl -sf $BASE/_matrix/client/versions >/dev/null 2>&1; then
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
fi
curl -sf $BASE/_matrix/client/versions >/dev/null 2>&1 || { echo "synapse down"; docker compose logs synapse|tail -20; exit 1; }

say "register alice (idempotent)"
docker compose exec -T synapse register_new_matrix_user -u alice -p password123 -a -k testsecret $BASE >/dev/null 2>&1 || true
[ -d node_modules/matrix-js-sdk ] || npm install --no-fund --no-audit --silent

say "run Phase-1 recovery proof (two devices, passphrase-only recovery)"
rm -f result-phase1.json
RUST_LOG=error HS=$BASE LOCALPART=alice PASS=password123 node phase1-recovery.mjs 2>&1 \
  | grep -vE 'FetchHttpApi|RustBackupManager|matrix_sdk_crypto|^ *(at|in) |Perf|Downloading|Initialising|Opening|Init Olm|Completed|Calling .setAccountData|GET |POST |PUT '
RC=${PIPESTATUS[0]}
say "result-phase1.json"; cat result-phase1.json 2>/dev/null
echo; echo "(stack left up; 'docker compose down -v' to clean)"
exit $RC
