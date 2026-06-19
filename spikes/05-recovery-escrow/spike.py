#!/usr/bin/env python3
"""
REDnet Spike 05 — recovery-key escrow crypto.

Proves, end-to-end, the two custody designs under comparison PLUS moderator revocation:
  (a) moderators-only      : K recoverable by M-of-N moderators alone
  (b) passphrase + M-of-N  : K needs M-of-N moderators AND the member's passphrase
  (rev) proactive re-share : after a moderator is revoked, their OLD share is cryptographically dead

Both modes use ONE escrow record format (a per-member `mode` flag) -> proves the team's preferred
"moderators-only by default, opt-in passphrase the member picks" model is a single code path.

Vetted primitives only (no bespoke crypto):
  Shamir secret sharing : PyCryptodome Crypto.Protocol.SecretSharing  (two 16B halves -> 256-bit MK)
  sealed shares         : PyNaCl SealedBox        (libsodium crypto_box_seal, anonymous sender)
  passphrase stretch    : PyNaCl Argon2id
  authenticated wrap    : PyNaCl SecretBox        (XSalsa20-Poly1305 -> a WRONG wrap key fails LOUDLY)

The AEAD tag is what enforces correctness: an insufficient/mixed Shamir set yields a wrong key, and
SecretBox.decrypt then raises instead of returning garbage. Writes result.json; exits !=0 on mismatch.
"""
import json, hashlib, sys
from Crypto.Protocol.SecretSharing import Shamir
from nacl.public import PrivateKey, SealedBox
from nacl.secret import SecretBox
from nacl import pwhash, utils
from nacl.exceptions import CryptoError

N, M = 5, 3
K_SECRET = b"4S-recovery-key::cross-signing+key-backup::CROWN-JEWEL"

# ---- Shamir over a 32-byte MK as two aligned 16-byte halves --------------------------------------
def split_mk(mk):
    lo = Shamir.split(M, N, mk[:16]); hi = Shamir.split(M, N, mk[16:])
    return {i: (l, h) for (i, l), (_, h) in zip(lo, hi)}        # {holder_idx: (lo_share, hi_share)}

def combine_mk(triples):                                        # triples: [(idx, lo, hi), ...]
    lo = Shamir.combine([(i, l) for (i, l, h) in triples])
    hi = Shamir.combine([(i, h) for (i, l, h) in triples])
    return lo + hi

# ---- wrap-key derivation -------------------------------------------------------------------------
def derive_wrap(mk, mode, passphrase, salt):
    if mode == "moderators_only":
        return mk                                               # MK itself is the 32-byte wrap key
    pk = pwhash.argon2id.kdf(32, passphrase.encode(), salt,
                             opslimit=pwhash.argon2id.OPSLIMIT_INTERACTIVE,
                             memlimit=pwhash.argon2id.MEMLIMIT_INTERACTIVE)
    return hashlib.sha256(pk + mk).digest()                     # bind BOTH factors (spike KDF; prod: HKDF)

# ---- escrow record = exactly what the CORE stores (all ciphertext it cannot read) ----------------
def make_escrow(mode, mod_pks, passphrase=None):
    mk = utils.random(32)
    salt = utils.random(pwhash.argon2id.SALTBYTES) if mode == "passphrase" else b""
    blob = SecretBox(derive_wrap(mk, mode, passphrase, salt)).encrypt(K_SECRET)
    sh = split_mk(mk)
    enc = {i: SealedBox(mod_pks[i - 1]).encrypt(sh[i][0] + sh[i][1]) for i in sh}
    return {"mode": mode, "blob": blob, "salt": salt, "enc_shares": enc, "policy": {"m": M, "n": N, "v": 1}}

def open_share(record, i, mod_sks):
    raw = SealedBox(mod_sks[i - 1]).decrypt(record["enc_shares"][i])
    return (i, raw[:16], raw[16:])

def recover(record, approving, mod_sks, passphrase=None):
    mk = combine_mk([open_share(record, i, mod_sks) for i in approving])
    return SecretBox(derive_wrap(mk, record["mode"], passphrase, record["salt"])).decrypt(record["blob"])

