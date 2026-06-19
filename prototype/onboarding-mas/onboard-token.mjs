// Milestone B: silent E2EE bootstrap on a MAS-created account, using a MAS-issued token
// (no password login — the token came from issue-compatibility-token). Same proven crypto
// path as milestone A. Writes result.json.
import * as sdk from "matrix-js-sdk";
import fs from "node:fs";
try { sdk.logger?.setLevel?.("ERROR"); } catch {}

const HS = process.env.HS || "http://localhost:8008";
const USER_ID = process.env.USER_ID;
const TOKEN = process.env.ACCESS_TOKEN;
const DEVICE_ID = process.env.DEVICE_ID;
const log = (...a) => console.log(...a);
const errs = [];

async function main() {
  let appHeldKey = null; const ssKeys = {};
  const client = sdk.createClient({
    baseUrl: HS, userId: USER_ID, accessToken: TOKEN, deviceId: DEVICE_ID,
    cryptoCallbacks: {
      getSecretStorageKey: async ({ keys }) => {
        const k = Object.keys(keys)[0];
        if (appHeldKey?.privateKey) return [k, appHeldKey.privateKey];
        if (ssKeys[k]) return [k, ssKeys[k]];
        return null;
      },
      cacheSecretStorageKey: (k, _i, pk) => { ssKeys[k] = pk; },
    },
  });
  await client.initRustCrypto({ useIndexedDB: false });
  const crypto = client.getCrypto();
  await client.startClient({ initialSyncLimit: 1 });
  await new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error("first sync timed out")), 30000);
    client.on("sync", (s) => { if (s === "PREPARED" || s === "SYNCING") { clearTimeout(t); res(); } });
  });
  log("crypto initialized; client synced");

  await crypto.bootstrapCrossSigning({ authUploadDeviceSigningKeys: async (mr) => { await mr({}); } });
  log("cross-signing bootstrapped");

  await crypto.bootstrapSecretStorage({
    setupNewSecretStorage: true, setupNewKeyBackup: true,
    createSecretStorageKey: async () => { const key = await crypto.createRecoveryKeyFromPassphrase(); appHeldKey = key; return key; },
  });
  log("secret storage bootstrapped");

  let serverBackup = null;
  try {
    const r = await fetch(`${HS}/_matrix/client/v3/room_keys/version`, { headers: { Authorization: `Bearer ${TOKEN}` } });
    serverBackup = r.ok ? (await r.json()).version : null;
  } catch (e) { errs.push("backup check: " + e.message); }

  const xs = await crypto.getCrossSigningStatus();
  const result = {
    account_created_by: "MAS (no-PII)", user_id: USER_ID,
    crossSigning_publicKeysOnDevice: !!xs?.publicKeysOnDevice,
    crossSigning_privateKeysInSecretStorage: !!xs?.privateKeysInSecretStorage,
    keyBackup_onServer: serverBackup,
    recoveryKey_generatedByApp: !!appHeldKey?.encodedPrivateKey,
    recoveryKey_shownToUser: false,
    errors: errs,
  };
  result.PASS = result.crossSigning_publicKeysOnDevice && result.crossSigning_privateKeysInSecretStorage &&
    !!serverBackup && result.recoveryKey_generatedByApp;
  fs.writeFileSync("result.json", JSON.stringify(result, null, 2));
  log("\n=== RESULT ===\n" + JSON.stringify(result, null, 2));
  try { client.stopClient(); await crypto.stop?.(); } catch {}
  setTimeout(() => process.exit(result.PASS ? 0 : 2), 300);
}
main().catch((e) => {
  const o = { PASS: false, fatal: e?.message || String(e) };
  try { fs.writeFileSync("result.json", JSON.stringify(o, null, 2)); } catch {}
  console.error("ERROR:", o.fatal);
  setTimeout(() => process.exit(1), 300);
});
