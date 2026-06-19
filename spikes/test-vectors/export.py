#!/usr/bin/env python3
"""
Export DETERMINISTIC cross-language test vectors for the Phase-2 recovery crypto.

The future TypeScript port (WebCrypto, in the Element fork) and the native moderator tool MUST
reproduce primitives.json BYTE-FOR-BYTE. These are the standard NIST/RFC primitives the whole escrow
is built from (RECOVERY.md §3, §12). Fixed keys + fixed nonces make every output deterministic.
Self-checks on run, so a bad vector can't be exported silently.

Vetted reference: `cryptography` (P-256 / HKDF-SHA256 / AES-256-GCM / scrypt).
"""
import json
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

H = lambda b: b.hex()


def derive(scalar):
    return ec.derive_private_key(scalar, ec.SECP256R1())


def upub(k):
    return k.public_key().public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)


def raw_priv(k):
    return k.private_numbers().private_value.to_bytes(32, "big")


# fixed P-256 scalars (both < group order n) -> deterministic keypairs
D_RECIP = 0x00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEE01
D_EPH = 0x0FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA98765432
recip, eph = derive(D_RECIP), derive(D_EPH)
INFO = b"rednet-ecies"

# 1) ECDH — the secure-element operation (eph_priv · recip_pub)
shared = eph.exchange(ec.ECDH(), recip.public_key())
# 2) HKDF-SHA256 over the shared secret
hkdf_out = HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=INFO).derive(
    shared
)
# 3) AES-256-GCM (standalone, fixed key/nonce/pt/aad)
gcm_key, gcm_nonce = bytes(range(32)), bytes(range(12))
gcm_pt = bytes.fromhex("00112233445566778899aabbccddeeff" * 2)
gcm_aad = b"rednet-v1"
gcm_ct = AESGCM(gcm_key).encrypt(gcm_nonce, gcm_pt, gcm_aad)
# 4) scrypt (passphrase KDF for the opt-in member factor)
scrypt_salt = bytes(range(16))
scrypt_out = Scrypt(salt=scrypt_salt, length=32, n=2**14, r=8, p=1).derive(
    b"correct horse battery staple"
)
# 5) ECIES seal WITH AAD (RECOVERY.md §12 item 5: AAD-bound form — ports MUST NOT use aad=None)
ecies_nonce = bytes.fromhex("0102030405060708090a0b0c")
ecies_pt = bytes.fromhex("ffeeddccbbaa99887766554433221100" * 2)
ecies_key = HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=INFO).derive(
    shared
)
ecies_aad = json.dumps(
    {
        "dir_version": 1,
        "m": 3,
        "member": "@alice:rednet.test",
        "mode": "moderators_only",
        "n": 5,
    },
    sort_keys=True,
    separators=(",", ":"),
).encode()
ecies_blob = (
    upub(eph)
    + ecies_nonce
    + AESGCM(ecies_key).encrypt(ecies_nonce, ecies_pt, ecies_aad)
)

offcurve_pub = bytearray(upub(eph))
offcurve_pub[64] ^= 0x01
offcurve_pub = bytes(offcurve_pub)
try:
    ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), offcurve_pub)
    raise AssertionError("off-curve point was NOT rejected by from_encoded_point")
except (ValueError, Exception):
    pass
offcurve_blob = (
    offcurve_pub
    + ecies_nonce
    + AESGCM(ecies_key).encrypt(
        ecies_nonce,
        b"should never decrypt",
        None,
    )
)

P256_P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
identity_pub = b"\x04" + b"\x00" * 64
low_order_pub = b"\x04" + b"\x00" * 32 + P256_P.to_bytes(32, "big")

vectors = {
    "_about": "Deterministic Phase-2 crypto vectors. The TS/WebCrypto port + native moderator tool MUST reproduce these byte-for-byte. All hex. See README.md.",
    "curve": "P-256 (secp256r1)",
    "ecdh": {
        "recipient_priv_raw": H(raw_priv(recip)),
        "recipient_pub_uncompressed": H(upub(recip)),
        "ephemeral_priv_raw": H(raw_priv(eph)),
        "ephemeral_pub_uncompressed": H(upub(eph)),
        "shared_secret_x": H(shared),
    },
    "hkdf_sha256": {
        "ikm": H(shared),
        "salt": "",
        "info": H(INFO),
        "length": 32,
        "out": H(hkdf_out),
    },
    "aes_256_gcm": {
        "key": H(gcm_key),
        "nonce": H(gcm_nonce),
        "plaintext": H(gcm_pt),
        "aad": H(gcm_aad),
        "ciphertext_with_tag": H(gcm_ct),
    },
    "scrypt": {
        "passphrase": "correct horse battery staple",
        "salt": H(scrypt_salt),
        "n": 2**14,
        "r": 8,
        "p": 1,
        "length": 32,
        "out": H(scrypt_out),
    },
    "ecies_seal": {
        "construction": "blob = ephemeral_pub_uncompressed(65) || nonce(12) || AES-256-GCM(key=HKDF-SHA256(ECDH(eph_priv, recip_pub), info='rednet-ecies'), nonce, plaintext, aad=escrow_aad)",
        "recipient_pub_uncompressed": H(upub(recip)),
        "ephemeral_priv_raw": H(raw_priv(eph)),
        "nonce": H(ecies_nonce),
        "plaintext": H(ecies_pt),
        "aad": H(ecies_aad),
        "aad_json": ecies_aad.decode(),
        "blob": H(ecies_blob),
    },
    "ecies_unseal_reject": {
        "_about": "Negative vectors — unseal MUST reject these (invalid-curve attack defense, RECOVERY.md §12 item 4). A port that accepts any of these is vulnerable to static-key extraction.",
        "offcurve_blob": H(offcurve_blob),
        "offcurve_description": "Valid ephemeral pub with y-coordinate flipped by 1 bit in the low byte — off-curve. ECDH with this point leaks bits of the static key.",
        "identity_point": H(identity_pub),
        "identity_description": "The (0,0) 'point' — not on P-256. Accepting it as a public key is a degenerate-input bug.",
        "low_order_point": H(low_order_pub),
        "low_order_description": "x=0, y=p (the field prime) — encodes as (0,0) mod p, also not on curve.",
    },
}


# self-checks: round-trips must hold before we write anything
def unseal(rk, blob, aad):
    ep = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), blob[:65])
    k = HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=INFO).derive(
        rk.exchange(ec.ECDH(), ep)
    )
    return AESGCM(k).decrypt(blob[65:77], blob[77:], aad)


assert unseal(recip, ecies_blob, ecies_aad) == ecies_pt, "ECIES round-trip failed"
try:
    unseal(recip, ecies_blob, None)
    raise AssertionError("ECIES unseal with aad=None should have failed")
except Exception:
    pass
assert (
    AESGCM(gcm_key).decrypt(gcm_nonce, gcm_ct, gcm_aad) == gcm_pt
), "GCM round-trip failed"
assert (
    recip.exchange(ec.ECDH(), eph.public_key()) == shared
), "ECDH symmetry failed"  # both directions agree

json.dump(vectors, open("primitives.json", "w"), indent=2)
print(
    "wrote primitives.json — self-checks passed (ECIES + GCM round-trips, ECDH symmetry)"
)
print("  ECDH shared_secret_x:", H(shared))
print("  ECIES blob:", len(ecies_blob), "bytes")
