# Spike 07 — Matrix-native escrow store + producer round-trip

**Status: PASS (6/6).** `./run.sh` (self-contained Synapse on :8010; `uv` pulls `cryptography` +
`pycryptodome` + `requests`).

Proves Phase-2 components **B (escrow store)** and **E (onboarding escrow creation)** end-to-end against
a real Synapse, with **no new service** — the decided Matrix-native design:

- the **moderator directory** is published as Matrix **room state** (`org.rednet.recovery.moderators`:
  policy `{m,n}` + each moderator's P-256 public key),
- the **producer** fetches it, builds the escrow (Spike-06 P-256 ECIES sealing per moderator), and stores
  the record in the member's **`account_data`** (`org.rednet.recovery.escrow.*`),
- **recovery on a fresh device** = GET the record back; M moderators unseal their shares → reconstruct →
  unwrap `K`.

## What it proves

| Check                                                   | Result |
| ------------------------------------------------------- | ------ |
| moderators-only: 3 mods recover `K` from `account_data` | ✅     |
| passphrase: 3 mods + correct phrase recover `K`         | ✅     |
| passphrase: 3 mods + WRONG phrase blocked               | ✅     |
| moderators-only: 2 mods (< M) blocked                   | ✅     |
| **server-stored record is OPAQUE** (no plaintext `K`)   | ✅     |
| `account_data` round-trip intact                        | ✅     |

The opacity check is the one that matters for the threat model: a seized core holds the escrow record
and the directory, and neither contains `K` or anything that yields it without M moderator keys.

## What this does NOT cover

The **recovery coordination handshake** (a fresh device requesting recovery, M moderators verifying the
human out-of-band and delivering their unsealed shares _to that new device_) — that's components D + F,
and the out-of-band human verification is a design decision, not a crypto one (RECOVERY.md §0, §5b).
This spike proves the _storage + producer + crypto recovery_; it hands the moderator shares directly
(modeling "the moderators approved"). The coordination/verification flow is specified, not yet built.
