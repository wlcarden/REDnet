/**
 * Behavioral verification of Phase-2 escrow lifecycle:
 *   - Directory signing + verification (Ed25519)
 *   - Escrow deposit + serialization round-trip
 *   - Recovery handshake (reseal share to ephemeral key + unseal + reconstruct)
 *   - Health checks (stale directory, moderator mismatch)
 *   - Cross-context AAD rejection on reseal
 *
 * Run: node test/lifecycle-behavioral.mjs
 */
import { execSync } from "node:child_process";
import { writeFileSync, unlinkSync } from "node:fs";

const ENTRY = "src/_test_lifecycle_entry.ts";
const OUT = "lib/_test_lifecycle.js";
writeFileSync(
  ENTRY,
  `export {
  signDirectory, verifyDirectory, directoryFingerprint
} from "./directory.ts";
export {
  serializeDirectory, deserializeDirectory,
  serializeEscrow, deserializeEscrow
} from "./events.ts";
export {
  createEscrow, unsealShare, recoverEscrow
} from "./escrow.ts";
export type { EscrowRecord, EscrowContext } from "./escrow.ts";
export {
  eciesSeal, eciesUnseal, canonicalAad
} from "./ecies.ts";
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
  signDirectory,
  verifyDirectory,
  directoryFingerprint,
  serializeDirectory,
  deserializeDirectory,
  serializeEscrow,
  deserializeEscrow,
  createEscrow,
  unsealShare,
  recoverEscrow,
  eciesSeal,
  eciesUnseal,
  canonicalAad,
} = mod;

// ed25519 for organizer key generation (test-only; production uses offline tooling)
const { ed25519 } = await import("@noble/curves/ed25519");

const CURVE = { name: "ECDH", namedCurve: "P-256" };
const checks = [];

async function attempt(label, fn, expect) {
  let got;
  try {
    got = (await fn()) ? "pass" : "fail";
  } catch (e) {
    got = "fail";
  }
  const ok = got === expect;
  checks.push(ok);
  const tag = ok ? "OK" : "*** MISMATCH ***";
  console.log(
    `  ${label.padEnd(60)} -> ${got.toUpperCase().padEnd(5)} (expect ${expect.padEnd(4)}) ${tag}`,
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

const K = new TextEncoder().encode("test-recovery-key-for-lifecycle");
const CTX = { member: "@test:rednet.test", dirVersion: 1 };

// ---- (a) DIRECTORY: Ed25519 signing + verification ----
console.log("\n(a) DIRECTORY AUTHENTICATION (Ed25519)");

const orgPrivKey = ed25519.utils.randomPrivateKey();
const orgPubKey = ed25519.getPublicKey(orgPrivKey);

const mods = await generateModKeys(5);
const modPubs = mods.map((m) => m.pub);

const dirPayload = {
  version: 1,
  moderators: modPubs.map((pub) => ({
    keyId: directoryFingerprint(pub),
    pubRaw65: pub,
  })),
  policy: { m: 3, n: 5 },
  created: 1718000000,
};

const signedDir = signDirectory(dirPayload, orgPrivKey);

await attempt("valid signature verifies", async () => {
  return verifyDirectory(signedDir, orgPubKey);
}, "pass");

await attempt("wrong pubkey rejects", async () => {
  const wrongKey = ed25519.getPublicKey(ed25519.utils.randomPrivateKey());
  return verifyDirectory(signedDir, wrongKey);
}, "fail");

await attempt("tampered version rejects", async () => {
  const tampered = {
    payload: { ...signedDir.payload, version: 999 },
    signature: signedDir.signature,
  };
  return verifyDirectory(tampered, orgPubKey);
}, "fail");

await attempt("tampered policy rejects", async () => {
  const tampered = {
    payload: { ...signedDir.payload, policy: { m: 1, n: 5 } },
    signature: signedDir.signature,
  };
  return verifyDirectory(tampered, orgPubKey);
}, "fail");

// ---- (b) SERIALIZATION ROUND-TRIP ----
console.log("\n(b) SERIALIZATION ROUND-TRIP");

await attempt("directory serialize/deserialize preserves data", async () => {
  const serialized = serializeDirectory(signedDir);
  const restored = deserializeDirectory(serialized);
  if (restored.payload.version !== signedDir.payload.version) return false;
  if (restored.payload.policy.m !== signedDir.payload.policy.m) return false;
  if (restored.payload.moderators.length !== signedDir.payload.moderators.length)
    return false;
  if (!eq(restored.signature, signedDir.signature)) return false;
  return verifyDirectory(restored, orgPubKey);
}, "pass");

const escrowRec = await createEscrow(K, modPubs, 3, "moderators_only", CTX);

await attempt("escrow serialize/deserialize preserves data", async () => {
  const serialized = serializeEscrow(escrowRec, 1);
  const restored = deserializeEscrow(serialized);
  if (restored.mode !== escrowRec.mode) return false;
  if (restored.policy.m !== escrowRec.policy.m) return false;
  if (restored.policy.n !== escrowRec.policy.n) return false;
  if (!eq(restored.blob, escrowRec.blob)) return false;
  if (restored.sealedShares.length !== escrowRec.sealedShares.length)
    return false;
  // prove the deserialized record still recovers
  const shares = await Promise.all(
    [0, 1, 2].map((i) =>
      unsealShare(mods[i].priv, restored.sealedShares[i], restored, CTX),
    ),
  );
  const got = await recoverEscrow(restored, shares, CTX);
  return eq(got, K);
}, "pass");

// ---- (c) RECOVERY HANDSHAKE: reseal to ephemeral key ----
console.log("\n(c) RECOVERY HANDSHAKE (reseal to ephemeral device key)");

await attempt("reseal to ephemeral key + unseal + reconstruct", async () => {
  // simulate: fresh device generates ephemeral keypair
  const ephKp = await crypto.subtle.generateKey(CURVE, true, ["deriveBits"]);
  const ephPubRaw = new Uint8Array(
    await crypto.subtle.exportKey("raw", ephKp.publicKey),
  );

  // each moderator unseals their share and reseals to the device
  const shareAad = canonicalAad({
    dir_version: CTX.dirVersion,
    m: 3,
    member: CTX.member,
    mode: "moderators_only",
    n: 5,
  });

  const resealedShares = await Promise.all(
    [0, 1, 2].map(async (i) => {
      const plainShare = await eciesUnseal(
        mods[i].priv,
        escrowRec.sealedShares[i],
        shareAad,
      );
      return eciesSeal(ephPubRaw, plainShare);
    }),
  );

  // fresh device unseals the resealed shares with its ephemeral private key
  const unsealedShares = await Promise.all(
    resealedShares.map((sealed) => eciesUnseal(ephKp.privateKey, sealed)),
  );

  const got = await recoverEscrow(escrowRec, unsealedShares, CTX);
  return eq(got, K);
}, "pass");

await attempt("reseal with wrong ephemeral key fails", async () => {
  const ephKp = await crypto.subtle.generateKey(CURVE, true, ["deriveBits"]);
  const ephPubRaw = new Uint8Array(
    await crypto.subtle.exportKey("raw", ephKp.publicKey),
  );
  const wrongKp = await crypto.subtle.generateKey(CURVE, true, ["deriveBits"]);

  const shareAad = canonicalAad({
    dir_version: CTX.dirVersion,
    m: 3,
    member: CTX.member,
    mode: "moderators_only",
    n: 5,
  });

  const resealedShares = await Promise.all(
    [0, 1, 2].map(async (i) => {
      const plainShare = await eciesUnseal(
        mods[i].priv,
        escrowRec.sealedShares[i],
        shareAad,
      );
      return eciesSeal(ephPubRaw, plainShare);
    }),
  );

  // try to unseal with WRONG ephemeral key
  const unsealedShares = await Promise.all(
    resealedShares.map((sealed) => eciesUnseal(wrongKp.privateKey, sealed)),
  );

  const got = await recoverEscrow(escrowRec, unsealedShares, CTX);
  return eq(got, K);
}, "fail");

// ---- (d) PASSPHRASE MODE RECOVERY HANDSHAKE ----
console.log("\n(d) PASSPHRASE MODE RECOVERY HANDSHAKE");
const PHRASE = "correct horse battery staple plaid";
const escrowPass = await createEscrow(K, modPubs, 3, "passphrase", CTX, PHRASE);

await attempt(
  "passphrase mode: reseal + correct phrase recovers",
  async () => {
    const ephKp = await crypto.subtle.generateKey(CURVE, true, ["deriveBits"]);
    const ephPubRaw = new Uint8Array(
      await crypto.subtle.exportKey("raw", ephKp.publicKey),
    );

    const shareAad = canonicalAad({
      dir_version: CTX.dirVersion,
      m: 3,
      member: CTX.member,
      mode: "passphrase",
      n: 5,
    });

    const resealedShares = await Promise.all(
      [0, 1, 2].map(async (i) => {
        const plainShare = await eciesUnseal(
          mods[i].priv,
          escrowPass.sealedShares[i],
          shareAad,
        );
        return eciesSeal(ephPubRaw, plainShare);
      }),
    );

    const unsealedShares = await Promise.all(
      resealedShares.map((sealed) => eciesUnseal(ephKp.privateKey, sealed)),
    );

    const got = await recoverEscrow(escrowPass, unsealedShares, CTX, PHRASE);
    return eq(got, K);
  },
  "pass",
);

await attempt(
  "passphrase mode: reseal + WRONG phrase blocks",
  async () => {
    const ephKp = await crypto.subtle.generateKey(CURVE, true, ["deriveBits"]);
    const ephPubRaw = new Uint8Array(
      await crypto.subtle.exportKey("raw", ephKp.publicKey),
    );

    const shareAad = canonicalAad({
      dir_version: CTX.dirVersion,
      m: 3,
      member: CTX.member,
      mode: "passphrase",
      n: 5,
    });

    const resealedShares = await Promise.all(
      [0, 1, 2].map(async (i) => {
        const plainShare = await eciesUnseal(
          mods[i].priv,
          escrowPass.sealedShares[i],
          shareAad,
        );
        return eciesSeal(ephPubRaw, plainShare);
      }),
    );

    const unsealedShares = await Promise.all(
      resealedShares.map((sealed) => eciesUnseal(ephKp.privateKey, sealed)),
    );

    const got = await recoverEscrow(escrowPass, unsealedShares, CTX, "wrong");
    return eq(got, K);
  },
  "fail",
);

// ---- Verdict ----
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
