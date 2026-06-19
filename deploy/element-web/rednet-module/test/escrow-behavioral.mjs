/**
 * Behavioral verification of the full escrow construction (Shamir + ECIES + scrypt).
 * Proves the same properties as spike 05, using the production code path.
 *
 * Run: node test/escrow-behavioral.mjs
 */

// Build the module first so we can import the bundled code.
// The escrow module isn't wired into index.ts yet, so we test via a
// dedicated esbuild entry point.
import { execSync } from "node:child_process";
import { writeFileSync, unlinkSync } from "node:fs";

const ENTRY = "src/_test_escrow_entry.ts";
const OUT = "lib/_test_escrow.js";
writeFileSync(
  ENTRY,
  `export {
  createEscrow, unsealShare, recoverEscrow, reshareEscrow
} from "./escrow.ts";
export { shamirCombine } from "./shamir.ts";
export { eciesSeal, eciesUnseal, canonicalAad } from "./ecies.ts";
`,
);

execSync(
  `npx esbuild ${ENTRY} --bundle --format=cjs --platform=browser --target=es2021 --outfile=${OUT}`,
  { stdio: "pipe" },
);
unlinkSync(ENTRY);

const raw = await import(`../${OUT}`);
const mod = raw.default ?? raw;
const {
  createEscrow,
  unsealShare,
  recoverEscrow,
  reshareEscrow,
} = mod;

// ---- helpers ----
const CURVE = { name: "ECDH", namedCurve: "P-256" };
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

async function generateModKeys(n) {
  const mods = [];
  for (let i = 0; i < n; i++) {
    const kp = await crypto.subtle.generateKey(CURVE, true, ["deriveBits"]);
    const pub = new Uint8Array(
      await crypto.subtle.exportKey("raw", kp.publicKey),
    );
    mods.push({ pub, priv: kp.privateKey });
  }
  return mods;
}

const K = new TextEncoder().encode(
  "4S-recovery-key::cross-signing+key-backup::CROWN-JEWEL",
);
const CTX = { member: "@alice:rednet.test", dirVersion: 1 };

// ---- (a) MODERATORS-ONLY (3-of-5) ----
console.log("\n(a) MODERATORS-ONLY (3-of-5, no member factor)");
const mods = await generateModKeys(5);
const modPubs = mods.map((m) => m.pub);

const recA = await createEscrow(K, modPubs, 3, "moderators_only", CTX);

await attempt("3 moderators recover", async () => {
  const shares = await Promise.all(
    [0, 1, 2].map((i) => unsealShare(mods[i].priv, recA.sealedShares[i], recA, CTX)),
  );
  const got = await recoverEscrow(recA, shares, CTX);
  return eq(got, K);
}, "recover");

await attempt("different 3 moderators recover", async () => {
  const shares = await Promise.all(
    [2, 3, 4].map((i) => unsealShare(mods[i].priv, recA.sealedShares[i], recA, CTX)),
  );
  const got = await recoverEscrow(recA, shares, CTX);
  return eq(got, K);
}, "recover");

await attempt("2 moderators (< threshold) blocked", async () => {
  const shares = await Promise.all(
    [0, 1].map((i) => unsealShare(mods[i].priv, recA.sealedShares[i], recA, CTX)),
  );
  const got = await recoverEscrow(recA, shares, CTX);
  return eq(got, K);
}, "block");

// ---- (b) PASSPHRASE + M-of-N ----
console.log("\n(b) PASSPHRASE + M-of-N (member factor ANDed with quorum)");
const PHRASE = "correct horse battery staple";

const recB = await createEscrow(K, modPubs, 3, "passphrase", CTX, PHRASE);

await attempt("3 mods + correct phrase", async () => {
  const shares = await Promise.all(
    [0, 1, 2].map((i) => unsealShare(mods[i].priv, recB.sealedShares[i], recB, CTX)),
  );
  const got = await recoverEscrow(recB, shares, CTX, PHRASE);
  return eq(got, K);
}, "recover");

await attempt("3 mods + WRONG phrase", async () => {
  const shares = await Promise.all(
    [0, 1, 2].map((i) => unsealShare(mods[i].priv, recB.sealedShares[i], recB, CTX)),
  );
  const got = await recoverEscrow(recB, shares, CTX, "hunter2");
  return eq(got, K);
}, "block");

