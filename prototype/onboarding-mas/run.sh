#!/usr/bin/env bash
# PWA milestone B — MAS+Synapse delegation + NO-PII account creation + silent bootstrap.
# Proves the full SPEC §5 Track A chain end-to-end:
#   MAS creates a no-PII account -> MAS issues a token -> Synapse ACCEPTS it (delegation)
#   -> silent E2EE bootstrap (milestone A) succeeds on that account.
set -uo pipefail
cd "$(dirname "$0")"
SYN=http://localhost:8008
MASIMG=ghcr.io/element-hq/matrix-authentication-service:latest
say(){ printf '\n=== %s ===\n' "$*"; }
jqpy(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

say "clean slate"; docker compose down -v >/dev/null 2>&1 || true; rm -f result.json
mkdir -p mas initdb

say "generate + patch MAS config"
docker run --rm $MASIMG config generate 2>/dev/null > mas/config.yaml
MAS_SECRET=$(uv run --quiet --with pyyaml python3 - <<'PY'
import yaml
p="mas/config.yaml"; c=yaml.safe_load(open(p))
c["database"]={"uri":"postgresql://synapse:synapse@postgres/mas"}
c["http"]["public_base"]="http://localhost:8080/"
c["http"]["issuer"]="http://localhost:8080/"
c["matrix"]["homeserver"]="rednet.test"
c["matrix"]["endpoint"]="http://synapse:8008/"
yaml.safe_dump(c,open(p,"w"))
print(c["matrix"]["secret"])
PY
)
echo "shared secret: ${MAS_SECRET:0:8}..."

say "start postgres (synapse + mas DBs)"
docker compose up -d postgres
until docker compose exec -T postgres pg_isready -U synapse >/dev/null 2>&1; do sleep 2; done
docker compose exec -T postgres psql -U synapse -d postgres -tAc "SELECT datname FROM pg_database WHERE datname IN ('synapse','mas');" | tr '\n' ' '; echo

say "MAS: migrate + start"
docker compose run --rm -T mas database migrate --config /config.yaml 2>&1 | tail -2 || echo "(migrate step note)"
docker compose up -d mas
for i in $(seq 1 30); do curl -sf http://localhost:8080/.well-known/openid-configuration >/dev/null 2>&1 && break; sleep 2; done
curl -sf http://localhost:8080/.well-known/openid-configuration >/dev/null 2>&1 && echo "MAS up (OIDC discovery responding)" || { echo "MAS NOT UP"; docker compose logs mas|tail -30; exit 1; }

say "Synapse: generate + delegate auth to MAS"
docker compose run --rm -T synapse generate >/dev/null 2>&1
MAS_SECRET="$MAS_SECRET" docker compose run --rm -T -e MAS_SECRET --entrypoint python3 synapse - <<'PY'
import yaml,os
p="/data/homeserver.yaml"; c=yaml.safe_load(open(p))
c["database"]={"name":"psycopg2","args":{"user":"synapse","password":"synapse","database":"synapse","host":"postgres","cp_min":5,"cp_max":10}}
c["report_stats"]=False; c["public_baseurl"]="http://localhost:8008/"
open("/data/mas_shared_secret","w").write(os.environ["MAS_SECRET"])
c["matrix_authentication_service"]={"enabled":True,"endpoint":"http://mas:8080","secret_path":"/data/mas_shared_secret"}
c["password_config"]={"enabled":False}
c.pop("enable_registration",None); c.pop("registration_shared_secret",None)
yaml.safe_dump(c,open(p,"w")); print("patched: delegating to MAS")
PY
docker compose up -d synapse
for i in $(seq 1 60); do curl -sf $SYN/_matrix/client/versions >/dev/null 2>&1 && break; sleep 2; done
curl -sf $SYN/_matrix/client/versions >/dev/null 2>&1 || { echo "SYNAPSE FAILED"; docker compose logs synapse|tail -50; exit 1; }
echo "synapse up, delegating to MAS"

say "create a NO-PII user via MAS (username + ephemeral password, NO email)"
PW=$(head -c16 /dev/urandom | base64)
docker compose exec -T mas mas-cli manage register-user alice --password "$PW" --yes --ignore-password-complexity --config /config.yaml 2>&1 | tail -3

say "mint a Matrix token via MAS (issue-compatibility-token)"
TOKOUT=$(docker compose exec -T mas mas-cli manage issue-compatibility-token alice ONBOARDDEV --config /config.yaml 2>&1)
echo "$TOKOUT" | tail -4
TOKEN=$(echo "$TOKOUT" | grep -oE '(mct_|syt_|mat_)[A-Za-z0-9_]+' | head -1)
[ -z "${TOKEN:-}" ] && TOKEN=$(echo "$TOKOUT" | grep -oE '[A-Za-z0-9_]{40,}' | head -1)
echo "parsed token: ${TOKEN:0:14}..."

say "PROVE DELEGATION: whoami through Synapse with the MAS-issued token"
WHO=$(curl -s -H "Authorization: Bearer $TOKEN" $SYN/_matrix/client/v3/account/whoami | jqpy "d.get('user_id','')")
echo "whoami -> ${WHO:-<failed>}"
[ "$WHO" = "@alice:rednet.test" ] || { echo "DELEGATION FAILED (Synapse did not accept the MAS token)"; exit 1; }

say "verify NO PII (no email in MAS)"
EMAILS=$(docker compose exec -T postgres psql -U synapse -d mas -tAc "SELECT count(*) FROM user_emails;" 2>/dev/null | tr -d '[:space:]')
echo "MAS user_emails rows: ${EMAILS:-?} (expect 0)"

say "install matrix-js-sdk"; [ -d node_modules/matrix-js-sdk ] || npm install --no-fund --no-audit --silent

say "SILENT bootstrap on the MAS-created account"
HS=$SYN USER_ID="$WHO" ACCESS_TOKEN="$TOKEN" DEVICE_ID=ONBOARDDEV node onboard-token.mjs 2>&1 | grep -E '===|crypto initialized|bootstrapped|PASS|fatal|ERROR'
RC=${PIPESTATUS[0]}
say "result.json"; cat result.json 2>/dev/null || echo "(none)"
echo; echo "(stack left up; 'docker compose down -v' to clean)"
exit ${RC:-1}
