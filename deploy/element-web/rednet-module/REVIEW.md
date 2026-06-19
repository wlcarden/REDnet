# REDnet onboarding module — validation status (READ BEFORE RELYING ON THIS)

This module implements REDnet's Phase-1 silent onboarding/recovery as an Element **CryptoSetupExtensions**
provider (the supported `ModuleRunner.instance.extensions.cryptoSetup` integration). The module handles all
crypto; `integration.patch` (51 lines, applies clean to v1.11.86) wires it into `MatrixChat.postLoginSetup`
and provides the `RednetRecoveryKeyDialog` modal UI.

## What IS validated (in-house, no external review)

- **Typechecks (0 errors)** against the real APIs `@matrix-org/react-sdk-module-api@2.4.0` +
  `matrix-js-sdk@34.12.0` (`npm i && npx tsc --noEmit` in this dir). The class correctly implements the
  v2.4.0 `ProvideCryptoSetupExtensions` contract.
- **The typecheck caught a real drift bug**: the recovery path called `restoreKeyBackup()` +
  `loadSessionBackupPrivateKeyFromSecretStorage()`, which **do not exist** on `CryptoApi` at v34.12.0 (the
  prototype was verified against an older SDK shape). Fixed to the v34.12.0 flow — `checkKeyBackupAndEnable()`
  enables the backup from secret storage and the rust crypto restores keys on demand.
- **Reuses verified crypto where unchanged**: `silentBootstrap` (incl. the malicious-core re-provision
  guard) + the diceware generator are the prototype-verified logic; `SHOW_ENCRYPTION_SETUP_UI = false` is the
  documented switch to suppress Element's setup nags.

## What is now WIRED + build-validated (was the gap; now done)

- **The fork patch applies clean to pristine v1.11.86** (`../integration.patch`, 51 lines — the
  `MatrixChat.postLoginSetup` hook), verified by `git apply --check`. NOT a template: a real diff of the
  actual source.
- **The build integrates everything and the sentinel flips ON.** The Dockerfile installs the module
  (`build_config.yaml` → `build:module_system`; emitted via esbuild → `lib/index.js`), applies the patch,
  copies `RednetRecoveryKeyDialog.tsx`, and webpack-bundles it. The build prints "onboarding patch APPLIED"
  and the post-build sentinel finds the dialog string → `REDNET_SILENT_ONBOARDING=on`. The image serves
  HTTP 200 with the onboarding dialog string present in the bundle.
- **The login trigger IS wired**: `postLoginSetup` calls `cryptoSetup.rednetOnboard(...)` when
  `SHOW_ENCRYPTION_SETUP_UI === false`, injecting the Modal UI; the module does the crypto. A real deploy now
  ships the silent-onboarding code, not stock Element.

## ✅ Browser E2E — PROVEN (2026-06-19)

The `[E2E?]` choreography concerns are now **resolved**. Playwright (`../e2e/onboarding.spec.ts`) against the
live single-host stack (Synapse 1.155.0 + MAS + Element v1.11.86 with the module + patch): **2/2 PASS (9.1s)**.

What was confirmed:

1. **Runtime choreography** — the async `onFreshAccount()` populates `cachedKey` BEFORE Element's synchronous
   `getSecretStorageKey()` / `createSecretStorageKey()` fires. The keySink pattern works at runtime, not just
   in the type system.
2. **UI suppression** — `SHOW_ENCRYPTION_SETUP_UI=false` + `setupEncryptionNeeded()=true` suppresses Element's
   `CompleteSecurity` / `E2E_SETUP` views. No "verify this device" or "set up Secure Backup" dialog appeared.
3. **Passphrase round-trip** — a fresh account's generated passphrase was saved, then entered on a fresh
   browser context (simulating a new device). Identity + key backup recovered. The recovery path
   (`onFreshDevice` → `deriveRecoveryKeyFromPassphrase` → `checkKeyBackupAndEnable`) works end-to-end.
4. **matrix-js-sdk shapes** — `secretStorage.getKey()` returning `[keyId, descriptor]` with the passphrase
   PBKDF2 params works at runtime against the v34.12.0 SDK + Synapse 1.155.0.

