# Spike 05 — recovery-key escrow crypto

**Status: PASS (10/10).** `./run.sh` (pure crypto, no Matrix server; `uv` pulls the vetted libs).

Proves the load-bearing cryptography for `../../RECOVERY.md` before we invest in the moderator PKI and
tooling around it — the same "verify the hard claim first" approach as Spikes 01/03/04.

## What it proves

| Group                   | Check                                                                                         | Result |
| ----------------------- | --------------------------------------------------------------------------------------------- | ------ |
| (a) moderators-only     | 3-of-5 recovers · 2 blocks · record-alone blocks                                              | ✅     |
| (b) passphrase + M-of-N | 3+phrase recovers · 3+wrong-phrase blocks · 2+phrase blocks · **3 mods + NO phrase blocks**   | ✅     |
| comparison              | same compromised 3-mod quorum: **(a) RECOVERS, (b) BLOCKED**                                  | ✅     |
| revocation              | proactive re-share → arrested mod's OLD share + 2 NEW shares **blocks**; 3 NEW shares recover | ✅     |

The headline contrast is the `(b) 3 mods, NO phrase → BLOCK` row vs `(a) 3 mods → RECOVER`: the member
passphrase is exactly what turns a compromised moderator quorum from "reads everyone" into "reads no
one without also breaking each member's factor." Both modes share **one record format + a `mode` flag**,
so "moderators-only by default, opt-in passphrase" is a single code path.

## Construction (as implemented)

```
MK  = 256-bit master wrap key (random)
(a) wrap = MK                               (b) wrap = SHA256(Argon2id(phrase, salt) ‖ MK)   [prod: HKDF]
Blob = SecretBox(wrap).encrypt(K)           # XSalsa20-Poly1305 — wrong key => decrypt RAISES
MK  → Shamir M-of-N (two 16B halves) → each share sealed to a moderator pubkey
```

Core stores `{mode, Blob, salt, sealed_shares, policy}` — all ciphertext it cannot read.

## Honest caveats (what the spike does NOT claim)

- **Re-share used the "re-deal" shortcut** (reconstruct MK at one point, re-split). It proves the
  _property_ — a fresh polynomial invalidates old shares — but production should use **distributed
  proactive secret sharing** so MK is never reconstructed on a single machine.
- **Re-share refreshes shares of the SAME MK.** It kills a _stolen share_; it does **not** help if the
  adversary already assembled M shares simultaneously and reconstructed MK (they keep MK forever, and
  the Blob is unchanged). Healing _that_ needs re-keying MK, which reconstructs K — or, in passphrase
  mode, the member re-escrowing. Revocation limits the window; it can't reach backward.
- **Vetted-but-spike KDF:** `SHA256(argon2 ‖ MK)` stands in for HKDF; PyCryptodome Shamir caps at 16B so
  MK is split as two aligned halves. Both are faithful but should be the real HKDF / a 256-bit-native
  Shamir in production.
- Argon2 params are INTERACTIVE (fast, for the spike). Production picks params for the threat: the
  passphrase must resist a coerced quorum that already holds MK + Blob, so **diceware-grade entropy**,
  since there's no trusted hardware to rate-limit guesses.
