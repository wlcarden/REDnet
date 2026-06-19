/*
 * REDnet onboarding/recovery as an Element CryptoSetupExtensions provider.
 *
 * Phase 1 (self-held passphrase): BROWSER E2E PROVEN (2/2 PASS, 2026-06-19).
 * Phase 2 (governance-gated escrow): crypto proven (37/37), lifecycle integration here.
 */
import {
  CryptoSetupExtensionsBase,
  type CryptoSetupArgs,
  type ExtendedMatrixClientCreds,
  type SecretStorageKeyDescription,
} from "@matrix-org/react-sdk-module-api/lib/lifecycles/CryptoSetupExtensions";
import type { MatrixClient } from "matrix-js-sdk";
import { deriveRecoveryKeyFromPassphrase } from "matrix-js-sdk/lib/crypto-api";
import {
  generateRecoveryPassphrase,
  recoverWithPassphrase,
  setActivePassphrase,
  setKeySink,
  silentBootstrap,
} from "./onboarding";
import type { SignedDirectory } from "./directory";
import type { EscrowMode } from "./escrow";
import type { RecoverySession, EscrowHealthStatus } from "./escrow-lifecycle";
import {
  depositEscrow,
  fetchDirectory,
  fetchEscrow,
  requestRecovery,
  collectSharesAndRecover,
  checkEscrowHealth,
} from "./escrow-lifecycle";

export interface Phase2Config {
  recoveryRoomId: string;
  orgPubKey: Uint8Array;
  defaultMode: EscrowMode;
}

export class RednetCryptoSetup extends CryptoSetupExtensionsBase {
  public SHOW_ENCRYPTION_SETUP_UI = false;

  private cachedKey: Uint8Array | null = null;
  private shownPassphrase: string | null = null;
  private phase2Config: Phase2Config | null = null;

  public constructor(
    private readonly getWordlist: () => string[] | undefined = () => undefined,
  ) {
    super();
    setKeySink((k) => {
      this.cachedKey = k;
    });
  }

  public configurePhase2(config: Phase2Config): void {
    this.phase2Config = config;
  }

  // ---- ProvideCryptoSetupExtensions: the SYNCHRONOUS surface Element consults during crypto setup ----

  public getSecretStorageKey(): Uint8Array | null {
    return this.cachedKey;
  }

  public createSecretStorageKey(): Uint8Array | null {
    return this.cachedKey;
  }

  public setupEncryptionNeeded(_args: CryptoSetupArgs): boolean {
    return true;
  }

  public examineLoginResponse(
    _response: unknown,
    _credentials: ExtendedMatrixClientCreds,
  ): void {
    /* no-op: REDnet derives its key from the member passphrase, not the login response */
  }

  public persistCredentials(_credentials: ExtendedMatrixClientCreds): void {
    /* no-op: use Element's default credential persistence */
  }

  public catchAccessSecretStorageError(e: Error): void {
    // eslint-disable-next-line no-console
    console.error("[rednet] secret-storage access error", e);
    try {
      window.alert(
        "Encryption setup error. Your messages may not be recoverable on a new device. " +
          "Contact an organizer for help.\n\n" +
          e.message,
      );
    } catch {
      /* alert blocked (e.g. iframe sandbox) — console.error above is the fallback */
    }
  }

  public getDehydrationKeyCallback():
    | ((
        keyInfo: SecretStorageKeyDescription,
        checkFunc: (key: Uint8Array) => void,
      ) => Promise<Uint8Array>)
    | null {
    return null; // device dehydration not used in Phase 1
  }

  // ---- REDnet async flow — invoked by the login hook (index.ts wiring) BEFORE Element's crypto setup ----

  /** NEW account: generate a recovery passphrase, silently bootstrap 4S + key backup, return it to show ONCE. */
  public async onFreshAccount(client: MatrixClient): Promise<string> {
    const passphrase = generateRecoveryPassphrase(7, this.getWordlist());
    await silentBootstrap(client, passphrase); // sinks cachedKey; THROWS on malicious-core re-provision
    this.shownPassphrase = passphrase;
    return passphrase;
  }

  /** EXISTING account, FRESH device: pre-cache the 4S key from the member's passphrase, then recover. */
  public async onFreshDevice(
    client: MatrixClient,
    passphrase: string,
  ): Promise<{ identityRecovered: boolean; backupEnabled: boolean }> {
    setActivePassphrase(passphrase);
    const defaultKeyId = await client.secretStorage.getDefaultKeyId();
    if (defaultKeyId) {
      const entry = await client.secretStorage.getKey(defaultKeyId);
      const desc = entry?.[1] as
        | { passphrase?: { salt: string; iterations: number } }
        | undefined;
      if (desc?.passphrase) {
        this.cachedKey = await deriveRecoveryKeyFromPassphrase(
          passphrase,
          desc.passphrase.salt,
          desc.passphrase.iterations,
        );
      }
    }
    return recoverWithPassphrase(client, passphrase);
  }

