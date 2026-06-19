/**
 * P-256 ECIES for REDnet Phase-2 escrow. WebCrypto-only, no dependencies.
 *
 * Construction: blob = ephemeral_pub(65) || nonce(12) || AES-256-GCM(
 *   key = HKDF-SHA256(ECDH(eph, recipient), info="rednet-ecies"),
 *   nonce, plaintext, aad
 * )
 *
 * Cross-checked against spikes/test-vectors/primitives.json (Python reference).
 */

const CURVE: EcKeyGenParams = { name: "ECDH", namedCurve: "P-256" };
const INFO = new TextEncoder().encode("rednet-ecies");

const P256_P = BigInt(
  "0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF",
);
const P256_B = BigInt(
  "0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B",
);

function hexToBytes(hex: string): Uint8Array {
  const a = new Uint8Array(hex.length / 2);
  for (let i = 0; i < a.length; i++) {
    a[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return a;
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function bytesToBigInt(bytes: Uint8Array): bigint {
  let n = 0n;
  for (const b of bytes) n = (n << 8n) | BigInt(b);
  return n;
}

function mod(a: bigint, m: bigint): bigint {
  return ((a % m) + m) % m;
}

export function validateP256Point(raw65: Uint8Array): void {
  if (raw65.length !== 65 || raw65[0] !== 0x04) {
    throw new Error("not an uncompressed P-256 point");
  }
  const x = bytesToBigInt(raw65.subarray(1, 33));
  const y = bytesToBigInt(raw65.subarray(33, 65));
  if (x === 0n && y === 0n) {
    throw new Error("identity / zero point");
  }
  if (x >= P256_P || y >= P256_P) {
    throw new Error("coordinate >= field prime");
  }
  const lhs = mod(y * y, P256_P);
  const rhs = mod(x * x * x - 3n * x + P256_B, P256_P);
  if (lhs !== rhs) {
    throw new Error("point not on P-256 curve");
  }
}

async function importEcdhPub(raw65: Uint8Array): Promise<CryptoKey> {
  validateP256Point(raw65);
  return crypto.subtle.importKey("raw", raw65, CURVE, false, []);
}

async function ecdh(
  privKey: CryptoKey,
  pubKey: CryptoKey,
): Promise<ArrayBuffer> {
  return crypto.subtle.deriveBits(
    { name: "ECDH", public: pubKey },
    privKey,
    256,
  );
}

async function hkdfSha256(
  ikm: ArrayBuffer,
  info: Uint8Array,
  length: number,
): Promise<ArrayBuffer> {
  const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, [
    "deriveBits",
  ]);
  return crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info },
    key,
    length * 8,
  );
}

async function aesGcmEncrypt(
  key: ArrayBuffer,
  nonce: Uint8Array,
  plaintext: Uint8Array,
  aad?: Uint8Array,
): Promise<ArrayBuffer> {
  const aesKey = await crypto.subtle.importKey("raw", key, "AES-GCM", false, [
    "encrypt",
  ]);
  const params: AesGcmParams = { name: "AES-GCM", iv: nonce };
  if (aad) params.additionalData = aad;
  return crypto.subtle.encrypt(params, aesKey, plaintext);
}

async function aesGcmDecrypt(
  key: ArrayBuffer,
  nonce: Uint8Array,
  ciphertext: Uint8Array,
  aad?: Uint8Array,
): Promise<ArrayBuffer> {
  const aesKey = await crypto.subtle.importKey("raw", key, "AES-GCM", false, [
    "decrypt",
  ]);
  const params: AesGcmParams = { name: "AES-GCM", iv: nonce };
  if (aad) params.additionalData = aad;
  return crypto.subtle.decrypt(params, aesKey, ciphertext);
}

export async function eciesSeal(
  recipientPubRaw65: Uint8Array,
  plaintext: Uint8Array,
  aad?: Uint8Array,
): Promise<Uint8Array> {
  const recipientPub = await importEcdhPub(recipientPubRaw65);
  const ephKp = await crypto.subtle.generateKey(CURVE, true, ["deriveBits"]);
  const ephPubRaw = new Uint8Array(
    await crypto.subtle.exportKey("raw", ephKp.publicKey),
  );
  const shared = await ecdh(ephKp.privateKey, recipientPub);
  const aesKey = await hkdfSha256(shared, INFO, 32);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await aesGcmEncrypt(aesKey, nonce, plaintext, aad));
  const blob = new Uint8Array(65 + 12 + ct.length);
  blob.set(ephPubRaw, 0);
  blob.set(nonce, 65);
  blob.set(ct, 77);
  return blob;
}

export async function eciesUnseal(
  recipientPrivKey: CryptoKey,
  blob: Uint8Array,
  aad?: Uint8Array,
): Promise<Uint8Array> {
  if (blob.length < 65 + 12 + 16) {
    throw new Error("blob too short");
  }
  const ephPubRaw = blob.subarray(0, 65);
  const nonce = blob.subarray(65, 77);
  const ct = blob.subarray(77);
  const ephPub = await importEcdhPub(ephPubRaw);
  const shared = await ecdh(recipientPrivKey, ephPub);
  const aesKey = await hkdfSha256(shared, INFO, 32);
  return new Uint8Array(await aesGcmDecrypt(aesKey, nonce, ct, aad));
}

export function canonicalAad(fields: Record<string, unknown>): Uint8Array {
  const sorted = JSON.stringify(fields, Object.keys(fields).sort());
  return new TextEncoder().encode(sorted);
}

export { hexToBytes, bytesToHex, hkdfSha256, aesGcmEncrypt, aesGcmDecrypt };
