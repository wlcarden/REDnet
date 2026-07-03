#!/usr/bin/env bash
# REDnet backup — captures the FIVE things a restore needs (proven in ../spikes/04).
# Missing any one fails restore, often SILENTLY (the MAS DB + its encryption key are a
# matched pair). Production: pipe this into restic (append-only, repo key held OFF the core)
# and emit a backup-success heartbeat to Prometheus (a stopped backup is the worst latent failure).
set -uo pipefail
umask 077   # the bundle holds crown jewels — write it 0600, never world-readable (security review R2)
cd "$(dirname "$0")" || exit 1
[ -f rednet.env ] && { set -a; . ./rednet.env; set +a; }

# F7: do not write a cleartext crown-jewel bundle unless it will be encrypted
# off-box (restic) OR the operator has explicitly accepted cleartext-at-rest. The
# Ansible timer runs this hourly and unattended, so a silent cleartext default
# would pile the MAS encryption key + both DBs + signing key onto the seizable
# core every hour. Fail closed instead.
if [ -z "${RESTIC_REPOSITORY:-}" ] || [ -z "${RESTIC_PASSWORD:-}" ]; then
  if [ "${REDNET_ALLOW_CLEARTEXT_BACKUP:-}" != "true" ]; then
    echo "REFUSING to back up: no encrypted off-box target is configured." >&2
    echo "  A backup here leaves the MAS encryption key + both DBs + signing key as" >&2
    echo "  CLEARTEXT on this core, regenerated hourly by the timer. Choose one:" >&2
    echo "    • set RESTIC_REPOSITORY + RESTIC_PASSWORD (repo key held OFF the core), or" >&2
    echo "    • set REDNET_ALLOW_CLEARTEXT_BACKUP=true to accept cleartext-at-rest (NOT for production)." >&2
    exit 1
  fi
  echo "⚠️  REDNET_ALLOW_CLEARTEXT_BACKUP=true — writing a CLEARTEXT bundle with no off-box encryption." >&2
fi

OUT="backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"; chmod 700 "$OUT"
say(){ printf '\n=== %s ===\n' "$*"; }

say "backup -> $OUT"
# 1 — Synapse DB (★ exclude one-time-keys: the E2EE TRUNCATE requirement, else decryption breaks)
docker compose exec -T postgres pg_dump -Fc --exclude-table-data e2e_one_time_keys_json -U synapse synapse > "$OUT/synapse.dump"
# 2 — MAS DB (a SEPARATE database — easy to forget)
docker compose exec -T postgres pg_dump -Fc -U synapse mas > "$OUT/mas.dump"
# 3 — Synapse signing key (server identity)
docker compose exec -T synapse sh -c 'cat /data/*.signing.key' > "$OUT/signing.key"
# 4 — MAS config incl. ★ secrets.encryption (matched pair with the MAS DB, or it restores as unreadable ciphertext)
cp mas/config.yaml "$OUT/mas-config.yaml"
# 5 — media store
docker compose exec -T synapse sh -c 'cd /data && tar c media_store 2>/dev/null' > "$OUT/media.tar" || true
# 6 — the HARDENED homeserver.yaml + log config, so a restore comes back HARDENED, not Synapse defaults (R2)
docker compose exec -T synapse sh -c 'cat /data/homeserver.yaml' > "$OUT/homeserver.yaml"
docker compose exec -T synapse sh -c 'cat /data/*.log.config 2>/dev/null' > "$OUT/log.config" || true

say "captured (size / file)"
ls -la "$OUT" | awk 'NR>1 && $5 {print $5"\t"$NF}'
# fail loudly if any core artifact is empty
for f in synapse.dump mas.dump signing.key mas-config.yaml homeserver.yaml; do
  [ -s "$OUT/$f" ] || { echo "FAIL: $f is empty"; exit 1; }
done
# --- optional: encrypted, off-box transport via restic (set RESTIC_REPOSITORY + RESTIC_PASSWORD) ---
# Production repo should be append-only object storage (e.g. s3:...) with the password held OFF the
# core box, so a core compromise can't rewrite or delete history.
SHREDDED=0
if [ -n "${RESTIC_REPOSITORY:-}" ] && [ -n "${RESTIC_PASSWORD:-}" ]; then
  say "restic -> $RESTIC_REPOSITORY"
  MOUNT=""; case "$RESTIC_REPOSITORY" in /*) MOUNT="-v $RESTIC_REPOSITORY:$RESTIC_REPOSITORY";; esac
  RUN="docker run --rm $MOUNT -v $PWD/backups:/backups:ro -e RESTIC_REPOSITORY -e RESTIC_PASSWORD restic/restic"
  $RUN snapshots >/dev/null 2>&1 || $RUN init
  if $RUN backup "/backups/$(basename "$OUT")" --tag rednet --host rednet-core; then
    echo "restic snapshot created."
    # off-box copy is safe -> SHRED the cleartext crown-jewel bundle off the seizable core (R2)
    find "$OUT" -type f -exec shred -u {} + 2>/dev/null || rm -f "$OUT"/*
    rmdir "$OUT" 2>/dev/null || true
    SHREDDED=1; echo "local cleartext bundle shredded (off-box restic copy retained)."
  else
    echo "WARNING: restic upload FAILED — cleartext bundle left at $OUT."
  fi
fi

# --- backup heartbeat -> pushgateway (clears the BackupHeartbeatStale/Missing alerts) ---
HB="${PUSHGATEWAY_URL:-http://127.0.0.1:9091}"
if curl -sf -o /dev/null --max-time 3 "$HB/-/healthy" 2>/dev/null; then
  printf 'rednet_backup_last_success_timestamp_seconds %s\n' "$(date +%s)" \
    | curl -s --data-binary @- "$HB/metrics/job/rednet_backup" >/dev/null && echo "heartbeat pushed -> $HB"
fi

echo
if [ "$SHREDDED" = 1 ]; then
  echo "OK. Off-box restic snapshot IS the backup; local cleartext shredded. Restore from restic (see ./restore.sh)."
else
  echo "⚠️  Cleartext crown-jewel bundle remains at $OUT ON THE CORE (MAS encryption key + both DBs + signing key)."
  echo "    Set RESTIC_REPOSITORY + RESTIC_PASSWORD (repo key held OFF the core) for encrypted off-box backup + auto-shred,"
  echo "    or move it off-box and delete it now — do not let cleartext crown jewels accumulate on a seizable core."
  echo "    Restore with: ./restore.sh $OUT   (see SPEC §9 / spikes/04)"
fi
