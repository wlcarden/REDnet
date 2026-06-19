#!/usr/bin/env bash
# Scrub deanonymizing metadata (IPs + user-agents) the stack retains.
#  - MAS has NO native pruning  -> NULL its IP/UA columns (incl. user_registrations.ip_address).
#  - Synapse `user_ips` is bounded by user_ips_max_age, but the `devices` table ip/user_agent is NOT
#    (security review R2) -> NULL it here too.
# Runs each DB in a SINGLE TRANSACTION with ON_ERROR_STOP, so a renamed/removed column ABORTS LOUDLY
# instead of silently skipping (R2). MAS only re-populates the CURRENT session's IP, so SCHEDULE THIS
# HOURLY on the core (systemd timer — see ansible/) to keep retention ≤ one interval.
# ⚠️ This does NOT erase backups or Postgres WAL/PITR history (R2) — hold backups OFF the core.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
say(){ printf '\n=== %s ===\n' "$*"; }

say "scrub MAS IP/UA columns (single transaction, fail-loud)"
docker compose exec -T postgres psql -U synapse -d mas -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
UPDATE compat_sessions          SET last_active_ip=NULL, user_agent=NULL WHERE last_active_ip IS NOT NULL OR user_agent IS NOT NULL;
UPDATE oauth2_sessions          SET last_active_ip=NULL, user_agent=NULL WHERE last_active_ip IS NOT NULL OR user_agent IS NOT NULL;
UPDATE user_sessions            SET last_active_ip=NULL, user_agent=NULL WHERE last_active_ip IS NOT NULL OR user_agent IS NOT NULL;
UPDATE personal_sessions        SET last_active_ip=NULL                  WHERE last_active_ip IS NOT NULL;
UPDATE user_registrations       SET ip_address=NULL, user_agent=NULL     WHERE ip_address IS NOT NULL OR user_agent IS NOT NULL;
UPDATE user_recovery_sessions   SET ip_address=NULL, user_agent=NULL     WHERE ip_address IS NOT NULL OR user_agent IS NOT NULL;
UPDATE oauth2_device_code_grant SET ip_address=NULL, user_agent=NULL     WHERE ip_address IS NOT NULL OR user_agent IS NOT NULL;
COMMIT;
SQL
MASRC=$?

say "scrub Synapse devices table (ip/user_agent — NOT bounded by user_ips_max_age)"
docker compose exec -T postgres psql -U synapse -d synapse -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
UPDATE devices SET ip=NULL, user_agent=NULL WHERE ip IS NOT NULL OR user_agent IS NOT NULL;
COMMIT;
SQL
SYNRC=$?

say "verify (rows still holding an IP — expect 0, or only just-active sessions)"
docker compose exec -T postgres psql -U synapse -d mas -tAc "
SELECT 'mas.user_registrations', count(*) FROM user_registrations WHERE ip_address IS NOT NULL
UNION ALL SELECT 'mas.compat_sessions', count(*) FROM compat_sessions WHERE last_active_ip IS NOT NULL;"
docker compose exec -T postgres psql -U synapse -d synapse -tAc "SELECT 'synapse.devices', count(*) FROM devices WHERE ip IS NOT NULL;"

if [ "${MASRC:-1}" = 0 ] && [ "${SYNRC:-1}" = 0 ]; then
  echo "scrub OK"
else
  echo "SCRUB FAILED — a transaction aborted (likely a schema change in MAS/Synapse). Investigate before trusting hygiene."; exit 1
fi
