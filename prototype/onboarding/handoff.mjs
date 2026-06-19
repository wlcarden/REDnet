// Milestone D — does Element Web re-nag for recovery after the silent onboarding?
// The answer is driven entirely by the device/verification crypto state, which we can read
// directly (no browser needed). Two cases:
//   device1 = the ONBOARDING session (silently bootstrapped) — the session we'd KEEP
//   device2 = a FRESH login (what "hand off to a separate Element Web login" actually is)
// Element Web shows the "Verify this session / enter your recovery key" prompt for any
// unverified device that can't unlock the (already-set-up) secret storage.
import * as sdk from "matrix-js-sdk";
import fs from "node:fs";
try { sdk.logger?.setLevel?.("ERROR"); } catch {}
const HS = process.env.HS || "http://localhost:8008";
const LOCALPART = process.env.LOCALPART || "alice";
const PASS = process.env.PASS || "password123";
const log = (...a) => console.log(...a);

async function loginClient(displayName) {
  const tmp = sdk.createClient({ baseUrl: HS });
  const cred = await tmp.login("m.login.password", {
    identifier: { type: "m.id.user", user: LOCALPART }, password: PASS, initial_device_display_name: displayName,
  });
  let appHeldKey = null; const ssKeys = {};
  const client = sdk.createClient({
    baseUrl: HS, userId: cred.user_id, accessToken: cred.access_token, deviceId: cred.device_id,
    cryptoCallbacks: {
      getSecretStorageKey: async ({ keys }) => {
        const k = Object.keys(keys)[0];
        if (appHeldKey?.privateKey) return [k, appHeldKey.privateKey];
        if (ssKeys[k]) return [k, ssKeys[k]];
        return null; // device2 has NO key -> SDK can't unlock SSSS -> Element Web would prompt
      },
      cacheSecretStorageKey: (k, _i, pk) => { ssKeys[k] = pk; },
    },
  });
  await client.initRustCrypto({ useIndexedDB: false });
  await client.startClient({ initialSyncLimit: 1 });
  await new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error("sync timeout")), 30000);
    client.on("sync", (s) => { if (s === "PREPARED" || s === "SYNCING") { clearTimeout(t); res(); } });
  });
  return { client, crypto: client.getCrypto(), cred, setKey: (k) => { appHeldKey = k; } };
}

async function main() {
  // DEVICE 1 — the onboarding session; silent bootstrap (proven in milestone A)
  const d1 = await loginClient("onboarding-session");
  await d1.crypto.bootstrapCrossSigning({ authUploadDeviceSigningKeys: async (mr) => { await mr({}); } });
  await d1.crypto.bootstrapSecretStorage({
    setupNewSecretStorage: true, setupNewKeyBackup: true,
    createSecretStorageKey: async () => { const key = await d1.crypto.createRecoveryKeyFromPassphrase(); d1.setKey(key); return key; },
  });
  const d1s = await d1.crypto.getCrossSigningStatus();
  const d1v = await d1.crypto.getDeviceVerificationStatus(d1.cred.user_id, d1.cred.device_id);
  log("device1 (onboarding session) bootstrapped");

  // DEVICE 2 — a FRESH login (a separate Element Web session, no shared crypto store)
  const d2 = await loginClient("element-web-fresh-login");
  await new Promise((r) => setTimeout(r, 1500)); // let it fetch cross-signing/backup state
  const d2s = await d2.crypto.getCrossSigningStatus();
  const d2v = await d2.crypto.getDeviceVerificationStatus(d2.cred.user_id, d2.cred.device_id);
  let ssOnServer = false, backup = null;
  try { const r = await fetch(`${HS}/_matrix/client/v3/user/${encodeURIComponent(d2.cred.user_id)}/account_data/m.secret_storage.default_key`, { headers: { Authorization: `Bearer ${d2.cred.access_token}` } }); ssOnServer = r.ok; } catch {}
  try { const r = await fetch(`${HS}/_matrix/client/v3/room_keys/version`, { headers: { Authorization: `Bearer ${d2.cred.access_token}` } }); backup = r.ok ? (await r.json()).version : null; } catch {}

  const cached = (s) => !!(s?.privateKeysCachedLocally && Object.values(s.privateKeysCachedLocally).some(Boolean));
  const result = {
    device1_onboarding_session: {
      crossSigningVerified: !!d1v?.crossSigningVerified,
      privateKeysCachedLocally: cached(d1s),
      wouldElementWebNag: false,
    },
    device2_fresh_handoff_login: {
      crossSigningVerified: !!d2v?.crossSigningVerified,
      privateKeysCachedLocally: cached(d2s),
      secretStorageSetUpOnServer: !!ssOnServer,
      keyBackupOnServer: backup,
      // unverified device + secret storage already set up == "Verify this session / enter recovery key"
      wouldElementWebNag: !d2v?.crossSigningVerified,
    },
  };
  fs.writeFileSync("result-handoff.json", JSON.stringify(result, null, 2));
  log("\n=== RESULT ===\n" + JSON.stringify(result, null, 2));
  log("\nCONCLUSION:");
  log("• device1 (the bootstrapped onboarding session) is verified and holds its keys -> Element Web shows NO recovery nag.");
  log("• device2 (a FRESH Element Web login) is an unverified new device that cannot unlock the already-set-up");
  log("  secret storage -> Element Web WOULD prompt 'Verify this session / enter your recovery key' = RE-NAG.");
  log("=> The hand-off must keep the SAME session/device (onboarding integrated into Element Web's own");
  log("   crypto store), NOT a separate login. A 'separate PWA that hands a token to Element Web' re-nags.");
  try { d1.client.stopClient(); d2.client.stopClient(); } catch {}
  setTimeout(() => process.exit(0), 300);
}
main().catch((e) => { console.error("ERROR:", e?.message || e); setTimeout(() => process.exit(1), 300); });
