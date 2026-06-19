#!/usr/bin/env python3
"""
REDnet Spike 06 — moderator keys on P-256 secure elements.

Phase-2 foundation. Spike 05 proved the escrow on libsodium Curve25519 sealed boxes, but Secure
Enclave / Android Keystore do **NIST P-256 ECDH, not Curve25519**. This re-proves the FULL escrow
construction (moderators-only + passphrase + revocation) on **P-256 ECIES**, using ONLY the operation
a secure element exposes — ECDH — and NEVER extracting the private key. That is the concrete claim:
"a moderator's recovery key can live in the phone's secure element, non-extractable, and still do its job."

Vetted primitives: `cryptography` (P-256 ECDH, HKDF-SHA256, AES-256-GCM, scrypt) + PyCryptodome (Shamir).
P-256 ECDH here is byte-for-byte the same operation Secure Enclave/Android Keystore/WebCrypto perform.
"""
import os, json, hashlib, sys
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

N, M = 5, 3
K_SECRET = b"4S-recovery-key::cross-signing+key-backup::CROWN-JEWEL"


class SecureElementKey:
    """Mimics a secure-element P-256 key (Secure Enclave / Android Keystore). Exposes ONLY public_key
    and ecdh() — there is deliberately NO method to export the private bytes. In production .ecdh() is
    a syscall into the element; the private key never leaves it, so a seized+extracted phone yields
    nothing. The whole escrow below works through this narrow interface => secure-element compatible.
    """

    def __init__(self):
        self._k = ec.generate_private_key(ec.SECP256R1())

    @property
    def public_key(self):
        return self._k.public_key()

    def ecdh(self, peer_pub):  # the ONLY operation the element exposes
        return self._k.exchange(ec.ECDH(), peer_pub)


def _kdf(shared, info=b"rednet-ecies"):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=info).derive(
        shared
    )


def ecies_seal(recipient_pub, plaintext):  # app-side: ephemeral ECDH -> HKDF -> AES-GCM
    eph = ec.generate_private_key(ec.SECP256R1())
    key = _kdf(eph.exchange(ec.ECDH(), recipient_pub))
    nonce = os.urandom(12)
    eph_pub = eph.public_key().public_bytes(
        Encoding.X962, PublicFormat.UncompressedPoint
    )  # 65 bytes
    return eph_pub + nonce + AESGCM(key).encrypt(nonce, plaintext, None)


def _validate_point(raw_65):
    """Reject off-curve, identity, and malformed points BEFORE ECDH. Defense-in-depth: `cryptography`
    and WebCrypto `importKey` already validate, but a secure-element ECDH syscall may not — an
    invalid-curve attack against the static key would be catastrophic (RECOVERY.md §12 item 4).
    """
    if len(raw_65) != 65 or raw_65[0] != 0x04:
        raise ValueError("not an uncompressed P-256 point")
    x = int.from_bytes(raw_65[1:33], "big")
    y = int.from_bytes(raw_65[33:65], "big")
    p = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
    b = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
    if x == 0 and y == 0:
        raise ValueError("identity / zero point")
    if x >= p or y >= p:
        raise ValueError("coordinate >= field prime")
    if (y * y - x * x * x + 3 * x - b) % p != 0:
        raise ValueError("point not on P-256 curve")
    return ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), raw_65)


def ecies_unseal(se_key, blob):  # recipient-side: ONE secure-element ecdh()
    eph_pub = _validate_point(blob[:65])
    key = _kdf(se_key.ecdh(eph_pub))  # <-- the only secure-element op in the whole flow
    return AESGCM(key).decrypt(blob[65:77], blob[77:], None)


# ---- Shamir over a 32-byte MK as two aligned 16-byte halves (same as Spike 05) ----
def split_mk(mk):
    from Crypto.Protocol.SecretSharing import Shamir

    lo = Shamir.split(M, N, mk[:16])
    hi = Shamir.split(M, N, mk[16:])
    return {i: (l, h) for (i, l), (_, h) in zip(lo, hi)}


def combine_mk(triples):
    from Crypto.Protocol.SecretSharing import Shamir

    lo = Shamir.combine([(i, l) for (i, l, h) in triples])
    hi = Shamir.combine([(i, h) for (i, l, h) in triples])
    return lo + hi


def derive_wrap(mk, mode, passphrase, salt):
    if mode == "moderators_only":
        return mk
    pk = Scrypt(salt=salt, length=32, n=2**14, r=8, p=1).derive(passphrase.encode())
    return hashlib.sha256(pk + mk).digest()  # bind BOTH (spike KDF; prod: HKDF)


def make_escrow(mode, mod_pubs, passphrase=None):
    mk = os.urandom(32)
    salt = os.urandom(16) if mode == "passphrase" else b""
    nonce = os.urandom(12)
    blob = nonce + AESGCM(derive_wrap(mk, mode, passphrase, salt)).encrypt(
        nonce, K_SECRET, None
    )
    sh = split_mk(mk)
    enc = {
        i: ecies_seal(mod_pubs[i - 1], sh[i][0] + sh[i][1]) for i in sh
    }  # sealed to P-256 mod keys
    return {"mode": mode, "blob": blob, "salt": salt, "enc_shares": enc}


