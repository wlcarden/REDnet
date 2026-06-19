/**
 * Phase-2 recovery escrow — the composed construction from spikes 05-08.
 *
 * MK (random 32B) → Shamir M-of-N → each share ECIES-sealed to a moderator pubkey.
 * Blob = AES-256-GCM(wrapKey, recoveryKey).
 *
 * moderators_only: wrapKey = MK
 * passphrase:      wrapKey = HKDF(scrypt(passphrase, salt) || MK, "rednet-escrow-wrap")
 */
import { scrypt } from "@noble/hashes/scrypt.js";
import { shamirSplit, shamirCombine } from "./shamir.ts";
import {
  eciesSeal,
  eciesUnseal,
  hkdfSha256,
  aesGcmEncrypt,
  aesGcmDecrypt,
  canonicalAad,
} from "./ecies.ts";

const WRAP_INFO = new TextEncoder().encode("rednet-escrow-wrap");
const SCRYPT_N = 16384;
const SCRYPT_R = 8;
const SCRYPT_P = 1;
const SCRYPT_DK_LEN = 32;

export type EscrowMode = "moderators_only" | "passphrase";

export interface EscrowPolicy {
  m: number;
  n: number;
  v: number;
}

export interface EscrowRecord {
  mode: EscrowMode;
  blob: Uint8Array;
  salt: Uint8Array;
  sealedShares: Uint8Array[];
  policy: EscrowPolicy;
}

export interface EscrowContext {
  member: string;
  dirVersion: number;
}

function blobAad(ctx: EscrowContext, mode: EscrowMode): Uint8Array {
  return canonicalAad({
    dir_version: ctx.dirVersion,
    member: ctx.member,
    mode,
  });
}

function shareAad(
  ctx: EscrowContext,
  mode: EscrowMode,
  m: number,
  n: number,
): Uint8Array {
  return canonicalAad({
    dir_version: ctx.dirVersion,
    m,
    member: ctx.member,
    mode,
    n,
  });
}

async function deriveWrapKey(
  mk: Uint8Array,
  mode: EscrowMode,
  passphrase: string | undefined,
  salt: Uint8Array,
): Promise<Uint8Array> {
  if (mode === "moderators_only") return mk;
  if (!passphrase) throw new Error("passphrase required for passphrase mode");
  const stretched = scrypt(new TextEncoder().encode(passphrase), salt, {
    N: SCRYPT_N,
    r: SCRYPT_R,
    p: SCRYPT_P,
    dkLen: SCRYPT_DK_LEN,
  });
  const ikm = new Uint8Array(SCRYPT_DK_LEN + mk.length);
  ikm.set(stretched, 0);
  ikm.set(mk, SCRYPT_DK_LEN);
  return new Uint8Array(
    await hkdfSha256(ikm.buffer as ArrayBuffer, WRAP_INFO, 32),
  );
}

export async function createEscrow(
  recoveryKey: Uint8Array,
  modPubKeys: Uint8Array[],
  threshold: number,
  mode: EscrowMode,
  ctx: EscrowContext,
  passphrase?: string,
): Promise<EscrowRecord> {
  const n = modPubKeys.length;
  const mk = crypto.getRandomValues(new Uint8Array(32));
  const salt =
    mode === "passphrase"
      ? crypto.getRandomValues(new Uint8Array(16))
      : new Uint8Array(0);

  const wrapKey = await deriveWrapKey(mk, mode, passphrase, salt);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(
    await aesGcmEncrypt(
      wrapKey.buffer as ArrayBuffer,
      nonce,
      recoveryKey,
      blobAad(ctx, mode),
    ),
  );
  const blob = new Uint8Array(12 + ct.length);
  blob.set(nonce, 0);
  blob.set(ct, 12);

  const shares = await shamirSplit(mk, n, threshold);
  const aad = shareAad(ctx, mode, threshold, n);
  const sealedShares = await Promise.all(
    shares.map((share, i) => eciesSeal(modPubKeys[i], share, aad)),
  );

  return { mode, blob, salt, sealedShares, policy: { m: threshold, n, v: 1 } };
}

export async function unsealShare(
  modPrivKey: CryptoKey,
  sealedShare: Uint8Array,
  record: EscrowRecord,
  ctx: EscrowContext,
): Promise<Uint8Array> {
  const aad = shareAad(ctx, record.mode, record.policy.m, record.policy.n);
  return eciesUnseal(modPrivKey, sealedShare, aad);
}

export async function recoverEscrow(
  record: EscrowRecord,
  unsealedShares: Uint8Array[],
  ctx: EscrowContext,
  passphrase?: string,
): Promise<Uint8Array> {
  const mk = await shamirCombine(unsealedShares);
  const wrapKey = await deriveWrapKey(mk, record.mode, passphrase, record.salt);
  const nonce = record.blob.subarray(0, 12);
  const ct = record.blob.subarray(12);
  return new Uint8Array(
    await aesGcmDecrypt(
      wrapKey.buffer as ArrayBuffer,
      nonce,
      ct,
      blobAad(ctx, record.mode),
    ),
  );
}

export async function reshareEscrow(
  record: EscrowRecord,
  unsealedShares: Uint8Array[],
  newModPubKeys: Uint8Array[],
  newThreshold: number,
  ctx: EscrowContext,
): Promise<EscrowRecord> {
  const mk = await shamirCombine(unsealedShares);
  const newN = newModPubKeys.length;
  const newShares = await shamirSplit(mk, newN, newThreshold);
  const aad = shareAad(ctx, record.mode, newThreshold, newN);
  const sealedShares = await Promise.all(
    newShares.map((share, i) => eciesSeal(newModPubKeys[i], share, aad)),
  );

  return {
    mode: record.mode,
    blob: record.blob,
    salt: record.salt,
    sealedShares,
    policy: { m: newThreshold, n: newN, v: record.policy.v + 1 },
  };
}
