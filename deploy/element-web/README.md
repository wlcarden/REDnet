# REDnet Element Web: soft fork

The web client. A **soft fork** of upstream Element Web that (a) locks the client to the REDnet
homeserver and strips metadata-leaking features, and (b) makes E2EE setup **silent**. A fresh user
logs in and never sees a recovery-key dialog or a device-verification nag.

> **Status: build context, browser E2E proven (2/2 PASS, 2026-06-19).** The webpack build is large;
> it runs at deploy time via `build.sh`. The CryptoSetupExtensions module (`rednet-module/`) drives
> silent onboarding; `integration.patch` wires it into MatrixChat's login flow.

## Why a fork (not a module/config)

Config + the Element module API can rebrand and lock the server, but they **cannot** silently call
`bootstrapSecretStorage`. Element always routes the secret-storage key through an interactive dialog
(`SecurityManager.getSecretStorageKey`). The prototype's "log in elsewhere, then hand off to Element"
path (milestone D) failed: a fresh Element login **re-nags**. So the silent bootstrap must happen
_inside_ Element. Two source edits, hence the fork.

## Build

```bash
./element-web/build.sh                       # renders config.json, builds the `element` image
docker compose --profile web up -d element    # start it; the front proxies / to it
```

Pin the version in `rednet.env`: `ELEMENT_VERSION=v1.11.86` (use an exact upstream tag).

## The silent-onboarding integration (`integration.patch`)

One hunk in `src/components/structures/MatrixChat.tsx`, applied best-effort by the Dockerfile (it
warns + continues if it no longer matches):

- **`MatrixChat.tsx` / `postLoginSetup()`**: checks `ModuleRunner.instance.extensions.cryptoSetup`
  for REDnet's `rednetOnboard()` method. If present, drives the full onboarding flow (fresh account →
  generate + show passphrase; returning device → prompt + retry up to 3 attempts) via modal dialogs,
  then skips Element's stock `COMPLETE_SECURITY` / `E2E_SETUP` views. The crypto lives in the module;
  the patch provides only the UI bridge (`RednetRecoveryKeyDialog`).

⚠️ **Re-anchor per release.** Element relocates this file between versions, so `integration.patch`
is version-anchored to `ELEMENT_VERSION`. If it stops applying, the build ships a branded client
with Element's stock onboarding, a **recovery-capability regression** (Security Key, not passphrase;
breaks N=1 / new-device recovery). The Dockerfile's build-sentinel check makes this machine-detectable.
**Validate** after building: log in on a fresh account and confirm our REDnet dialog appears (not
Element's), and cross-signing shows green.

## Recovery, Phase 1: self-held passphrase (`rednet-module/src/onboarding.ts`)

**Browser E2E proven** (2/2 PASS, 2026-06-19). Recovery is native Matrix 4S keyed by a **member
passphrase**. Works at any community size, including a lone founder (N=1), with no moderator
infrastructure. The module's `RednetCryptoSetup` class drives:

- `onFreshAccount(client)`: new account: provision cross-signing + 4S + key backup keyed by a
  7-word EFF diceware passphrase (~90 bits). The UI surfaces it **once** ("save this").
- `onFreshDevice(client, passphrase)`: fresh device: re-derive the 4S key from the passphrase,
  recover the **same** cross-signing identity, and restore message history from key backup.
- `rednetOnboard(...)`: single entrypoint for the integration patch; handles the fresh-vs-returning
  fork, 3-attempt retry with error display, and client-side auto-join of starter rooms.
- Defense: `silentBootstrap` refuses to re-provision if secret storage already exists server-side
  (malicious-core guard).

The passphrase MUST be **diceware-grade** because there's no trusted hardware to rate-limit guesses; a
seized server could brute-force a weak one (RECOVERY.md §8). The generator uses EFF-large (7776
words), rejection sampling, 7-word minimum.

**Phase 2 (governance-gated moderator quorum)** is a separate, later sub-project; see `RECOVERY.md`
(crypto proven in `spikes/05-recovery-escrow/`). Phase 1 is the bootstrap recovery and stands alone.

## What `config.json` enforces

Locked to our homeserver (`disable_custom_urls`), no guests, no identity server, no public room
directory, URL previews off, E2EE-by-default with secure backup required, dark theme, brand from
`REDNET_BRAND`. Drop a logo at `themes/element/img/logos/rednet.svg` in the build to brand the login.
