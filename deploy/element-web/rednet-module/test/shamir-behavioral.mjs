/**
 * Behavioral verification of shamir-secret-sharing for REDnet Phase-2 escrow.
 * Proves the same properties as spikes 05-08, using the production library.
 *
 * Run: node test/shamir-behavioral.mjs
 */
import { split, combine } from "shamir-secret-sharing";

const checks = [];

async function attempt(label, fn, expect) {
  let got;
  try {
    got = (await fn()) ? "recover" : "block";
  } catch {
    got = "block";
  }
  const ok = got === expect;
  checks.push(ok);
  const tag = ok ? "OK" : "*** MISMATCH ***";
  console.log(
    `  ${label.padEnd(58)} -> ${got.toUpperCase().padEnd(8)} (expect ${expect.padEnd(7)}) ${tag}`,
  );
}

function eq(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

async function aesWrap(key, pt) {
  const k = await crypto.subtle.importKey("raw", key, "AES-GCM", false, [
    "encrypt",
  ]);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, k, pt),
  );
  const out = new Uint8Array(12 + ct.length);
  out.set(nonce, 0);
  out.set(ct, 12);
  return out;
}

async function aesUnwrap(key, blob) {
  const k = await crypto.subtle.importKey("raw", key, "AES-GCM", false, [
    "decrypt",
  ]);
  return new Uint8Array(
    await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: blob.subarray(0, 12) },
      k,
      blob.subarray(12),
    ),
  );
}

const K =
  new TextEncoder().encode("4S-recovery-key::cross-signing+key-backup::CROWN-JEWEL");

// ---- (a) BASIC: M-of-N split/combine (3-of-5) ----
console.log("\n(a) BASIC SHAMIR (3-of-5)");
const mk = crypto.getRandomValues(new Uint8Array(32));
const blob = await aesWrap(mk, K);
const shares = await split(mk, 5, 3);

await attempt("3 shares reconstruct", async () => {
  const r = await combine([shares[0], shares[1], shares[2]]);
  return eq(await aesUnwrap(r, blob), K);
}, "recover");

await attempt("different 3 shares reconstruct", async () => {
  const r = await combine([shares[2], shares[3], shares[4]]);
  return eq(await aesUnwrap(r, blob), K);
}, "recover");

await attempt("all 5 shares reconstruct", async () => {
  const r = await combine(shares);
  return eq(await aesUnwrap(r, blob), K);
}, "recover");

await attempt("2 shares (< threshold) blocked by AEAD", async () => {
  const r = await combine([shares[0], shares[1]]);
  return eq(await aesUnwrap(r, blob), K);
}, "block");

// ---- (b) REVOCATION: re-share kills an evicted moderator's old share ----
console.log("\n(b) REVOCATION (re-share onto fresh polynomial)");
const oldShare3 = shares[2];

const mkR = await combine([shares[0], shares[1], shares[3]]);
const fresh = await split(mkR, 5, 3);

await attempt("3 NEW shares reconstruct", async () => {
  const r = await combine([fresh[0], fresh[1], fresh[2]]);
  return eq(await aesUnwrap(r, blob), K);
}, "recover");

await attempt("OLD share + 2 NEW shares blocked", async () => {
  const r = await combine([oldShare3, fresh[0], fresh[1]]);
  return eq(await aesUnwrap(r, blob), K);
}, "block");

// ---- (c) GROWTH: 2-of-3 -> 3-of-5 (threshold rises) ----
console.log("\n(c) GROWTH (2-of-3 -> 3-of-5)");
const mk2 = crypto.getRandomValues(new Uint8Array(32));
const blob2 = await aesWrap(mk2, K);
const v1 = await split(mk2, 3, 2);

await attempt("v1: 2-of-3 recovers", async () => {
  const r = await combine([v1[0], v1[1]]);
  return eq(await aesUnwrap(r, blob2), K);
}, "recover");

const mk2R = await combine(v1);
const v2 = await split(mk2R, 5, 3);

await attempt("v2: 3-of-5 NEW shares recover", async () => {
  const r = await combine([v2[0], v2[1], v2[2]]);
  return eq(await aesUnwrap(r, blob2), K);
}, "recover");

await attempt("v2: 2-of-5 NEW shares blocked (threshold rose)", async () => {
  const r = await combine([v2[0], v2[1]]);
  return eq(await aesUnwrap(r, blob2), K);
}, "block");

await attempt("MIX: 1 old v1 + 2 new v2 blocked", async () => {
  const r = await combine([v1[0], v2[1], v2[2]]);
  return eq(await aesUnwrap(r, blob2), K);
}, "block");

// ---- Verdict ----
const passed = checks.filter(Boolean).length;
const total = checks.length;
const ok = checks.every(Boolean);
console.log(
  `\n=== VERDICT: ${passed}/${total} checks -> ${ok ? "PASS" : "FAIL"} ===`,
);
process.exit(ok ? 0 : 2);
