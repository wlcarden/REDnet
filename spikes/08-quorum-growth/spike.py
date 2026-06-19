#!/usr/bin/env python3
"""
REDnet Spike 08 — quorum growth: M/N scales as the community grows.

Proves the mechanism behind RECOVERY.md §11/§12 scaling: a recovery quorum can GROW (2-of-3 -> 3-of-5)
by re-sharing the SAME wrap key onto a fresh, higher-threshold polynomial. Verifies that after growth:
  - the new quorum recovers,
  - the threshold actually rose (what was enough before is now insufficient),
  - old and new shares are cryptographically incompatible (can't be mixed).
And documents the one OPERATIONAL caveat: old shares survive until honest moderators DELETE them
(re-sharing kills them only in combination with deletion — same caveat as §6 revocation).

Vetted: PyCryptodome Shamir + `cryptography` AES-256-GCM.
"""
import os, json, sys
from Crypto.Protocol.SecretSharing import Shamir
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

K = b"4S-recovery-key::CROWN-JEWEL"

def split(mk, m, n):                                  # Shamir m-of-n over a 32-byte MK (two 16B halves)
    lo = Shamir.split(m, n, mk[:16]); hi = Shamir.split(m, n, mk[16:])
    return {i: (l, h) for (i, l), (_, h) in zip(lo, hi)}
def combine(triples):
    return Shamir.combine([(i, l) for (i, l, h) in triples]) + Shamir.combine([(i, h) for (i, l, h) in triples])

mk = os.urandom(32)
nonce = os.urandom(12)
blob = nonce + AESGCM(mk).encrypt(nonce, K, None)
def unwrap(guess): return AESGCM(guess).decrypt(blob[:12], blob[12:], None)

checks = []
def check(label, fn, expect):
    try: got = "recover" if unwrap(fn()) == K else "block"
    except Exception: got = "block"
    ok = got == expect; checks.append(ok)
    print(f"  {label:54s} -> {got.upper():8s} (expect {expect:7s}) {'OK' if ok else '*** FAIL ***'}")

# --- v1: the community just reached 3 organizers -> 2-of-3 quorum ---
print("v1 quorum: 2-of-3 (community hit 3 trusted organizers)")
v1 = split(mk, 2, 3)
check("v1: 2 of 3 shares recover", lambda: combine([(i, *v1[i]) for i in [1, 2]]), "recover")

# --- GROWTH: two more organizers join -> re-share the SAME wrap key to 3-of-5 ---
print("grow -> 3-of-5 (re-share same wrap key onto a fresh, higher-threshold polynomial)")
mk_r = combine([(i, *v1[i]) for i in [1, 2, 3]])     # re-deal (prod: distributed PSS, no single reconstruct)
assert mk_r == mk
v2 = split(mk_r, 3, 5)
check("v2: 3 of 5 NEW shares recover", lambda: combine([(i, *v2[i]) for i in [1, 2, 3]]), "recover")
check("v2: 2 of 5 NEW shares blocked (threshold rose 2->3)", lambda: combine([(i, *v2[i]) for i in [1, 2]]), "block")
check("MIX: 1 old v1 share + 2 new v2 shares blocked", lambda: combine([(1, *v1[1]), (2, *v2[2]), (3, *v2[3])]), "block")

# OPERATIONAL caveat (NOT a crypto guarantee): re-sharing does not auto-kill old shares.
old_alive = False
try: old_alive = unwrap(combine([(i, *v1[i]) for i in [1, 2]])) == K
except Exception: pass
print(f"\n  [operational] old 2-of-3 shares STILL reconstruct until deleted: {old_alive}")
print("  -> honest moderators MUST delete old shares on every re-share; deletion (not the new polynomial)")
print("     is what kills them. Same caveat as §6 revocation. A KNOWN-compromised mod => re-key, not just re-share.")

result = {"total": len(checks), "passed": sum(checks), "PASS": all(checks)}
json.dump(result, open("result.json", "w"), indent=2)
print(f"\n=== VERDICT: {result['passed']}/{result['total']} crypto checks -> {'PASS' if result['PASS'] else 'FAIL'} ===")
sys.exit(0 if result["PASS"] else 2)
