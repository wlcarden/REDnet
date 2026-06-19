export const EVENT_DIRECTORY = "org.rednet.recovery.directory";
export const EVENT_ESCROW = "org.rednet.recovery.escrow";
export const EVENT_REQUEST = "org.rednet.recovery.request";
export const EVENT_SHARE = "org.rednet.recovery.share";

export interface DirectoryStateContent {
  version: number;
  moderators: Array<{
    keyId: string;
    pub: number[];
  }>;
  policy: { m: number; n: number };
  created: number;
  signature: number[];
}

export interface EscrowAccountData {
  mode: "moderators_only" | "passphrase";
  blob: number[];
  salt: number[];
  sealedShares: number[][];
  policy: { m: number; n: number; v: number };
  dirVersion: number;
}

export interface RecoveryRequestContent {
  memberUserId: string;
  ephemeralPub: number[];
  bindingCode: string;
  timestamp: number;
}

export interface ShareDeliveryContent {
  requestEventId: string;
  moderatorKeyId: string;
  resealedShare: number[];
}

export function serializeDirectory(
  dir: import("./directory").SignedDirectory,
): DirectoryStateContent {
  return {
    version: dir.payload.version,
    moderators: dir.payload.moderators.map((m) => ({
      keyId: m.keyId,
      pub: Array.from(m.pubRaw65),
    })),
    policy: dir.payload.policy,
    created: dir.payload.created,
    signature: Array.from(dir.signature),
  };
}

export function deserializeDirectory(
  content: DirectoryStateContent,
): import("./directory").SignedDirectory {
  return {
    payload: {
      version: content.version,
      moderators: content.moderators.map((m) => ({
        keyId: m.keyId,
        pubRaw65: new Uint8Array(m.pub),
      })),
      policy: content.policy,
      created: content.created,
    },
    signature: new Uint8Array(content.signature),
  };
}

export function serializeEscrow(
  record: import("./escrow").EscrowRecord,
  dirVersion: number,
): EscrowAccountData {
  return {
    mode: record.mode,
    blob: Array.from(record.blob),
    salt: Array.from(record.salt),
    sealedShares: record.sealedShares.map((s) => Array.from(s)),
    policy: record.policy,
    dirVersion,
  };
}

export function deserializeEscrow(
  data: EscrowAccountData,
): import("./escrow").EscrowRecord {
  return {
    mode: data.mode,
    blob: new Uint8Array(data.blob),
    salt: new Uint8Array(data.salt),
    sealedShares: data.sealedShares.map((s) => new Uint8Array(s)),
    policy: data.policy,
  };
}
