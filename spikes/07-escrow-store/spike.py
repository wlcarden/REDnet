#!/usr/bin/env python3
"""
REDnet Spike 07 — Matrix-native escrow store + producer round-trip (Phase-2 components B + E).

Proves the DECIDED storage design end-to-end against a real Synapse, with NO new service:
  - moderator directory published as Matrix ROOM STATE (org.rednet.recovery.moderators)
  - the producer fetches it, builds the escrow (Spike-06 P-256 ECIES sealing), and stores the record
    in the member's ACCOUNT_DATA (org.rednet.recovery.escrow.*)
  - recovery on a "fresh device" = GET the record back + M moderators unseal -> reconstruct -> unwrap K
  - the server only ever holds opaque ciphertext (asserted)

Vetted: `cryptography` (P-256/HKDF/AES-GCM/scrypt) + PyCryptodome Shamir + `requests` (Matrix C-S API).
"""
import os, json, hashlib, sys, base64, requests
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from Crypto.Protocol.SecretSharing import Shamir

HS = os.environ.get("HS", "http://localhost:8010")
USER, PASS = os.environ.get("LOCALPART", "alice"), os.environ.get("PASS", "password123")
N, M = 5, 3
K_SECRET = b"4S-recovery-key::CROWN-JEWEL::escrowed-to-moderators"
b64 = lambda b: base64.b64encode(b).decode()
ub64 = lambda s: base64.b64decode(s)

# ---- P-256 ECIES + Shamir (from Spike 06) ----
class SecureElementKey:
    def __init__(self): self._k = ec.generate_private_key(ec.SECP256R1())
    def pub(self): return self._k.public_key().public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)
    def ecdh(self, peer): return self._k.exchange(ec.ECDH(), peer)

def _kdf(s): return HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=b"rednet-ecies").derive(s)
def ecies_seal(pub_bytes, pt):
    pub = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), pub_bytes)
    eph = ec.generate_private_key(ec.SECP256R1()); nonce = os.urandom(12)
    ephb = eph.public_key().public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)
    return ephb + nonce + AESGCM(_kdf(eph.exchange(ec.ECDH(), pub))).encrypt(nonce, pt, None)
def ecies_unseal(se, blob):
    eph = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), blob[:65])
    return AESGCM(_kdf(se.ecdh(eph))).decrypt(blob[65:77], blob[77:], None)
def split_mk(mk):
    lo = Shamir.split(M, N, mk[:16]); hi = Shamir.split(M, N, mk[16:])
    return {i: (l, h) for (i, l), (_, h) in zip(lo, hi)}
def combine_mk(t):
    return Shamir.combine([(i, l) for (i, l, h) in t]) + Shamir.combine([(i, h) for (i, l, h) in t])
def derive_wrap(mk, mode, passphrase, salt):
    if mode == "moderators_only": return mk
    pk = Scrypt(salt=salt, length=32, n=2**14, r=8, p=1).derive(passphrase.encode())
    return hashlib.sha256(pk + mk).digest()

# ---- Matrix C-S API (account_data store + room-state moderator directory) ----
class Matrix:
    def __init__(self, hs): self.hs, self.tok, self.uid = hs, None, None
    def login(self, u, p):
        d = requests.post(f"{self.hs}/_matrix/client/v3/login", json={"type": "m.login.password",
            "identifier": {"type": "m.id.user", "user": u}, "password": p}).json()
        self.tok, self.uid = d["access_token"], d["user_id"]; return self.uid
    def _h(self): return {"Authorization": f"Bearer {self.tok}"}
    def put_acct(self, typ, body): requests.put(f"{self.hs}/_matrix/client/v3/user/{self.uid}/account_data/{typ}", headers=self._h(), json=body).raise_for_status()
    def get_acct(self, typ):
        r = requests.get(f"{self.hs}/_matrix/client/v3/user/{self.uid}/account_data/{typ}", headers=self._h()); return r.json() if r.ok else None
    def create_room(self): return requests.post(f"{self.hs}/_matrix/client/v3/createRoom", headers=self._h(), json={"preset": "private_chat"}).json()["room_id"]
    def set_state(self, room, typ, body): requests.put(f"{self.hs}/_matrix/client/v3/rooms/{room}/state/{typ}/", headers=self._h(), json=body).raise_for_status()
    def get_state(self, room, typ):
        r = requests.get(f"{self.hs}/_matrix/client/v3/rooms/{room}/state/{typ}/", headers=self._h()); return r.json() if r.ok else None