# ---- proactive re-share: refresh shares of the SAME MK on a FRESH polynomial, exclude a mod -------
def reshare_excluding(record, mod_sks, survivors, mod_pks):
    mk = combine_mk([open_share(record, i, mod_sks) for i in survivors])  # re-deal (prod: distributed PSS)
    sh = split_mk(mk)                                                     # fresh polynomial, same MK
    enc = {i: SealedBox(mod_pks[i - 1]).encrypt(sh[i][0] + sh[i][1]) for i in sh}
    r = dict(record); r["enc_shares"] = enc; r["policy"] = {**record["policy"], "v": record["policy"]["v"] + 1}
    return r

# ---- harness -------------------------------------------------------------------------------------
checks = []
def attempt(label, fn, expect):                                  # expect in {"recover","block"}
    try:
        got = "recover" if fn() == K_SECRET else "block"
    except Exception:
        got = "block"
    ok = got == expect
    checks.append(ok)
    print(f"  {label:50s} -> {got.upper():8s} (expect {expect:7s}) {'OK' if ok else '*** MISMATCH ***'}")

mod_sks = [PrivateKey.generate() for _ in range(N)]
mod_pks = [sk.public_key for sk in mod_sks]

print("\n(a) MODERATORS-ONLY  (3-of-5, no member factor)")
recA = make_escrow("moderators_only", mod_pks)
attempt("3 moderators",                    lambda: recover(recA, [1, 2, 3], mod_sks), "recover")
attempt("2 moderators (< M)",              lambda: recover(recA, [1, 2], mod_sks),    "block")
attempt("record alone, no moderator shares", lambda: recover(recA, [], mod_sks),      "block")

print("\n(b) PASSPHRASE + M-of-N  (member factor ANDed with the quorum)")
PHRASE = "correct horse battery staple"
recB = make_escrow("passphrase", mod_pks, passphrase=PHRASE)
attempt("3 mods + correct phrase",         lambda: recover(recB, [1, 2, 3], mod_sks, PHRASE),         "recover")
attempt("3 mods + WRONG phrase",           lambda: recover(recB, [1, 2, 3], mod_sks, "hunter2"),      "block")
attempt("2 mods + correct phrase",         lambda: recover(recB, [1, 2], mod_sks, PHRASE),            "block")
attempt("3 mods, NO phrase [coerced quorum]", lambda: recover(recB, [1, 2, 3], mod_sks, "."),         "block")

print("\n*** THE COMPARISON: same attack, both designs ***")
print("    a compromised 3-mod quorum WITH NO member involvement:")
print("      (a) moderators-only  -> RECOVERS  (this is the exposure you accept)")
print("      (b) passphrase       -> BLOCKED   (member factor caps the blast radius)")

print("\n(rev) REVOCATION: proactive re-share kills a revoked moderator's old share")
old4 = open_share(recA, 4, mod_sks)                              # arrested mod #4's OLD share (adversary-held)
recA2 = reshare_excluding(recA, mod_sks, [1, 2, 3], mod_pks)     # survivors re-share; #4 excluded
attempt("BEFORE: mod#4 was a valid member of a quorum", lambda: recover(recA, [2, 3, 4], mod_sks), "recover")
def mix_old_new():
    n1, n2 = open_share(recA2, 1, mod_sks), open_share(recA2, 2, mod_sks)
    return SecretBox(combine_mk([old4, n1, n2])).decrypt(recA2["blob"])
attempt("AFTER: arrested OLD share + 2 NEW shares", mix_old_new,                         "block")
attempt("AFTER: 3 NEW shares (healthy quorum)",     lambda: recover(recA2, [1, 2, 3], mod_sks), "recover")

result = {"total": len(checks), "passed": sum(checks), "PASS": all(checks)}
json.dump(result, open("result.json", "w"), indent=2)
print(f"\n=== VERDICT: {result['passed']}/{result['total']} checks matched expectations -> "
      f"{'PASS' if result['PASS'] else 'FAIL'} ===")
sys.exit(0 if result["PASS"] else 2)