  /**
   * Single entrypoint for the login-hook fork patch (MatrixChat.postLoginSetup). The MODULE owns the crypto;
   * the PATCH owns the UI (it holds Element's Modal) and injects it here. Fresh account → generate + show the
   * passphrase ONCE; returning account on a new device → prompt for it + recover.
   */
  public async rednetOnboard(
    client: MatrixClient,
    isReturningAccount: boolean,
    ui: {
      showOnce: (passphrase: string) => Promise<unknown>;
      prompt: (error?: string) => Promise<string>;
      offerPhase2Recovery?: () => Promise<boolean>;
      showBindingCode?: (code: string) => Promise<void>;
      waitForShares?: (needed: number) => Promise<Uint8Array[]>;
      notifyEscrowDeposited?: () => void;
    },
    autoJoinRooms?: string[],
  ): Promise<void> {
    if (isReturningAccount) {
      const recovered = await this.attemptPassphraseRecovery(client, ui);
      if (recovered) return;

      if (this.phase2Config && ui.offerPhase2Recovery) {
        const wantsPhase2 = await ui.offerPhase2Recovery();
        if (wantsPhase2) {
          await this.phase2Recovery(client, ui);
          return;
        }
      }
    } else {
      const passphrase = await this.onFreshAccount(client);
      await ui.showOnce(passphrase);
      await this.joinStarterRooms(client, autoJoinRooms);

      if (this.phase2Config && this.cachedKey) {
        await this.tryDepositEscrow(client, this.cachedKey, ui);
      }
    }
  }

  private async attemptPassphraseRecovery(
    client: MatrixClient,
    ui: { prompt: (error?: string) => Promise<string> },
  ): Promise<boolean> {
    const MAX_ATTEMPTS = 3;
    let error: string | undefined;
    for (let i = 0; i < MAX_ATTEMPTS; i++) {
      const passphrase = await ui.prompt(error);
      if (!passphrase) return false;
      try {
        await this.onFreshDevice(client, passphrase);
        return true;
      } catch {
        error =
          i < MAX_ATTEMPTS - 1
            ? "Wrong passphrase. Check for typos and try again."
            : "Recovery failed. Contact an organizer if you need help.";
      }
    }
    await ui.prompt(error);
    return false;
  }

  private async phase2Recovery(
    client: MatrixClient,
    ui: {
      showBindingCode?: (code: string) => Promise<void>;
      waitForShares?: (needed: number) => Promise<Uint8Array[]>;
    },
  ): Promise<void> {
    if (!this.phase2Config || !ui.showBindingCode || !ui.waitForShares) return;
    const { recoveryRoomId, orgPubKey } = this.phase2Config;

    const dir = await fetchDirectory(client, recoveryRoomId, orgPubKey);
    if (!dir) throw new Error("No valid moderator directory found");

    const escrow = await fetchEscrow(client);
    if (!escrow) throw new Error("No escrow record found for this account");

    const session = await requestRecovery(client, recoveryRoomId);
    await ui.showBindingCode(session.bindingCode);

    const resealedShares = await ui.waitForShares(escrow.record.policy.m);

    const ctx = {
      member: client.getUserId()!,
      dirVersion: escrow.dirVersion,
    };

    const recoveryKey = await collectSharesAndRecover(
      client,
      session,
      resealedShares,
      escrow.record,
      ctx,
      escrow.record.mode === "passphrase" ? undefined : undefined,
    );

    this.cachedKey = recoveryKey;
    setActivePassphrase(null);
    await recoverWithPassphrase(client, "");
  }

  private async tryDepositEscrow(
    client: MatrixClient,
    recoveryKey: Uint8Array,
    ui: { notifyEscrowDeposited?: () => void },
  ): Promise<void> {
    if (!this.phase2Config) return;
    const { recoveryRoomId, orgPubKey, defaultMode } = this.phase2Config;

    try {
      const dir = await fetchDirectory(client, recoveryRoomId, orgPubKey);
      if (!dir) return;
      await depositEscrow(client, recoveryKey, dir, defaultMode);
      ui.notifyEscrowDeposited?.();
    } catch (e) {
      // eslint-disable-next-line no-console
      console.warn("[rednet] escrow deposit failed (non-fatal):", e);
    }
  }

  public async getEscrowHealth(
    client: MatrixClient,
  ): Promise<EscrowHealthStatus> {
    if (!this.phase2Config) return { status: "phase1_only" };
    return checkEscrowHealth(
      client,
      this.phase2Config.recoveryRoomId,
      this.phase2Config.orgPubKey,
    );
  }

  /** Default starter rooms (localparts) — the set bootstrap-rooms.sh creates. Override via rednetOnboard's arg. */
  private static readonly DEFAULT_STARTER_ROOMS = [
    "community",
    "welcome",
    "announcements",
    "reference",
    "general",
  ];

  private async joinStarterRooms(
    client: MatrixClient,
    configured?: string[],
  ): Promise<void> {
    const domain = client.getDomain();
    const rooms = configured?.length
      ? configured
      : RednetCryptoSetup.DEFAULT_STARTER_ROOMS;
    for (const r of rooms) {
      const alias = r.startsWith("#") ? r : `#${r}:${domain}`;
      try {
        await client.joinRoom(alias);
      } catch {
        /* already a member, or the room doesn't exist on this deploy — ignore */
      }
    }
  }

  /** The passphrase generated for a fresh account, so the caller can surface it ONCE then drop it. */
  public takeShownPassphrase(): string | null {
    const p = this.shownPassphrase;
    this.shownPassphrase = null;
    return p;
  }
}