await attempt("2 mods + correct phrase (< threshold)", async () => {
  const shares = await Promise.all(
    [0, 1].map((i) => unsealShare(mods[i].priv, recB.sealedShares[i], recB, CTX)),
  );
  const got = await recoverEscrow(recB, shares, CTX, PHRASE);
  return eq(got, K);
}, "block");

await attempt("3 mods + NO phrase (coerced quorum)", async () => {
  const shares = await Promise.all(
    [0, 1, 2].map((i) => unsealShare(mods[i].priv, recB.sealedShares[i], recB, CTX)),
  );
  const got = await recoverEscrow(recB, shares, CTX);
  return eq(got, K);
}, "block");

// ---- (c) REVOCATION: re-share kills evicted moderator's old share ----
console.log("\n(c) REVOCATION (re-share onto fresh polynomial)");

const oldShares = await Promise.all(
  [0, 1, 2].map((i) => unsealShare(mods[i].priv, recA.sealedShares[i], recA, CTX)),
);
const oldShare2 = oldShares[2];

const survivors = [0, 1, 3];
const survivorShares = await Promise.all(
  survivors.map((i) => unsealShare(mods[i].priv, recA.sealedShares[i], recA, CTX)),
);

const recA2 = await reshareEscrow(recA, survivorShares, modPubs, 3, CTX);

await attempt("3 NEW shares reconstruct", async () => {
  const shares = await Promise.all(
    [0, 1, 2].map((i) =>
      unsealShare(mods[i].priv, recA2.sealedShares[i], recA2, CTX),
    ),
  );
  const got = await recoverEscrow(recA2, shares, CTX);
  return eq(got, K);
}, "recover");

await attempt("OLD share + 2 NEW shares blocked", async () => {
  const newShares = await Promise.all(
    [0, 1].map((i) =>
      unsealShare(mods[i].priv, recA2.sealedShares[i], recA2, CTX),
    ),
  );
  const got = await recoverEscrow(recA2, [oldShare2, ...newShares], CTX);
  return eq(got, K);
}, "block");

// ---- (d) GROWTH: 2-of-3 -> 3-of-5 ----
console.log("\n(d) GROWTH (2-of-3 -> 3-of-5)");
const mods3 = mods.slice(0, 3);
const pubs3 = mods3.map((m) => m.pub);

const recD = await createEscrow(K, pubs3, 2, "moderators_only", CTX);

await attempt("v1: 2-of-3 recovers", async () => {
  const shares = await Promise.all(
    [0, 1].map((i) => unsealShare(mods3[i].priv, recD.sealedShares[i], recD, CTX)),
  );
  const got = await recoverEscrow(recD, shares, CTX);
  return eq(got, K);
}, "recover");

const v1Shares = await Promise.all(
  [0, 1, 2].map((i) =>
    unsealShare(mods3[i].priv, recD.sealedShares[i], recD, CTX),
  ),
);
const recD2 = await reshareEscrow(recD, v1Shares, modPubs, 3, CTX);

await attempt("v2: 3-of-5 recovers", async () => {
  const shares = await Promise.all(
    [0, 1, 2].map((i) =>
      unsealShare(mods[i].priv, recD2.sealedShares[i], recD2, CTX),
    ),
  );
  const got = await recoverEscrow(recD2, shares, CTX);
  return eq(got, K);
}, "recover");

await attempt("v2: 2-of-5 blocked (threshold rose)", async () => {
  const shares = await Promise.all(
    [0, 1].map((i) =>
      unsealShare(mods[i].priv, recD2.sealedShares[i], recD2, CTX),
    ),
  );
  const got = await recoverEscrow(recD2, shares, CTX);
  return eq(got, K);
}, "block");

// ---- (e) CROSS-CONTEXT: wrong member AAD rejects ----
console.log("\n(e) CROSS-CONTEXT (AAD binding)");
const CTX_BOB = { member: "@bob:rednet.test", dirVersion: 1 };

await attempt("wrong member context rejects share unseal", async () => {
  await unsealShare(mods[0].priv, recA.sealedShares[0], recA, CTX_BOB);
  return true;
}, "block");

// ---- Verdict ----
// Cleanup
try {
  unlinkSync(OUT);
} catch {}

const passed = checks.filter(Boolean).length;
const total = checks.length;
const ok = checks.every(Boolean);
console.log(
  `\n=== VERDICT: ${passed}/${total} checks -> ${ok ? "PASS" : "FAIL"} ===`,
);
process.exit(ok ? 0 : 2);
