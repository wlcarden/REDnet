# Phase-2 recovery crypto — test vectors

A verified oracle so the future **TypeScript/WebCrypto port** (Element fork) and the **native moderator
tool** can prove they match the reference implementation (spikes 05–08), not just "look right." Generated

- self-checked by `export.py` (`uv run --with cryptography python3 export.py`).

## `primitives.json` — byte-exact, cross-language

Standard NIST/RFC primitives with fixed keys + fixed nonces, so every output is deterministic. The port
**must reproduce each value byte-for-byte.** Covers:

| Vector        | The port computes it with                                                             |
| ------------- | ------------------------------------------------------------------------------------- |
| `ecdh`        | WebCrypto `deriveBits` (ECDH, P-256) — **the one operation a secure element exposes** |
| `hkdf_sha256` | WebCrypto `deriveBits` (HKDF, SHA-256)                                                |
| `aes_256_gcm` | WebCrypto `encrypt`/`decrypt` (AES-GCM, 256-bit)                                      |
| `scrypt`      | the opt-in-passphrase KDF (scrypt n=2¹⁴,r=8,p=1)                                      |
| `ecies_seal`  | the composed seal: `eph_pub(65) ‖ nonce(12) ‖ AES-GCM(HKDF(ECDH(eph,recip)))`         |

**How to use:** load the JSON, recompute each output from the given inputs, assert equality. A mismatch
means a real bug (wrong curve point encoding, wrong HKDF info, wrong GCM tag handling) — exactly the
class of error that silently breaks interop and is invisible to "it ran."

## ⚠️ Shamir is NOT in here — and that's deliberate

PyCryptodome's `SecretSharing.Shamir` operates in **GF(2¹²⁸)**; most JS Shamir libraries are byte-wise
**GF(2⁸)**. Their shares are **mutually incompatible** — you cannot validate a JS Shamir against the
Python reference byte-for-byte, and trying to would send you down a rabbit hole.

It doesn't matter, because **production is all-one-language**: the producer (member's client), the
recoverer (member's new client), and the moderator tool all use the **same** TS/native Shamir. Python
was only the reference for verifying the _construction_. So the requirement on the port's Shamir is
**behavioral self-consistency**, not Python-byte-match. The port's Shamir must pass these scenarios
(proven in the spikes), using its own implementation:

- **05/06/07:** any **M** shares reconstruct the wrap key; any **M-1** do not; a sealed record alone
  (no shares) does not.
- **passphrase mode:** M shares **and** the correct passphrase recover; M shares + wrong/no passphrase
  do not.
- **revocation (05/06):** after a proactive re-share onto a fresh polynomial, an old share mixed with
  new shares does **not** reconstruct.
- **growth (08):** re-sharing 2-of-3 → 3-of-5 raises the threshold (2 new shares no longer suffice) and
  old/new shares cannot be mixed.

Pick an **audited** TS Shamir, then gate it on the above before it touches real keys.
