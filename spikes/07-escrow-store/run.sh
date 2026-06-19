#!/usr/bin/env bash
# Spike 07 — Matrix-native escrow store + producer round-trip. Self-contained Synapse on :8010.
set -uo pipefail
cd "$(dirname "$0")"
BASE=http://localhost:8010
say(){ printf '\n=== %s ===\n' "$*"; }

if ! curl -sf $BASE/_matrix/client/versions >/dev/null 2>&1; then
  say "start postgres + synapse (:8010)"
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

say "register alice (member)"
docker compose exec -T synapse register_new_matrix_user -u alice -p password123 -a -k testsecret http://localhost:8008 >/dev/null 2>&1 || true

say "run escrow store round-trip"
rm -f result.json
HS=$BASE uv run --quiet --with cryptography --with pycryptodome --with requests python3 spike.py
RC=$?
echo; echo "(stack left up; 'docker compose down -v' to clean)"
exit $RC
