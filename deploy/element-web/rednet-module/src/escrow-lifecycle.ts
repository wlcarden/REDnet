import type { MatrixClient } from "matrix-js-sdk";
import { createEscrow, recoverEscrow, reshareEscrow } from "./escrow.ts";
import type { EscrowMode, EscrowContext, EscrowRecord } from "./escrow.ts";
import { eciesSeal, eciesUnseal } from "./ecies.ts";
import { verifyDirectory } from "./directory.ts";
import type { SignedDirectory } from "./directory.ts";
import {
  EVENT_DIRECTORY,
  EVENT_ESCROW,
  EVENT_REQUEST,
  EVENT_SHARE,
  serializeEscrow,
  deserializeEscrow,
  deserializeDirectory,
  type EscrowAccountData,
  type DirectoryStateContent,
  type RecoveryRequestContent,
  type ShareDeliveryContent,
} from "./events.ts";

const CURVE: EcKeyGenParams = { name: "ECDH", namedCurve: "P-256" };

export type EscrowHealthStatus =
  | { status: "healthy" }
  | { status: "no_escrow" }
  | { status: "no_directory" }
  | { status: "directory_invalid" }
  | { status: "stale"; reason: string }
  | { status: "phase1_only" };

export interface RecoverySession {
  requestEventId: string;
  ephemeralKeyPair: CryptoKeyPair;
  ephemeralPubRaw: Uint8Array;
  bindingCode: string;
}

function generateBindingCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(3));
  const num = ((bytes[0] << 16) | (bytes[1] << 8) | bytes[2]) % 1000000;
  return num.toString().padStart(6, "0");
}

export async function fetchDirectory(
  client: MatrixClient,
  recoveryRoomId: string,
  orgPubKey: Uint8Array,
): Promise<SignedDirectory | null> {
  let stateEvent: { getContent(): DirectoryStateContent } | null;
  try {
    stateEvent = client
      .getRoom(recoveryRoomId)
      ?.currentState.getStateEvents(EVENT_DIRECTORY, "") as typeof stateEvent;
  } catch {
    return null;
  }
  if (!stateEvent) return null;

  const content = stateEvent.getContent();
  if (!content?.version) return null;

  const dir = deserializeDirectory(content);
  if (!verifyDirectory(dir, orgPubKey)) return null;
  return dir;
}

export async function fetchEscrow(
  client: MatrixClient,
): Promise<{ record: EscrowRecord; dirVersion: number } | null> {
  let data: EscrowAccountData | undefined;
  try {
    data = (await client.getAccountDataFromServer(EVENT_ESCROW)) as
      | EscrowAccountData
      | undefined;
  } catch {
    return null;
  }
  if (!data?.blob?.length) return null;
  return { record: deserializeEscrow(data), dirVersion: data.dirVersion };
}

export async function depositEscrow(
  client: MatrixClient,
  recoveryKey: Uint8Array,
  directory: SignedDirectory,
  mode: EscrowMode,
  passphrase?: string,
): Promise<void> {
  const userId = client.getUserId();
  if (!userId) throw new Error("not logged in");

  const ctx: EscrowContext = {
    member: userId,
    dirVersion: directory.payload.version,
  };

  const modPubKeys = directory.payload.moderators.map((m) => m.pubRaw65);
  const threshold = directory.payload.policy.m;

  const record = await createEscrow(
    recoveryKey,
    modPubKeys,
    threshold,
    mode,
    ctx,
    passphrase,
  );

  const serialized = serializeEscrow(record, directory.payload.version);
  await client.setAccountData(
    EVENT_ESCROW,
    serialized as unknown as Record<string, unknown>,
  );
}

export async function requestRecovery(
  client: MatrixClient,
  recoveryRoomId: string,
): Promise<RecoverySession> {
  const userId = client.getUserId();
  if (!userId) throw new Error("not logged in");

  const ephemeralKeyPair = await crypto.subtle.generateKey(CURVE, true, [
    "deriveBits",
  ]);
  const ephemeralPubRaw = new Uint8Array(
    await crypto.subtle.exportKey("raw", ephemeralKeyPair.publicKey),
  );
  const bindingCode = generateBindingCode();

  const content: RecoveryRequestContent = {
    memberUserId: userId,
    ephemeralPub: Array.from(ephemeralPubRaw),
    bindingCode,
    timestamp: Date.now(),
  };

  const result = await client.sendEvent(
    recoveryRoomId,
    EVENT_REQUEST as any,
    content as any,
  );

  return {
    requestEventId: result.event_id,
    ephemeralKeyPair,
    ephemeralPubRaw,
    bindingCode,
  };
}

export async function collectSharesAndRecover(
  client: MatrixClient,
  session: RecoverySession,
  resealedShares: Uint8Array[],
  escrowRecord: EscrowRecord,
  ctx: EscrowContext,
  passphrase?: string,
): Promise<Uint8Array> {
  const unsealedShares = await Promise.all(
    resealedShares.map((sealed) =>
      eciesUnseal(session.ephemeralKeyPair.privateKey, sealed),
    ),
  );

  return recoverEscrow(escrowRecord, unsealedShares, ctx, passphrase);
}

export async function resealShareForDevice(
  modPrivKey: CryptoKey,
  sealedShare: Uint8Array,
  escrowRecord: EscrowRecord,
  ctx: EscrowContext,
  deviceEphemeralPub: Uint8Array,
): Promise<Uint8Array> {
  const aad = await import("./ecies.ts").then((m) =>
    m.canonicalAad({
      dir_version: ctx.dirVersion,
      m: escrowRecord.policy.m,
      member: ctx.member,
      mode: escrowRecord.mode,
      n: escrowRecord.policy.n,
    }),
  );
  const plainShare = await eciesUnseal(modPrivKey, sealedShare, aad);
  return eciesSeal(deviceEphemeralPub, plainShare);
}

export async function deliverShare(
  client: MatrixClient,
  recoveryRoomId: string,
  requestEventId: string,
  moderatorKeyId: string,
  resealedShare: Uint8Array,
): Promise<void> {
  const content: ShareDeliveryContent = {
    requestEventId,
    moderatorKeyId,
    resealedShare: Array.from(resealedShare),
  };
  await client.sendEvent(recoveryRoomId, EVENT_SHARE as any, content as any);
}

export async function checkEscrowHealth(
  client: MatrixClient,
  recoveryRoomId: string | null,
  orgPubKey: Uint8Array,
): Promise<EscrowHealthStatus> {
  const escrow = await fetchEscrow(client);
  if (!escrow) return { status: "no_escrow" };

  if (!recoveryRoomId) return { status: "phase1_only" };

  const dir = await fetchDirectory(client, recoveryRoomId, orgPubKey);
  if (!dir) return { status: "no_directory" };

  if (escrow.dirVersion < dir.payload.version) {
    return {
      status: "stale",
      reason:
        "Moderator directory updated since escrow was created. Re-escrow recommended.",
    };
  }

  const escrowModCount = escrow.record.sealedShares.length;
  const dirModCount = dir.payload.moderators.length;
  if (escrowModCount !== dirModCount) {
    return {
      status: "stale",
      reason: "Moderator set changed. Re-escrow required.",
    };
  }

  return { status: "healthy" };
}

export async function reEscrow(
  client: MatrixClient,
  recoveryKey: Uint8Array,
  directory: SignedDirectory,
  mode: EscrowMode,
  passphrase?: string,
): Promise<void> {
  await depositEscrow(client, recoveryKey, directory, mode, passphrase);
}
