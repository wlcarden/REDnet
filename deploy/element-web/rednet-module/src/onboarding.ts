/*
 * REDnet onboarding + recovery — Phase 1 (self-held passphrase). Crypto logic VERIFIED end-to-end in
 * prototype/onboarding/phase1-recovery.mjs (a fresh device recovers the SAME cross-signing identity AND
 * message history from the passphrase alone). This is native Matrix 4S keyed by a passphrase; the module
 * drives it silently.
 *
 * The canonical implementation. The CryptoSetupExtensions bridge adds a KEY SINK: Element's
 * getSecretStorageKey()/createSecretStorageKey() are
 * SYNCHRONOUS, so the freshly-generated/derived 4S key must be cached the moment it exists; silentBootstrap
 * pushes it to the registered sink (avoids the callback-before-resolve race the spike caught).
 */
import type { MatrixClient } from "matrix-js-sdk";
import { deriveRecoveryKeyFromPassphrase } from "matrix-js-sdk/lib/crypto-api";

let activePassphrase: string | null = null;
export function setActivePassphrase(p: string | null): void {
  activePassphrase = p;
}

// The CryptoSetup extension registers a sink so it can return the key synchronously to Element.
let keySink: ((key: Uint8Array) => void) | null = null;
export function setKeySink(cb: ((key: Uint8Array) => void) | null): void {
  keySink = cb;
}

/** Derive the 4S key from the active passphrase + the key's PBKDF2 params. Null => fall back to Element. */
export async function getRednetSecretStorageKey({
  keys,
}: {
  keys: Record<string, { passphrase?: { salt: string; iterations: number } }>;
}): Promise<[string, Uint8Array] | null> {
  const keyId = Object.keys(keys)[0];
  const info = keys[keyId];
  if (activePassphrase && info?.passphrase) {
    const { salt, iterations } = info.passphrase;
    const key = await deriveRecoveryKeyFromPassphrase(
      activePassphrase,
      salt,
      iterations,
    );
    keySink?.(key);
    return [keyId, key];
  }
  return null;
}

function onboardMarkerKey(userId: string): string {
  return `rednet.onboarded.${userId}`;
}

/**
 * ONBOARDING (new account): silently provision E2EE with secret storage + key backup keyed by `passphrase`.
 * The ONLY thing the member must see is the passphrase, surfaced ONCE by the caller.
 */
export async function silentBootstrap(
  client: MatrixClient,
  passphrase: string,
): Promise<void> {
  const crypto = client.getCrypto();
  if (!crypto) throw new Error("rednet onboarding: crypto not initialized");
  const userId = client.getUserId() ?? "";

  // DEFENSE (security review): a MALICIOUS CORE can withhold a returning member's cross-signing keys to
  // drive the new-account branch and SILENTLY DESTROY their identity + key backup. Refuse to overwrite if
  // there is ANY sign this isn't a truly fresh account: (a) secret storage exists server-side, or (b) this
  // device onboarded this account before (a local marker the core cannot forge).
  const existingKeyId = await client.secretStorage
    .getDefaultKeyId()
    .catch(() => null);
  const localMarker =
    typeof localStorage !== "undefined" &&
    !!localStorage.getItem(onboardMarkerKey(userId));
  if (existingKeyId || localMarker) {
    throw new Error(
      `rednet onboarding: account already has recovery set up (serverKey=${!!existingKeyId}, local=${localMarker}). ` +
        "Refusing to re-provision and overwrite the existing identity/key-backup — possible server tampering or a " +
        "returning account. Recover with the passphrase, or require explicit user confirmation of a reset.",
    );
  }

  setActivePassphrase(passphrase);

  await crypto.bootstrapCrossSigning({
    authUploadDeviceSigningKeys: async (makeRequest) => {
      await makeRequest({}); // MSC3967: first device-signing upload needs no interactive auth
    },
  });

  const status = await crypto.getCrossSigningStatus();
  const alreadyProvisioned =
    !!status?.privateKeysInSecretStorage && !!status?.publicKeysOnDevice;
  if (!alreadyProvisioned) {
    // Pre-generate the key so the SYNC getSecretStorageKey can return it during bootstrap.
    const key = await crypto.createRecoveryKeyFromPassphrase(passphrase);
    if (key.privateKey) keySink?.(key.privateKey);
    await crypto.bootstrapSecretStorage({
      setupNewSecretStorage: true,
      setupNewKeyBackup: true,
      createSecretStorageKey: async () => key,
    });
    await crypto.checkKeyBackupAndEnable();
  }
  if (typeof localStorage !== "undefined")
    localStorage.setItem(onboardMarkerKey(userId), "1");
}

/**
 * RECOVERY (existing account, FRESH device): recover the cross-signing identity AND message history from
 * the passphrase alone. The caller pre-caches the derived key (sync bridge) before invoking this.
 */
export async function recoverWithPassphrase(
  client: MatrixClient,
  passphrase: string,
): Promise<{ identityRecovered: boolean; backupEnabled: boolean }> {
  const crypto = client.getCrypto();
  if (!crypto) throw new Error("rednet recovery: crypto not initialized");
  setActivePassphrase(passphrase);

  await crypto.bootstrapCrossSigning({
    authUploadDeviceSigningKeys: async (makeRequest) => {
      await makeRequest({});
    },
  });

  // matrix-js-sdk 34.12.0: checkKeyBackupAndEnable() enables the backup from secret storage — reached via our
  // passphrase-derived 4S key — and the rust crypto restores room keys ON DEMAND as messages are decrypted.
  // Proven by browser E2E (fresh-device recovery, 2026-06-19).
  let backupEnabled = false;
  try {
    const check = await crypto.checkKeyBackupAndEnable();
    backupEnabled = !!check;
  } catch {
    /* backup unavailable — the cross-signing identity is still recovered below */
  }

  const status = await crypto.getCrossSigningStatus();
  return {
    identityRecovered: !!status?.privateKeysCachedLocally,
    backupEnabled,
  };
}

/**
 * Generate a strong recovery passphrase. EFF-large diceware (>=7776 words, 7 words ~= 90 bits) or a
 * ~104-bit alphanumeric fallback. MUST be diceware-grade: no trusted hardware rate-limits guesses against
 * a seized server (RECOVERY.md §8). Prefer generating over letting the member choose.
 */
export function generateRecoveryPassphrase(
  words = 7,
  wordlist?: string[],
): string {
  const g = globalThis.crypto;
  const pick = (n: number): number => {
    const limit = Math.floor(0xffffffff / n) * n;
    const a = new Uint32Array(1);
    do {
      g.getRandomValues(a);
    } while (a[0] >= limit);
    return a[0] % n;
  };
  if (wordlist && wordlist.length >= 7776) {
    const w = Math.max(words, 7);
    return Array.from(
      { length: w },
      () => wordlist[pick(wordlist.length)],
    ).join("-");
  }
  const alpha = "abcdefghjkmnpqrstuvwxyz23456789"; // no ambiguous chars
  return Array.from({ length: 21 }, () => alpha[pick(alpha.length)]).join("");
}
