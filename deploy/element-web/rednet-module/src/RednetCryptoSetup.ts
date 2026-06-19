/*
 * REDnet Phase-1 onboarding/recovery as an Element CryptoSetupExtensions provider.
 *
 * VALIDATION STATUS (see REVIEW.md):
 *   TYPECHECKS against @matrix-org/react-sdk-module-api@2.4.0 + matrix-js-sdk@34.12.0.
 *   BROWSER E2E PROVEN (2026-06-19): the async/sync choreography works — cachedKey is populated before
 *     Element's sync getters fire, UI suppression works, and the passphrase round-trips (fresh account →
 *     fresh device recovery). See e2e/onboarding.spec.ts (2/2 PASS).
 *   REMAINING: external crypto review of the bootstrap/recovery path (edge cases, malicious-core guard,
 *     backup trust model).
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

export class RednetCryptoSetup extends CryptoSetupExtensionsBase {
  /** Suppress Element's interactive encryption-setup UI — REDnet drives setup silently. */
  public SHOW_ENCRYPTION_SETUP_UI = false;

  /**
   * Pre-derived 4S key for this session. Element consults the sync getters below DURING crypto setup; the
   * async prep (onFreshAccount/onFreshDevice) derives the key and the keySink populates this first.
   */
  private cachedKey: Uint8Array | null = null;
  private shownPassphrase: string | null = null;

  public constructor(
    private readonly getWordlist: () => string[] | undefined = () => undefined,
  ) {
    super();
    setKeySink((k) => {
      this.cachedKey = k;
    });
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
    },
    autoJoinRooms?: string[],
  ): Promise<void> {
    if (isReturningAccount) {
      const MAX_ATTEMPTS = 3;
      let error: string | undefined;
      for (let i = 0; i < MAX_ATTEMPTS; i++) {
        const passphrase = await ui.prompt(error);
        if (!passphrase) return;
        try {
          await this.onFreshDevice(client, passphrase);
          return;
        } catch {
          error =
            i < MAX_ATTEMPTS - 1
              ? "Wrong passphrase. Check for typos and try again."
              : "Recovery failed. Contact an organizer if you need help.";
        }
      }
      await ui.prompt(error);
    } else {
      const passphrase = await this.onFreshAccount(client);
      await ui.showOnce(passphrase);
      // NEW account: join the community space + starter channels from the CLIENT. Synapse `auto_join_rooms`
      // does NOT fire for MAS-provisioned users (confirmed empirically), so the client does it — robust across
      // every registration path. Returning accounts are already members, so this runs only for fresh accounts.
      await this.joinStarterRooms(client, autoJoinRooms);
    }
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
