#!/usr/bin/env bash
# REDnet restore — cold restore from a backup.sh directory onto a FRESH stack.
# Mirrors the verified runbook in ../spikes/04 (incl. the /data-ownership fix: provision the
# box FIRST so perms + media_store exist, THEN overlay the signing key as the runtime user).
# ★ The server_name (REDNET_DOMAIN) MUST be identical to the original — it is immutable.
# ⚠️ DESTRUCTIVE: wipes the current stack. Run on a fresh box / after `docker compose down -v`.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
BK="${1:?usage: ./restore.sh backups/<timestamp>}"
[ -d "$BK" ] || { echo "no such backup dir: $BK"; exit 1; }
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }
: "${REDNET_DOMAIN:?}"
say(){ printf '\n=== %s ===\n' "$*"; }

say "WIPE current stack"
docker compose down -v >/dev/null 2>&1 || true

say "restore MAS config (incl. secrets.encryption — matched with the MAS DB)"
cp "$BK/mas-config.yaml" mas/config.yaml

say "fresh postgres + restore BOTH databases"
docker compose up -d postgres
until docker compose exec -T postgres pg_isready -U synapse >/dev/null 2>&1; do sleep 2; done
docker compose exec -T postgres pg_restore --no-owner -d synapse -U synapse < "$BK/synapse.dump" >/dev/null 2>&1 \
  || docker compose exec -T postgres pg_restore --no-owner --clean --if-exists -d synapse -U synapse < "$BK/synapse.dump" >/dev/null 2>&1
docker compose exec -T postgres pg_restore --no-owner -d mas -U synapse < "$BK/mas.dump" >/dev/null 2>&1 \
  || docker compose exec -T postgres pg_restore --no-owner --clean --if-exists -d mas -U synapse < "$BK/mas.dump" >/dev/null 2>&1
echo "both DBs restored"

say "provision fresh /data (perms + media_store), then overlay the HARDENED config + secrets"
# ★ R2 fix: a restore must bring the honeypot back HARDENED, not as Synapse defaults. We `generate`
# only to create /data perms + media_store, then OVERWRITE the config with the backed-up hardened one.
docker compose run --rm -T synapse generate >/dev/null 2>&1
DUID=$(docker compose run --rm -T --entrypoint stat synapse -c '%u' /data | tr -d '[:space:]'); DUID="${DUID:-991}"
put(){ docker compose run --rm -T --user "$DUID" --entrypoint sh synapse -c "cat > $1"; }
put "/data/homeserver.yaml" < "$BK/homeserver.yaml"                         # the hardened config (not the default)
put "/data/${REDNET_DOMAIN}.signing.key" < "$BK/signing.key"
[ -s "$BK/log.config" ] && put "/data/${REDNET_DOMAIN}.log.config" < "$BK/log.config"
# the MAS shared-secret file the hardened config references (secret_path) — re-derive from the restored MAS config
python3 -c "import yaml;print(yaml.safe_load(open('mas/config.yaml'))['matrix']['secret'])" | put "/data/mas_shared_secret"
echo "DBs + signing key + HARDENED homeserver.yaml + MAS shared secret restored"

say "restore media"
[ -s "$BK/media.tar" ] && docker compose run --rm -T --user "$DUID" --entrypoint sh synapse -c 'tar x -C /data' < "$BK/media.tar" 2>/dev/null && echo "media restored" || echo "(no media)"

say "★ ASSERT the restored config is HARDENED (fail-closed — the honeypot must not come back open)"
HARD=$(docker compose run --rm -T --entrypoint python3 synapse -c "import yaml;c=yaml.safe_load(open('/data/homeserver.yaml'));print('fed=%s mas=%s ret=%s'%(c.get('federation_domain_whitelist'),'matrix_authentication_service' in c,bool(c.get('retention',{}).get('enabled'))))" 2>/dev/null)
echo "  $HARD"
[ "$HARD" = "fed=[] mas=True ret=True" ] || { echo "FAIL: restored homeserver.yaml is NOT hardened (federation/MAS-delegation/retention). REFUSING — re-render via setup.sh before starting."; exit 1; }
echo "restored config is hardened ✓"
echo
echo "Start: docker compose up -d synapse caddy (single-host) / the WG override (two-host)."
echo "Smoke test: log in + read an encrypted message from two devices (SPEC §9)."
