# Spike 04 — Backup → cold restore → recoverability

**Question:** `SPEC.md §9` claims the deployment is recoverable from encrypted off-box backups. The research flagged two _silent_-failure traps: the `e2e_one_time_keys_json` TRUNCATE requirement (restoring it re-issues stale keys → decryption errors), and the realistic cold-restore model. Does a back-up → destroy → restore actually bring the server back, intact?

**What it does:** stands up Synapse + Postgres, creates a user + an encrypted room + 4 messages, **plants a stale one-time-key row**, then:

1. **Backs up** with `pg_dump -Fc --exclude-table-data e2e_one_time_keys_json` + signing key + config.
2. **Destroys everything** (`down -v` wipes both volumes — total loss).
3. **Cold-restores** onto fresh volumes and starts Synapse.
4. **Verifies:** login works, encrypted history intact, stale OTK gone, signing key preserved, E2EE key upload works.

**Run:** `bash run.sh` (≈2 min).

## Result — PASS (2026-06-16, Synapse 1.155.0)

```
login after restore: yes
encrypted msgs : before=4 after=4
OTK rows       : before=1 after=0   (the exclude-dump = the TRUNCATE requirement, satisfied)
signing.key    : preserved
keys/upload    : HTTP 200
PASS
```

**Confirmed:**

- ✅ **Account + encrypted message history fully recover** from a cold restore.
- ✅ The **`--exclude-table-data e2e_one_time_keys_json` dump satisfies the TRUNCATE requirement** automatically (stale OTK 1 → 0) — no manual TRUNCATE needed, and E2EE machinery (`keys/upload`) works on the restored server.
- ✅ **Signing key + `server_name` preserved** by restoring the config tar (same sha).

## Finding that fed back into the SPEC

- **`/data` ownership gotcha:** extracting backup files into a _fresh empty_ volume left `/data` un-writable by Synapse's runtime user (UID 991) → it crashed creating `media_store`. **Real-restore fix (now in §9):** provision the box first (so perms + `media_store` exist), _then_ overlay the signing key + config **as the runtime user**. A "restore by untar-into-empty-volume" runbook would have failed in production.

## Out of scope (deployment-drill item)

- **MAS restore** — the second database + the matched `secrets.encryption` (back up the MAS DB _without_ its key = unreadable ciphertext). This is the headline silent-failure the research found; it's a documented `SPEC §9` requirement, deferred from local spikes due to MAS-delegation setup complexity. It belongs in the quarterly full-stack restore drill.
- **Media-store backup/restore** (additive file copy — mechanically simple; not exercised here).
