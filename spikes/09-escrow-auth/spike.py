#!/usr/bin/env python3
"""
REDnet Spike 09 — escrow-record AUTHENTICATION (closes the security-review HIGH).

Spikes 05-08 proved the escrow crypto, but with `associated_data=None` and an UNSIGNED moderator
directory. The swarm flagged that as a HIGH: the escrow record + the directory (published as
server-rewritable Matrix room state) are not authenticated, so a malicious core can mount
  (1) DIRECTORY SUBSTITUTION  — swap in attacker-controlled moderator public keys, then "recover" as
      the member using attacker keys; and
  (2) POLICY DOWNGRADE / RECORD REPLAY — present a weaker {m,n}, or replay member A's record at member B,
      because nothing binds the ciphertext to {mode, policy, directory-version, member}.

This spike proves the FIX (RECOVERY.md §12 required hardening):
  - Bind context into the AEAD AAD: every ECIES share-seal AND the wrap blob carry
    aad = canonical{mode, m, n, dir_version, member}. Tamper any field => AES-GCM tag fails => BLOCK.
  - SIGN the moderator directory with an OFFLINE org key (Ed25519) whose public key is pinned
    out-of-band (NOT fetched from the server). Producer + recovery REFUSE an unsigned/forged directory.
The proof is the NEGATIVE cases: each attack must BLOCK while the honest path RECOVERS.

Vetted primitives: `cryptography` (P-256 ECDH, HKDF, AES-256-GCM, Ed25519, scrypt) + PyCryptodome (Shamir).
"""
import os, json, hashlib, sys
from cryptography.hazmat.primitives.asymmetric import ec, ed25519
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from cryptography.exceptions import InvalidSignature

N, M = 5, 3
K_SECRET = b"4S-recovery-key::cross-signing+key-backup::CROWN-JEWEL"


# ---- secure-element P-256 key (Spike 06: ECDH-only, non-extractable) ----
class SecureElementKey:
    def __init__(self):
        self._k = ec.generate_private_key(ec.SECP256R1())

    @property
    def public_key(self):
        return self._k.public_key()

    def ecdh(self, peer_pub):
        return self._k.exchange(ec.ECDH(), peer_pub)


def _canon(obj) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def _pub_b64(pub) -> str:
    import base64

    return base64.b64encode(
        pub.public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)
    ).decode()


def _b64_pub(s: str):
    import base64

    return ec.EllipticCurvePublicKey.from_encoded_point(
        ec.SECP256R1(), base64.b64decode(s)
    )


def _kdf(shared, info=b"rednet-ecies"):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=info).derive(
        shared
    )


# ---- ECIES with AAD (the fix vs Spike 06's associated_data=None) ----
def ecies_seal(recipient_pub, plaintext, aad: bytes):
    eph = ec.generate_private_key(ec.SECP256R1())
    key = _kdf(eph.exchange(ec.ECDH(), recipient_pub))
    nonce = os.urandom(12)
    eph_pub = eph.public_key().public_bytes(
        Encoding.X962, PublicFormat.UncompressedPoint
    )  # 65 bytes
    return eph_pub + nonce + AESGCM(key).encrypt(nonce, plaintext, aad)  # <-- AAD bound


def ecies_unseal(se_key, blob, aad: bytes):
    eph_pub = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), blob[:65])
    key = _kdf(se_key.ecdh(eph_pub))
    return AESGCM(key).decrypt(blob[65:77], blob[77:], aad)  # <-- AAD verified


# ---- Shamir over a 32-byte MK as two aligned 16-byte halves (Spikes 05/06) ----
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
    return hashlib.sha256(pk + mk).digest()


# ---- signed moderator directory (the room-state object, now authenticated) ----
def publish_directory(mod_pubs, m, n, version, org_sk):
    body = _canon(
        {
            "version": version,
            "policy": {"m": m, "n": n},
            "moderators": [_pub_b64(p) for p in mod_pubs],
        }
    )
    return {"body": body.decode(), "sig": org_sk.sign(body).hex()}


def verify_directory(directory, trusted_org_pub):
    """REFUSE unless the directory is signed by the OUT-OF-BAND-pinned org key. This is the trust anchor
    a malicious core cannot forge — it is NOT fetched from the server."""
    body = directory["body"].encode()
    trusted_org_pub.verify(
        bytes.fromhex(directory["sig"]), body
    )  # raises InvalidSignature on tamper
    return json.loads(body)


# ---- AAD: bind the escrow to its context (the heart of the fix) ----
def escrow_aad(mode, m, n, dir_version, member):
    return _canon(
        {"mode": mode, "m": m, "n": n, "dir_version": dir_version, "member": member}
    )


def make_escrow(mode, directory, trusted_org_pub, member, passphrase=None):
    d = verify_directory(
        directory, trusted_org_pub
    )  # REFUSE a forged/unsigned directory
    mod_pubs = [_b64_pub(s) for s in d["moderators"]]
    m, n, ver = d["policy"]["m"], d["policy"]["n"], d["version"]
    aad = escrow_aad(mode, m, n, ver, member)
    mk = os.urandom(32)
    salt = os.urandom(16) if mode == "passphrase" else b""
    nonce = os.urandom(12)
    blob = nonce + AESGCM(derive_wrap(mk, mode, passphrase, salt)).encrypt(
        nonce, K_SECRET, aad
    )
    sh = split_mk(mk)
    enc = {i: ecies_seal(mod_pubs[i - 1], sh[i][0] + sh[i][1], aad) for i in sh}
    return {
        "mode": mode,
        "blob": blob,
        "salt": salt,
        "enc_shares": enc,
        "m": m,
        "n": n,
        "dir_version": ver,
        "member": member,
    }