checks = []
def check(label, cond):
    checks.append(bool(cond)); print(f"  {label:54s} {'OK' if cond else '*** FAIL ***'}")

m = Matrix(HS); print("member:", m.login(USER, PASS))
mods = [SecureElementKey() for _ in range(N)]  # moderator secure-element keys (only PUBLIC keys leave the device)

# (B/directory) publish the moderator directory as Matrix ROOM STATE
dir_room = m.create_room()
m.set_state(dir_room, "org.rednet.recovery.moderators", {
    "policy": {"m": M, "n": N},
    "moderators": [{"id": f"mod{i+1}", "p256_pub": b64(mods[i].pub())} for i in range(N)],
})
print("published moderator directory ->", dir_room)

def build_escrow(mode, passphrase=None):
    d = m.get_state(dir_room, "org.rednet.recovery.moderators")        # producer fetches the directory
    pubs = [ub64(x["p256_pub"]) for x in d["moderators"]]
    mk, salt, nonce = os.urandom(32), (os.urandom(16) if mode == "passphrase" else b""), os.urandom(12)
    blob = nonce + AESGCM(derive_wrap(mk, mode, passphrase, salt)).encrypt(nonce, K_SECRET, None)
    sh = split_mk(mk)
    return {"mode": mode, "blob": b64(blob), "salt": b64(salt),
            "enc_shares": {str(i): b64(ecies_seal(pubs[i-1], sh[i][0]+sh[i][1])) for i in sh}, "policy": d["policy"]}

# (E + B) build the escrow at onboarding and STORE it in the member's account_data
m.put_acct("org.rednet.recovery.escrow.mods", build_escrow("moderators_only"))
m.put_acct("org.rednet.recovery.escrow.pass", build_escrow("passphrase", "correct horse battery staple"))
print("stored escrow records in account_data")

def recover(typ, approving, passphrase=None):
    rec = m.get_acct(typ)                                              # fresh device just GETs it back
    triples = [(i, *( (lambda r: (r[:16], r[16:]))(ecies_unseal(mods[i-1], ub64(rec["enc_shares"][str(i)]))) )) for i in approving]
    blob = ub64(rec["blob"])
    return AESGCM(derive_wrap(combine_mk(triples), rec["mode"], passphrase, ub64(rec["salt"]))).decrypt(blob[:12], blob[12:], None)

print("\nround-trip recovery from the stored record:")
check("moderators-only: 3 mods recover K from account_data", recover("org.rednet.recovery.escrow.mods", [1, 2, 3]) == K_SECRET)
check("passphrase: 3 mods + correct phrase recover K", recover("org.rednet.recovery.escrow.pass", [1, 2, 3], "correct horse battery staple") == K_SECRET)
try: leaked = recover("org.rednet.recovery.escrow.pass", [1, 2, 3], "WRONG") == K_SECRET
except Exception: leaked = False
check("passphrase: 3 mods + WRONG phrase blocked", not leaked)
try: leaked2 = recover("org.rednet.recovery.escrow.mods", [1, 2]) == K_SECRET
except Exception: leaked2 = False
check("moderators-only: 2 mods (< M) blocked", not leaked2)

raw = json.dumps(m.get_acct("org.rednet.recovery.escrow.mods"))
check("server-stored record is OPAQUE (no plaintext K)", "CROWN-JEWEL" not in raw and b64(K_SECRET)[:24] not in raw)
check("account_data round-trip intact", m.get_acct("org.rednet.recovery.escrow.mods")["mode"] == "moderators_only")

result = {"total": len(checks), "passed": sum(checks), "PASS": all(checks)}
json.dump(result, open("result.json", "w"), indent=2)
print(f"\n=== VERDICT: {result['passed']}/{result['total']} -> {'PASS' if result['PASS'] else 'FAIL'} ===")
sys.exit(0 if result["PASS"] else 2)
