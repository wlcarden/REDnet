#!/usr/bin/env bash
# Spike 03 — Two-tier topology + media through the proxy hop.
# Verifies: (1) the CORE (Synapse+Postgres) has NO published host ports; (2) the FRONT
# (Caddy) is the only public face; (3) a client can register/login and ROUND-TRIP a 10MB
# media file end-to-end through the front, byte-identical.
# NOTE: the WireGuard MSS/PMTU upload-hang is a real-network concern a local bridge can't
# reproduce — that stays a deployment-time check. This validates the proxy/body-size layer.
set -uo pipefail
cd "$(dirname "$0")"
PROJ=rednet-spike-03
FRONT=http://localhost:8080
say(){ printf '\n=== %s ===\n' "$*"; }
jqpy(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

say "clean slate"; docker compose down -v >/dev/null 2>&1 || true

say "start postgres (core)"
docker compose up -d postgres
until docker compose exec -T postgres pg_isready -U synapse >/dev/null 2>&1; do sleep 2; done
echo "postgres ready"

say "generate + patch synapse config"
docker compose run --rm -T synapse generate >/dev/null 2>&1
docker compose run --rm -T --entrypoint python3 synapse - <<'PY'
import yaml; p="/data/homeserver.yaml"; c=yaml.safe_load(open(p))
c["database"]={"name":"psycopg2","args":{"user":"synapse","password":"synapse","database":"synapse","host":"postgres","cp_min":5,"cp_max":10}}
c["enable_registration"]=True; c["enable_registration_without_verification"]=True
c["registration_shared_secret"]="testsecret"; c["report_stats"]=False
c["public_baseurl"]="http://localhost:8080/"
for l in c.get("listeners",[]):
    if l.get("port")==8008: l["x_forwarded"]=True   # trust the Caddy hop
yaml.safe_dump(c,open(p,"w")); print("patched (x_forwarded on; public_baseurl via front)")
PY

say "start synapse (core, no ports) + caddy (front, :8080)"
docker compose up -d synapse caddy
echo "waiting for front -> synapse ..."
for i in $(seq 1 60); do curl -sf $FRONT/_matrix/client/versions >/dev/null 2>&1 && break; sleep 2; done
curl -sf $FRONT/_matrix/client/versions >/dev/null 2>&1 || { echo "FRONT UNREACHABLE"; docker compose logs caddy synapse | tail -50; exit 1; }
echo "client-server API reachable via the front"

say "ISOLATION — published host ports in this project"
docker ps --filter "label=com.docker.compose.project=$PROJ" --format '{{.Names}} :: {{.Ports}}'
PUBLISHED=$(docker ps --filter "label=com.docker.compose.project=$PROJ" --format '{{.Names}} {{.Ports}}' | grep -c '0\.0\.0\.0' || true)
PUBNONCADDY=$(docker ps --filter "label=com.docker.compose.project=$PROJ" --format '{{.Names}} {{.Ports}}' | grep '0\.0\.0\.0' | grep -vc caddy || true)

say "register (core-internal admin) + login THROUGH the front"
docker compose exec -T synapse register_new_matrix_user -u bob -p password123 -a -k testsecret http://localhost:8008 >/dev/null 2>&1 || true
TOKEN=$(curl -s -XPOST $FRONT/_matrix/client/v3/login -H 'Content-Type: application/json' \
  -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"bob"},"password":"password123"}' | jqpy "d['access_token']")
[ -n "${TOKEN:-}" ] || { echo "LOGIN THROUGH FRONT FAILED"; exit 1; }
AUTH="Authorization: Bearer $TOKEN"; echo "logged in via the front"

say "MEDIA round-trip through the front (10 MB, sha256-checked)"
head -c 10485760 /dev/urandom > /tmp/spike03_up.bin
UPSHA=$(sha256sum /tmp/spike03_up.bin | cut -d' ' -f1)
MXC=$(curl -s -XPOST "$FRONT/_matrix/media/v3/upload?filename=blob.bin" -H "$AUTH" \
  -H 'Content-Type: application/octet-stream' --data-binary @/tmp/spike03_up.bin | jqpy "d['content_uri']")
echo "uploaded -> ${MXC:-<none>}"
[ -n "${MXC:-}" ] || { echo "UPLOAD THROUGH FRONT FAILED"; docker compose logs caddy synapse | tail -30; exit 1; }
MID="${MXC#mxc://rednet.test/}"
curl -s -H "$AUTH" "$FRONT/_matrix/client/v1/media/download/rednet.test/$MID" -o /tmp/spike03_down.bin
DOWNSHA=$(sha256sum /tmp/spike03_down.bin 2>/dev/null | cut -d' ' -f1)
echo "uploaded   sha256: $UPSHA"
echo "downloaded sha256: ${DOWNSHA:-<none>}  ($(stat -c%s /tmp/spike03_down.bin 2>/dev/null || echo 0) bytes)"

say "VERDICT"
PASS=1
[ "$UPSHA" = "${DOWNSHA:-x}" ] || { PASS=0; echo "FAIL: 10MB media did NOT round-trip intact through the proxy"; }
[ "${PUBNONCADDY:-1}" = "0" ] && [ "${PUBLISHED:-0}" -ge "1" ] || { PASS=0; echo "FAIL: isolation — a non-front service publishes a host port (or nothing published)"; }
if [ "$PASS" = 1 ]; then
  echo "PASS: core has NO public ports (only Caddy publishes :8080); client-server API + 10MB media round-trip cleanly through the front."
fi
rm -f /tmp/spike03_up.bin /tmp/spike03_down.bin
echo; echo "(stack left up; 'docker compose down -v' to clean)"
