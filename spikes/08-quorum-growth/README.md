# Spike 08 — quorum growth (M/N scales with the community)

**Status: PASS (4/4).** `./run.sh` (pure crypto; `uv` pulls `pycryptodome` + `cryptography`).

Backs the scaling model in `RECOVERY.md §11`: a recovery quorum **grows** (2-of-3 → 3-of-5) by
re-sharing the **same** wrap key onto a fresh, higher-threshold polynomial — so a community can move
_through_ quorum sizes as it adds trusted organizers, without rebuilding anyone's escrow.

## What it proves

| Check                                                                      | Result |
| -------------------------------------------------------------------------- | ------ |
| v1: 2-of-3 recovers (small quorum)                                         | ✅     |
| v2: 3-of-5 NEW shares recover (after growth)                               | ✅     |
| v2: 2-of-5 NEW shares blocked — **threshold actually rose**                | ✅     |
| old v1 share + new v2 shares **can't be mixed** (incompatible polynomials) | ✅     |

## The operational caveat it surfaces

Re-sharing does **not** auto-kill old shares — `old 2-of-3 shares STILL reconstruct until deleted: True`.
So honest moderators **must delete** their old shares on every re-share; deletion, not the new
polynomial, is what retires them (same caveat as §6 revocation). A _known-compromised_ moderator who
kept their old share therefore needs a **re-key** (new wrap key), not just a re-share — re-share only
defeats a moderator who deleted, i.e. it limits _creeping_ compromise, not a held-back share.

This is why quorum changes (adding the 4th/5th organizer, swapping someone out) are routine re-share
events, but a moderator _arrest_ triggers the stronger response.