def open_share(rec, i, mod_keys):
    raw = ecies_unseal(mod_keys[i - 1], rec["enc_shares"][i])
    return (i, raw[:16], raw[16:])


def recover(rec, approving, mod_keys, passphrase=None):
    mk = combine_mk([open_share(rec, i, mod_keys) for i in approving])
    wrap = derive_wrap(mk, rec["mode"], passphrase, rec["salt"])
    return AESGCM(wrap).decrypt(rec["blob"][:12], rec["blob"][12:], None)


def reshare(
    rec, mod_keys, survivors, mod_pubs
):  # proactive re-share onto a fresh polynomial
    mk = combine_mk([open_share(rec, i, mod_keys) for i in survivors])
    sh = split_mk(mk)
    enc = {i: ecies_seal(mod_pubs[i - 1], sh[i][0] + sh[i][1]) for i in sh}
    r = dict(rec)
    r["enc_shares"] = enc
    return r


checks = []


def attempt(label, fn, expect):
    try:
        got = "recover" if fn() == K_SECRET else "block"
    except Exception:
        got = "block"
    ok = got == expect
    checks.append(ok)
    print(
        f"  {label:50s} -> {got.upper():8s} (expect {expect:7s}) {'OK' if ok else '*** MISMATCH ***'}"
    )


mod_keys = [SecureElementKey() for _ in range(N)]
mod_pubs = [k.public_key for k in mod_keys]
# secure-element claim: the key object exposes NO extraction path, yet the whole escrow works through it
no_extract = not any(
    hasattr(mod_keys[0], a)
    for a in ("private_bytes", "private_numbers", "_export", "exportKey")
)

print("\n(a) MODERATORS-ONLY on P-256 secure-element keys")
recA = make_escrow("moderators_only", mod_pubs)
attempt(
    "3 mods (P-256 ECIES unseal via ecdh only)",
    lambda: recover(recA, [1, 2, 3], mod_keys),
    "recover",
)
attempt("2 mods (< M)", lambda: recover(recA, [1, 2], mod_keys), "block")

print("\n(b) PASSPHRASE + M-of-N on P-256")
PH = "correct horse battery staple"
recB = make_escrow("passphrase", mod_pubs, passphrase=PH)
attempt(
    "3 mods + correct phrase", lambda: recover(recB, [1, 2, 3], mod_keys, PH), "recover"
)
attempt(
    "3 mods + WRONG phrase",
    lambda: recover(recB, [1, 2, 3], mod_keys, "hunter2"),
    "block",
)
attempt(
    "3 mods, NO phrase [coerced quorum]",
    lambda: recover(recB, [1, 2, 3], mod_keys, "."),
    "block",
)

print("\n(rev) REVOCATION on P-256 (proactive re-share)")
old4 = open_share(recA, 4, mod_keys)
recA2 = reshare(recA, mod_keys, [1, 2, 3], mod_pubs)


def mix():
    n1, n2 = open_share(recA2, 1, mod_keys), open_share(recA2, 2, mod_keys)
    return AESGCM(combine_mk([old4, n1, n2])).decrypt(
        recA2["blob"][:12], recA2["blob"][12:], None
    )


attempt("arrested OLD share + 2 NEW shares", mix, "block")
attempt(
    "3 NEW shares (healthy quorum)",
    lambda: recover(recA2, [1, 2, 3], mod_keys),
    "recover",
)

print("\n(inv) INVALID-CURVE ATTACK defense (RECOVERY.md §12 item 4)")
valid_seal = recA["enc_shares"][1]
valid_eph = valid_seal[:65]
offcurve_eph = bytearray(valid_eph)
offcurve_eph[64] ^= 0x01
offcurve_blob = bytes(offcurve_eph) + valid_seal[65:]
attempt(
    "off-curve ephemeral point (y flipped 1 bit)",
    lambda: ecies_unseal(mod_keys[0], offcurve_blob),
    "block",
)
identity_blob = b"\x04" + b"\x00" * 64 + valid_seal[65:]
attempt(
    "identity / zero point (0,0)",
    lambda: ecies_unseal(mod_keys[0], identity_blob),
    "block",
)
truncated_blob = valid_seal[:30] + valid_seal[65:]
attempt(
    "truncated point (< 65 bytes)",
    lambda: ecies_unseal(mod_keys[0], truncated_blob),
    "block",
)
P256_P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
oversize_blob = (
    b"\x04" + P256_P.to_bytes(32, "big") + P256_P.to_bytes(32, "big") + valid_seal[65:]
)
attempt(
    "coordinates >= field prime",
    lambda: ecies_unseal(mod_keys[0], oversize_blob),
    "block",
)

print(f"\n  secure-element key exposes NO private-key extraction: {no_extract}")
result = {
    "total": len(checks),
    "passed": sum(checks),
    "secureElement_noExtraction": no_extract,
    "PASS": all(checks) and no_extract,
}
json.dump(result, open("result.json", "w"), indent=2)
print(
    f"\n=== VERDICT: {result['passed']}/{result['total']} checks + no-extraction={no_extract} -> "
    f"{'PASS' if result['PASS'] else 'FAIL'} ==="
)
sys.exit(0 if result["PASS"] else 2)