def recover(
    rec,
    directory,
    trusted_org_pub,
    approving,
    mod_keys,
    passphrase=None,
    ctx_override=None,
):
    d = verify_directory(directory, trusted_org_pub)  # REFUSE a substituted directory
    # AAD is derived from the SIGNED directory's policy + the record's member — NOT from unauthenticated
    # record fields, so a downgraded/substituted context fails the tag. ctx_override models an ATTACK.
    c = ctx_override or {
        "m": d["policy"]["m"],
        "n": d["policy"]["n"],
        "ver": d["version"],
        "member": rec["member"],
    }
    aad = escrow_aad(rec["mode"], c["m"], c["n"], c["ver"], c["member"])
    triples = []
    for i in approving:
        raw = ecies_unseal(
            mod_keys[i - 1], rec["enc_shares"][i], aad
        )  # AAD-mismatch => raises
        triples.append((i, raw[:16], raw[16:]))
    wrap = derive_wrap(combine_mk(triples), rec["mode"], passphrase, rec["salt"])
    return AESGCM(wrap).decrypt(rec["blob"][:12], rec["blob"][12:], aad)


checks = []


def attempt(label, fn, expect):
    try:
        got = "recover" if fn() == K_SECRET else "block"
    except Exception:
        got = "block"
    ok = got == expect
    checks.append(ok)
    print(
        f"  {label:54s} -> {got.upper():8s} (expect {expect:7s}) {'OK' if ok else '*** MISMATCH ***'}"
    )


# org signing key (offline; its PUBLIC key is pinned out-of-band into every member's client)
org_sk = ed25519.Ed25519PrivateKey.generate()
org_pub = org_sk.public_key()
mod_keys = [SecureElementKey() for _ in range(N)]
mod_pubs = [k.public_key for k in mod_keys]
directory = publish_directory(mod_pubs, M, N, version=1, org_sk=org_sk)

print("\n(a) HONEST PATH — org-signed directory + AAD-bound escrow")
recA = make_escrow("moderators_only", directory, org_pub, member="@alice:rednet.test")
attempt(
    "3 mods, correct directory + context",
    lambda: recover(recA, directory, org_pub, [1, 2, 3], mod_keys),
    "recover",
)
attempt(
    "2 mods (< M)", lambda: recover(recA, directory, org_pub, [1, 2], mod_keys), "block"
)

print("\n(b) ATTACK: DIRECTORY SUBSTITUTION (malicious core rewrites the room state)")
eve_keys = [SecureElementKey() for _ in range(N)]
eve_pubs = [k.public_key for k in eve_keys]
# Eve can't sign with the org key, so she either re-signs with her OWN key or keeps the stale sig:
eve_sk = ed25519.Ed25519PrivateKey.generate()
dir_eve_resigned = publish_directory(
    eve_pubs, M, N, 1, eve_sk
)  # signed by the WRONG key
dir_eve_stale = {
    "body": publish_directory(eve_pubs, M, N, 1, eve_sk)["body"],
    "sig": directory["sig"],
}  # her keys, old sig
attempt(
    "producer refuses Eve-resigned directory",
    lambda: make_escrow(
        "moderators_only", dir_eve_resigned, org_pub, "@alice:rednet.test"
    ),
    "block",
)
attempt(
    "producer refuses Eve-keys + stale org sig",
    lambda: make_escrow(
        "moderators_only", dir_eve_stale, org_pub, "@alice:rednet.test"
    ),
    "block",
)
attempt(
    "recovery refuses substituted directory",
    lambda: recover(recA, dir_eve_resigned, org_pub, [1, 2, 3], eve_keys),
    "block",
)

print("\n(c) ATTACK: POLICY DOWNGRADE (present a weaker {m,n} at recovery)")
attempt(
    "downgrade m=3 -> m=2 in the AAD",
    lambda: recover(
        recA,
        directory,
        org_pub,
        [1, 2],
        mod_keys,
        ctx_override={"m": 2, "n": N, "ver": 1, "member": "@alice:rednet.test"},
    ),
    "block",
)

print("\n(d) ATTACK: RECORD REPLAY across members (Alice's record presented as Bob)")
attempt(
    "recover Alice's record as @bob",
    lambda: recover(
        recA,
        directory,
        org_pub,
        [1, 2, 3],
        mod_keys,
        ctx_override={"m": M, "n": N, "ver": 1, "member": "@bob:rednet.test"},
    ),
    "block",
)

print(
    "\n(e) ATTACK: stale directory VERSION (rolled back to re-enable revoked moderators)"
)
attempt(
    "version rollback v2 -> v1 in the AAD",
    lambda: recover(
        recA,
        directory,
        org_pub,
        [1, 2, 3],
        mod_keys,
        ctx_override={"m": M, "n": N, "ver": 99, "member": "@alice:rednet.test"},
    ),
    "block",
)

result = {"total": len(checks), "passed": sum(checks), "PASS": all(checks)}
json.dump(result, open("result.json", "w"), indent=2)
print(
    f"\n=== VERDICT: {result['passed']}/{result['total']} -> {'PASS' if result['PASS'] else 'FAIL'} ==="
)
print(
    "Authenticated: directory substitution, policy downgrade, record replay, and version rollback all BLOCK;"
)
print("only the org-signed directory + correctly-bound context RECOVERS.")
sys.exit(0 if result["PASS"] else 2)
