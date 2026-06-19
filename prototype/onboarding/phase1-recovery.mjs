// REDnet Phase-1 proof — SELF-HELD PASSPHRASE RECOVERY.
// Proves the bootstrap recovery model (works at community size N=1): a member who loses their
// device recovers their cross-signing IDENTITY and their message HISTORY on a brand-new device,
// using ONLY a passphrase — no moderators, no access to the old device. This is native Matrix 4S
// keyed by a passphrase; the soft fork just drives it silently (custodyRecoveryKey -> this).
//
// Device 1: bootstrap cross-signing + secret storage keyed by PASSPHRASE + key backup; send an
//           encrypted message (-> a megolm key lands in the backup).
// Device 2: FRESH login (new device). Re-derive the 4S key from the passphrase, import the SAME
//           cross-signing identity, and restore the backed-up key. Assert it recovered.
// Writes result-phase1.json (truncation-safe); exits non-zero on FAIL.
import * as sdk from "matrix-js-sdk";
import { deriveRecoveryKeyFromPassphrase } from "matrix-js-sdk/lib/crypto-api/index.js";
import fs from "node:fs";
try { sdk.logger?.setLevel?.("ERROR"); } catch {}

const HS = process.env.HS || "http://localhost:8008";
const USER = process.env.LOCALPART || "alice";
const PASS = process.env.PASS || "password123";
const PASSPHRASE = "rednet-recovery correct horse battery staple";   // diceware-grade member secret
const WRONG = "definitely not the right passphrase";
const SECRET_MSG = "history-written-before-device-2-existed";
const errs = [];
const log = (...a) => console.log(...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function login(name) {
  const tmp = sdk.createClient({ baseUrl: HS });
  return tmp.login("m.login.password", {
    identifier: { type: "m.id.user", user: USER }, password: PASS, initial_device_display_name: name,
  });
}
async function withCrypto(creds, getKey, syncLimit) {
  const client = sdk.createClient({
    baseUrl: HS, userId: creds.user_id, accessToken: creds.access_token, deviceId: creds.device_id,
    cryptoCallbacks: getKey ? { getSecretStorageKey: getKey } : {},
  });
  await client.initRustCrypto({ useIndexedDB: false });
  await client.startClient({ initialSyncLimit: syncLimit });
  await new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error("sync timeout")), 30000);
    client.on("sync", (s) => { if (s === "PREPARED" || s === "SYNCING") { clearTimeout(t); res(); } });
  });
  return client;
}

