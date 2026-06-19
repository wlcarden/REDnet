# Spike 06 — moderator keys on P-256 secure elements

**Status: PASS (7/7 + no-extraction).** `./run.sh` (pure crypto; `uv` pulls `cryptography` + `pycryptodome`).

The Phase-2 foundation. Spike 05 proved the escrow on libsodium **Curve25519** sealed boxes — but
Secure Enclave / Android Keystore / WebCrypto do **NIST P-256 ECDH, not Curve25519**. This re-proves
the full construction on **P-256 ECIES**, through a `SecureElementKey` that exposes _only_ `ecdh()` and
**no private-key extraction**. Recovery succeeds through that narrow interface ⇒ the moderator key can
live in the phone's secure element, non-extractable, and a seized+forensically-extracted phone yields
nothing.

## What it proves

| Group                   | Check                                                                       | Result |
| ----------------------- | --------------------------------------------------------------------------- | ------ |
| (a) moderators-only     | 3-of-5 recovers (ECIES unseal via `ecdh()` only) · 2 blocks                 | ✅     |
| (b) passphrase + M-of-N | 3+phrase recovers · wrong/no-phrase blocks                                  | ✅     |
| revocation              | proactive re-share: arrested OLD share + 2 NEW → blocks; 3 NEW → recovers   | ✅     |
| secure-element          | the key object has **no** `private_bytes`/export path, yet the escrow works | ✅     |

## Construction (the P-256 ECIES change vs Spike 05)

```
moderator key = P-256 keypair (prod: generated IN Secure Enclave / Android Keystore, non-extractable)
seal(share -> mod_pub):   ephemeral P-256 keypair; HKDF(ECDH(eph_priv, mod_pub)) -> AES-256-GCM
unseal(mod):              HKDF(mod.ecdh(eph_pub)) -> AES-256-GCM     # the ONE secure-element op
```

Everything else is unchanged from Spike 05 (Shamir M-of-N over the MK, passphrase layer, revocation).
P-256 ECDH here is byte-for-byte the operation the platform secure elements perform.

## What this does NOT cover (the platform binding is the next decision)

This proves the **crypto** works on P-256 with an ECDH-only key. It does **not** exercise a real secure
element (none in-sandbox). Production binds the P-256 key to non-extractable hardware via one of:

- **Native keystore (iOS Secure Enclave / Android Keystore)** — does P-256 ECDH directly; clean ECIES
  exactly as verified here. Requires a **native app** (Element X) for the moderator's key.
- **WebAuthn PRF** — works in a **browser** (no native app), but the authenticator yields a _symmetric_
  PRF secret, not an ECDH key, so sealing would be a symmetric wrap, **not** the P-256 ECIES proven here.

The choice is a moderator-UX decision (native vs web), and it changes the sealing — so it's settled
before the moderator approval tool is built.
