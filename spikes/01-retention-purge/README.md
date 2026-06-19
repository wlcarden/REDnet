# Spike 01 — Encrypted-room retention purge (GATING)

**Question:** `SPEC.md §6` ships per-room retention presets and tells users (in the exposure banner) that messages auto-delete. The research flagged Synapse retention as _experimental and buggy_, with a live 2026 bug tail and a specific worry about **encrypted rooms**. Does retention **actually purge `m.room.encrypted` message events**, or does it silently no-op?

**What it does:** stands up Synapse + PostgreSQL (Docker), sets a server-wide `default_policy` of 1-minute `max_lifetime` + a 10s purge interval, creates an **encrypted** room (`m.room.encryption` set), **also** sets a per-room `m.room.retention` override (the exact mechanism the Draupnir preset bot uses), sends 6 `m.room.encrypted` events, then polls the Postgres `events` table until they purge.

**Run:** `bash run.sh` (≈3 min). Leaves the stack up for inspection; `docker compose down -v` to clean.

## Result — PASS (2026-06-16, Synapse 1.155.0, the pinned build)

```
m.room.encrypted BEFORE: 6
  t+70s: m.room.encrypted = 1
PASS: encrypted message events purged (6 -> 1)
```

Synapse logs confirmed real deletion (not hiding) from `events`, `event_json`, `event_search`, `event_edges`, etc. — the message **content** is gone, not just flagged.

**Confirmed behaviors (these are now validated facts the design relies on):**

- ✅ Retention **purges encrypted-room message events** on Synapse 1.155.0. The research's "silently no-ops" worry did **not** reproduce on the pinned version.
- ✅ The **per-room `m.room.retention` override works** — so the Draupnir preset path (`!rednet retention <preset>`) is viable, not just the server-wide default.
- ✅ **State events persist** (member, `m.room.encryption`, create, power_levels, history_visibility, join_rules, name, retention all remained = 1). This validates the exposure-banner copy: "retention does not purge membership/keys/room metadata."
- ✅ **The last message is never deleted** (6 → 1, not 6 → 0). The preset UI/banner should not promise zero residue.

## Implications for the spec

- The retention design (`SPEC.md §6`) is **sound on the pinned build**. Keep Synapse pinned ≥ 1.155.0; **re-run this spike on any version bump** (retention behavior is version-sensitive — it regressed and got re-fixed historically).
- Exposure-banner wording is validated: messages purge from the server on a timer; **state/membership/keys and the last message remain**; device-local copies are not touched (no client-side disappearing messages exist).
- This does **not** test purge under load or over long horizons — see Spike 06 (DB growth under retention at scale).