## Phase-2 escrow crypto — BEHAVIORALLY VERIFIED (2026-06-19)

The full escrow construction (RECOVERY.md §5-§12) is now implemented and tested:

- **Shamir:** `shamir-secret-sharing` (Privy, Cure53+Zellic audited, GF(2^8), zero deps).
  Wrapper: `src/shamir.ts`. **10/10 behavioral checks PASS** (`test/shamir-behavioral.mjs`).
- **ECIES:** P-256 WebCrypto, `src/ecies.ts`. **14/14 test vectors PASS** against Python reference.
- **Escrow construction:** `src/escrow.ts` — composes Shamir + ECIES + scrypt + HKDF + AES-256-GCM.
  **13/13 behavioral checks PASS** (`test/escrow-behavioral.mjs`):
  - moderators_only: 3-of-5 recover, 2-of-5 blocked
  - passphrase: 3+correct recover, 3+wrong blocked, 2+correct blocked, 3+none (coerced quorum) blocked
  - revocation: re-share kills old shares (old + new mix blocked)
  - growth: 2-of-3 → 3-of-5, threshold rises, 2-of-5 blocked
  - cross-context: wrong member AAD rejects share unseal
- **scrypt KDF:** `@noble/hashes` (audited, zero deps). Test vector match (primitives.json) confirmed.

**AAD design:** two layers — `blobAad(member, mode, dir_version)` is stable across reshares (moderators
can re-share without the member's passphrase); `shareAad(member, mode, dir_version, m, n)` includes the
policy, binding shares to their quorum context.

## Phase-2 escrow lifecycle — BEHAVIORALLY VERIFIED (2026-06-19)

The lifecycle layer bridges the verified crypto primitives to the Matrix client:

- **Directory authentication:** `src/directory.ts` — Ed25519 signed moderator directory (`@noble/curves`).
  **4/4 checks PASS** (valid sig, wrong pubkey, tampered version, tampered policy).
- **Event protocol:** `src/events.ts` — 4 custom Matrix event types (`org.rednet.recovery.{directory,
escrow, request, share}`) + serialize/deserialize round-trip. **2/2 checks PASS**.
- **Recovery handshake:** `src/escrow-lifecycle.ts` — deposit, recovery request (ephemeral P-256 keypair
  - 6-digit binding code), reseal-to-device, share collection + reconstruction, health checks. **4/4
    checks PASS** (moderators-only + passphrase mode handshake, wrong-key rejection).
- **CryptoSetup integration:** `src/RednetCryptoSetup.ts` — `configurePhase2()`, automatic escrow deposit
  on fresh account (when directory available), Phase-2 recovery path with moderator-assisted flow,
  escrow health check API.

**Total verified checks: 47/47** (10 Shamir + 13 escrow + 14 ECIES + 10 lifecycle).

### Not built (runtime infrastructure, not crypto)

- **Moderator approval tool** — native app with secure-element P-256 key binding (RECOVERY.md §5b).
- **Coordination bot** — keyless relay for recovery requests + share delivery.
- **Lifecycle prompt UI** — "your escrow references a revoked moderator" detection is built; the
  user-facing prompt + re-escrow trigger are not.

## Remaining (needs external review)

The module is now **implemented, build-integrated, and behaviorally verified**. What remains is an **external
Matrix-crypto review** by a specialist familiar with Element's `CryptoSetupExtensions` lifecycle, `rust-crypto`
lazy restore, and the 4S/cross-signing/key-backup interaction. The in-house E2E proves the happy path works;
the external review is needed for:

- Edge cases under concurrent logins / slow network / partial bootstrap
- Whether the `checkKeyBackupAndEnable()` lazy-restore path has silent failure modes
- The malicious-core re-provision guard in `silentBootstrap` (does it actually prevent a rogue server
  from re-keying the member?)
- Key backup trust model: does `checkKeyBackupAndEnable()` verify the backup signature, or trust blindly?
- Phase-2 AAD binding + directory authentication under adversarial conditions
