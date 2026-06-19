import { ed25519 } from "@noble/curves/ed25519";

export interface ModeratorEntry {
  keyId: string;
  pubRaw65: Uint8Array;
}

export interface DirectoryPayload {
  version: number;
  moderators: ModeratorEntry[];
  policy: { m: number; n: number };
  created: number;
}

export interface SignedDirectory {
  payload: DirectoryPayload;
  signature: Uint8Array;
}

function canonicalPayload(payload: DirectoryPayload): Uint8Array {
  const obj = {
    created: payload.created,
    moderators: payload.moderators
      .map((m) => ({
        keyId: m.keyId,
        pub: Array.from(m.pubRaw65),
      }))
      .sort((a, b) => a.keyId.localeCompare(b.keyId)),
    policy: { m: payload.policy.m, n: payload.policy.n },
    version: payload.version,
  };
  return new TextEncoder().encode(JSON.stringify(obj));
}

export function signDirectory(
  payload: DirectoryPayload,
  orgPrivKey: Uint8Array,
): SignedDirectory {
  const msg = canonicalPayload(payload);
  const signature = ed25519.sign(msg, orgPrivKey);
  return { payload, signature };
}

export function verifyDirectory(
  dir: SignedDirectory,
  orgPubKey: Uint8Array,
): boolean {
  const msg = canonicalPayload(dir.payload);
  return ed25519.verify(dir.signature, msg, orgPubKey);
}

export function directoryFingerprint(pubRaw65: Uint8Array): string {
  const hex = Array.from(pubRaw65.subarray(1, 9), (b) =>
    b.toString(16).padStart(2, "0"),
  ).join("");
  return hex;
}

export function findModeratorKey(
  dir: SignedDirectory,
  keyId: string,
): Uint8Array | null {
  const entry = dir.payload.moderators.find((m) => m.keyId === keyId);
  return entry?.pubRaw65 ?? null;
}
