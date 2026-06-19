# Spike 09 — escrow-record authentication (closes the security-review HIGH)

**Status: PASS (8/8).** `./run.sh` (pure crypto; `uv` pulls `cryptography` + `pycryptodome`).

Spikes 05–08 proved the escrow **crypto**, but sealed with `associated_data=None` and an **unsigned**
moderator directory. The security swarm flagged that as a **HIGH**: the escrow record and the directory
(published as server-rewritable Matrix room state) are not authenticated, so a malicious core can mount
**directory substitution** (swap in attacker moderator keys) or **policy-downgrade / record-replay**
(nothing binds the ciphertext to `{mode, policy, directory-version, member}`).

## What it proves (each attack must BLOCK; only the honest path RECOVERS)

| Group                  | Check                                                              | Result       |
| ---------------------- | ------------------------------------------------------------------ | ------------ |
| honest                 | org-signed directory + AAD-bound escrow: 3-of-5 recovers; 2 blocks | ✅           |
| directory substitution | Eve re-signs with her key · keeps stale org sig · recovery sees it | ✅ all BLOCK |
| policy downgrade       | m=3 → m=2 at recovery                                              | ✅ BLOCK     |
| record replay          | Alice's record presented as Bob                                    | ✅ BLOCK     |
| version rollback       | re-enable revoked moderators via an old directory version          | ✅ BLOCK     |

## The fix (RECOVERY.md §12)

1. **AAD binding** — every ECIES share-seal AND the wrap blob carry
   `aad = canon{mode, m, n, dir_version, member}`. Tamper any field ⇒ AES-GCM tag fails ⇒ block.
2. **Signed directory** — the moderator directory is signed by an **offline org key** (Ed25519) whose
   **public key is pinned out-of-band** into the client (the whitelabel build / a pinned config — NOT
   fetched from the server it defends against). Producer + recovery refuse an unsigned/forged directory.

## Productionization (remaining — this is the spike, not the product)

- Pin the org public key into the Element build (a config trust anchor) and move the producer into the
  onboarding module; Spike 07 is the Matrix-native store, this adds the authentication on top.
- Bind the AAD to the record's **creation-time** directory version and keep signed directory snapshots, so
  an old record still recovers under its own version (this spike uses a static v1 and models context
  tampering via an explicit override).
