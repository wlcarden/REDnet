/*
 * REDnet onboarding module entrypoint. Element's module_system loads the default export as a RuntimeModule
 * and reads `this.extensions` to discover the cryptoSetup provider (see element-web docs/modules.md +
 * src/modules/ModuleRunner.ts). This registration REPLACES the old integration.patch soft fork.
 *
 * The cryptoSetup extension's getters are SYNCHRONOUS; the silent bootstrap/recovery is async. The keySink
 * pattern ensures the async prep (onFreshAccount/onFreshDevice) populates cachedKey before Element's sync
 * getters fire. PROVEN by browser E2E (e2e/onboarding.spec.ts, 2/2 PASS — see REVIEW.md).
 */
import { RuntimeModule } from "@matrix-org/react-sdk-module-api/lib/RuntimeModule";
import type { ModuleApi } from "@matrix-org/react-sdk-module-api/lib/ModuleApi";
import { RednetCryptoSetup } from "./RednetCryptoSetup";
import { EFF_LARGE_WORDLIST } from "./eff-wordlist";

export default class RednetOnboardingModule extends RuntimeModule {
  public constructor(moduleApi: ModuleApi) {
    super(moduleApi);
    this.extensions = {
      cryptoSetup: new RednetCryptoSetup(() => EFF_LARGE_WORDLIST),
    };
  }
}