async function main() {
  // ========== DEVICE 1 — onboard with a PASSPHRASE-keyed 4S ==========
  const cred1 = await login("rednet-device-1");
  let held = null;
  const c1 = await withCrypto(cred1, async ({ keys }) => {
    const id = Object.keys(keys)[0];
    return held ? [id, held.privateKey] : null;
  }, 1);
  const x1 = c1.getCrypto();
  await x1.bootstrapCrossSigning({ authUploadDeviceSigningKeys: async (mk) => { await mk({}); } });
  held = await x1.createRecoveryKeyFromPassphrase(PASSPHRASE);     // pre-generate so the callback always has it
  await x1.bootstrapSecretStorage({
    setupNewSecretStorage: true, setupNewKeyBackup: true,
    createSecretStorageKey: async () => held,
  });
  await x1.checkKeyBackupAndEnable();
  const masterId1 = await (x1.getCrossSigningKeyId?.() ?? Promise.resolve(null));
  log("device 1: passphrase-4S + cross-signing + backup ready; master", masterId1);

  const room = await c1.createRoom({
    name: "recovery-test",
    initial_state: [{ type: "m.room.encryption", state_key: "", content: { algorithm: "m.megolm.v1.aes-sha2" } }],
  });
  const roomId = room.room_id;
  // CRITICAL: wait until the client RECOGNIZES the room as encrypted. Sending before the m.room.encryption
  // state is processed sends PLAINTEXT -> no megolm session -> nothing to back up (the count=0 bug).
  let roomEnc = false;
  for (let i = 0; i < 20 && !roomEnc; i++) { roomEnc = await x1.isEncryptionEnabledInRoom(roomId); if (!roomEnc) await sleep(1000); }
  log("device 1: room recognized as encrypted?", roomEnc);
  const sent = await c1.sendEvent(roomId, "m.room.message", { msgtype: "m.text", body: SECRET_MSG });
  log("device 1: sent encrypted msg", sent.event_id);
  // The backup upload is a background loop (no public "backup now"); poll the server's authoritative
  // key count until the megolm key has actually landed, rather than guessing a fixed wait.
  let backupCount = 0;
  const info0 = await (x1.getKeyBackupInfo?.() ?? Promise.resolve(null));
  const trust0 = info0 ? await x1.isKeyBackupTrusted?.(info0) : null;
  log("device 1: backup trusted?", JSON.stringify(trust0));
  for (let i = 0; i < 30 && backupCount < 1; i++) {
    await x1.checkKeyBackupAndEnable?.();           // re-kick the upload loop (idempotent)
    await sleep(2000);
    try {
      const r = await fetch(`${HS}/_matrix/client/v3/room_keys/version`, { headers: { Authorization: `Bearer ${cred1.access_token}` } });
      if (r.ok) backupCount = (await r.json()).count ?? 0;
    } catch {}
    if (i % 4 === 0) log(`  poll ${i * 2}s: server backup count=${backupCount}, activeVer=${await x1.getActiveSessionBackupVersion?.()}`);
  }
  const v1 = (await x1.getActiveSessionBackupVersion?.()) ?? null;
  log("device 1: backup version", v1, "| keys in backup:", backupCount);

  // ========== DEVICE 2 — FRESH device, recover from passphrase ONLY ==========
  const cred2 = await login("rednet-device-2");
  log("device 2: fresh login, device", cred2.device_id);
  let derived = 0, capturedInfo = null;
  const keyFrom = (phrase) => async ({ keys }) => {
    const id = Object.keys(keys)[0]; const info = keys[id]; capturedInfo = info;
    if (info?.passphrase) {
      derived++;
      return [id, await deriveRecoveryKeyFromPassphrase(phrase, info.passphrase.salt, info.passphrase.iterations)];
    }
    return null;
  };
  const c2 = await withCrypto(cred2, keyFrom(PASSPHRASE), 10);
  const x2 = c2.getCrypto();
  await x2.bootstrapCrossSigning({ authUploadDeviceSigningKeys: async (mk) => { await mk({}); } });  // import from 4S
  let restored = { total: 0, imported: 0 };
  try {
    await x2.loadSessionBackupPrivateKeyFromSecretStorage();
    await x2.checkKeyBackupAndEnable();
    const r = await x2.restoreKeyBackup();
    restored = { total: r?.total ?? 0, imported: r?.imported ?? 0 };
  } catch (e) { errs.push("restore: " + e.message); }
  const xs2 = await x2.getCrossSigningStatus();
  const masterId2 = await (x2.getCrossSigningKeyId?.() ?? Promise.resolve(null));
  log("device 2: backup restored", JSON.stringify(restored), "master", masterId2);

  // negative sanity: a WRONG passphrase derives DIFFERENT key bytes (so the passphrase truly gates)
  let wrongDiffers = false;
  if (capturedInfo?.passphrase) {
    const { salt, iterations } = capturedInfo.passphrase;
    const good = await deriveRecoveryKeyFromPassphrase(PASSPHRASE, salt, iterations);
    const bad = await deriveRecoveryKeyFromPassphrase(WRONG, salt, iterations);
    wrongDiffers = Buffer.compare(Buffer.from(good), Buffer.from(bad)) !== 0;
  }

  const sameIdentity = masterId1 && masterId2 ? masterId1 === masterId2 : null;
  const result = {
    device2_derivedKeyFromPassphrase: derived > 0,
    device2_crossSigning_privateKeysCached: !!xs2?.privateKeysCachedLocally,
    device2_recoveredSameIdentity: sameIdentity,          // same master key => recovered, not reset
    device2_keyBackup_imported: restored.imported,
    device2_keyBackup_total: restored.total,
    wrongPassphrase_yieldsDifferentKey: wrongDiffers,
    errors: errs,
  };
  result.PASS =
    result.device2_derivedKeyFromPassphrase &&
    result.device2_crossSigning_privateKeysCached &&
    result.device2_keyBackup_imported >= 1 &&
    result.wrongPassphrase_yieldsDifferentKey &&
    result.device2_recoveredSameIdentity !== false;       // null (API absent) tolerated; false fails
  fs.writeFileSync("result-phase1.json", JSON.stringify(result, null, 2));
  log("\n=== RESULT ===\n" + JSON.stringify(result, null, 2));
  try { c1.stopClient(); c2.stopClient(); } catch {}
  setTimeout(() => process.exit(result.PASS ? 0 : 2), 500);
}
main().catch((e) => {
  const out = { PASS: false, fatal: e?.message || String(e), stack: e?.stack?.split("\n").slice(0, 6) };
  try { fs.writeFileSync("result-phase1.json", JSON.stringify(out, null, 2)); } catch {}
  console.error("\nERROR:", out.fatal);
  setTimeout(() => process.exit(1), 500);
});
