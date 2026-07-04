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

## Hiding native room/space creation (`customisations.json` + `RednetComponentVisibility.ts`)

Room/space creation is locked **server-side** (`synapse-modules/rednet_room_policy.py`): the system
accounts create rooms via the gov bot (`!gov room` / `!gov space`), members request them with
`!gov request`. Stock Element still renders **Create Room / Create Space / Explore** buttons, which
now dead-end in the module's `403` — and the space-creation flow _spins_ rather than surfacing it. A
`ComponentVisibility` customisation hides them so the client matches the policy:

- `src/RednetComponentVisibility.ts` (copied into `src/customisations/` by the Dockerfile) —
  `shouldShowComponent()` returns `false` for `UIComponent.CreateRooms`, `CreateSpaces`, `ExploreRooms`.
- `customisations.json` (repo root) maps the default `ComponentVisibility.ts` to our file; webpack
  resolves it at build time.

⚠️ **Re-anchor per release**, like `integration.patch`: the `UIComponent` values and the customisation
path are pinned to `ELEMENT_VERSION` (and upstream deprecates customisations in favour of the module
API, which doesn't yet expose component visibility). The Dockerfile greps the built bundle for a
module-load marker and warns if the customisation wasn't wired.

## Hiding leaky/broken affordances (`hide-affordances.patch`)

Verified against `v1.11.86`: some stock affordances our security model breaks are **hardcoded** in
their components — neither `config.json` nor the `ComponentVisibility` customisation can hide them, so
a source patch drops them:

- **Export chat** (`RoomSummaryCard.tsx`) — any member could export a room's **full decrypted history**
  to a file in one click; a portable seizure/exfil artifact against the retention posture.
- **Native message Report** (`MessageContextMenu.tsx`) — routes the event + reason to the **homeserver
  admin** (the party our threat model distrusts) by default; use the coercion-aware `!report` → #gov-bot
  flow instead.
- **Add-extensions button** (`RoomSummaryCard.tsx`) — `integrations_ui_url` is empty, so it only
  dead-ends in a "no manager configured" dialog.

Unlike `integration.patch`, this apply is **FATAL** in the Dockerfile: if it stops applying, the build
**refuses** rather than silently shipping a client that still exposes Export/Report. CI (`element-build`)
also `git apply --check`s it against the pinned tag.

⚠️ **Re-anchor per release**: regenerate the diff against the new `ELEMENT_VERSION` (edit the three
JSX sites, `git diff > hide-affordances.patch`).

### `gate-call-buttons.patch`

Separate from `hide-affordances` because it's a _conditional_ gate, not a removal. In stock Element the
1:1 header voice/video buttons render for ≤2-member rooms regardless of any config (the group/video
feature flags and `UIFeature.voip` don't gate them — `voip` only gates the incoming-call listener).
REDnet has no legacy 1:1 VoIP path (P2P disabled to prevent IP leak, no TURN), so with calls off
(default) they only dead-end. This patch wraps the buttons in `RoomHeader.tsx` in the already-present
`groupCallsEnabled` (`feature_group_calls`), so they hide when calls are off and show when the `calls`
profile enables them (Element Call). **Graceful** apply; re-anchor per release.

## Request a room/space button (`RednetRequestRoomDialog.tsx` + `request-room-button.patch`)

The **positive** affordance replacing the hidden native creation. A member clicks **Request a room
or space** in the room-list `+` menu → a dialog collects a name + optional reason + room/space
choice → the client sends `!gov request room|space "NAME" --why "REASON"` to their DM with
`@rednet-gov` (the gov bot's `handle_dm_gov` queues it for organizer review). Nothing is created
client-side; it's a request.

- `src/RednetRequestRoomDialog.tsx` (copied into `src/components/views/dialogs/` by the Dockerfile) —
  self-contained: `ensureDMExists(@rednet-gov)` + `sendTextMessage`, then an `InfoDialog` confirmation.
  Hardcoded English (fork ships en only), which also sidesteps Element's compile-time `_t()` key gate.
- `request-room-button.patch` (RoomListHeader.tsx) — adds the menu item to **both** plus-menu branches
  (Home tab + active space) and forces `canShowPlusMenu = true` (hiding native creation would otherwise
  leave the Home menu empty and drop the `+` entirely).

**Graceful** (unlike `hide-affordances.patch`): if the patch stops applying, the build warns and ships
a working client — members request via the `!gov request` command, which the guides + the pinned
#reference message document. The Dockerfile greps the bundle for the button label to confirm it wired.

⚠️ **Re-anchor per release**: the `RoomListHeader` plus-menu structure + the dialog's SDK imports
(`ensureDMExists`, `sendTextMessage`, `Field`) are pinned to `ELEMENT_VERSION`.

## Duress / panic control (`RednetPanicDialog.tsx` + `panic-button.patch`)

The coercion control (server side is COMMUNITY-MANAGEMENT.md "Duress / panic control"). A
member whose device is seized, force-unlocked, or who is pressured to hand over their
account hits one confirm-gated **Panic — wipe this device** item in the user menu, which:

1. sends `!duress` (plaintext) to their `@rednet-gov` DM — the gov bot's `handle_duress`
   self-locks the **sender's own** account (a reversible MAS lock that kills every session)
   and alerts organizers; then
2. dispatches Element's `logout`, which runs `onLoggedOut()` →
   `clearStorage({ deleteEverything: true })`: the crypto store (`clearStores`),
   `localStorage`, `sessionStorage` and the session token are all wiped, returning the device
   to a blank login.

- `src/RednetPanicDialog.tsx` (copied into `src/components/views/dialogs/`) — self-contained.
  **The wipe must not be gated on the signal**: under duress the network may be cut, so the
  send is best-effort and time-bounded (`SIGNAL_TIMEOUT_MS`), and the logout always runs. It
  dispatches `logout` **directly** to skip Element's "back up your keys first" warning — a
  panic wipe wants the data gone, not preserved.
- `panic-button.patch` (`UserMenu.tsx`) — adds the red menu item next to Sign out and imports
  the dialog. **Graceful** apply: if it stops applying, the client still works (a member can
  type `!duress` in their gov-bot DM by hand, which the guides document). The Dockerfile greps
  the built bundle for `wipe this device` to confirm it wired.

⚠️ **Re-anchor per release**: the `UserMenu` option list + the dialog's SDK imports
(`ensureDMExists`, `sendTextMessage`, `defaultDispatcher`, and the `logout` action's
`clearStorage` behaviour) are pinned to `ELEMENT_VERSION`.

## Legibility UI: role labels, retention pill, governance nav

Three small additions that make REDnet's governance model visible in the client. All
**graceful** (a non-applying patch just drops that one affordance) and CI `git apply
--check`ed.

### Role labels (`role-labels.patch`)

Repoints the stock power-level → role text so it reads in REDnet terms and adds a **PL 75
Organizer** tier (stock Element only labels 50/100):

- `Roles.ts` `levelRoleMap()` — drives the role text in the UserInfo panel + timeline sender
  labels (via `textualPowerLevel`). Hardcoded English (the fork ships en only), which also
  sidesteps the compile-time `_t()` key gate — `power_level|organizer` isn't a real key.
- `EntityTile.tsx` — adds `PowerStatus.Organizer`, switches `PowerLabel` to plain strings, and
  drops the `_t()` wrapper at the render; `MemberTile.tsx` adds `[75, Organizer]` to the
  member-list badge map. So the member-list chip shows **Organizer** too.

### Retention indicator (`RednetRetentionPill.tsx` + `retention-indicator.patch`)

Stock Element has **no** retention UI, so the disappearing-message window is invisible. This
adds a room-header pill (amber `Nd`, tooltip "Messages here disappear after N days"). Data
source, in order: durable rooms (config `org.rednet.retention.exempt_localparts`, e.g.
`#reference`, `#vouch-log`) show **nothing**; else a per-room `m.room.retention` `max_lifetime`;
else the deploy default `org.rednet.retention.default_days`.

- That default is the server retention (`REDNET_RETENTION_DAYS`) the client **can't** read from
  `homeserver.yaml`, so `build.sh` threads it into `config.json` (`__REDNET_RETENTION_DAYS__`).
- `RednetRetentionPill.tsx` copied into `src/components/views/rooms/`; the patch inserts it in
  `RoomHeader.tsx`. Styled in `branding/rednet-overrides.css`.

### Governance dashboard nav (`RednetGovernanceButton.tsx` + `governance-nav.patch`)

Promotes the `/governance/` dashboard from a room widget to a persistent space-panel footer
button — **organizer-only**: it renders only for a PL≥75 member of `#governance` (members
aren't in that room), so a non-organizer never sees a dashboard they can't use. The dashboard
also auth-gates server-side (`mint_endpoint` verifies PL via the Matrix OpenID token), so this
is UX, not the security boundary. Copied into `src/components/views/spaces/`; the patch inserts
it in `SpacePanel.tsx` next to `QuickSettingsButton`.

⚠️ **Re-anchor per release**: `Roles.ts`/`EntityTile`/`MemberTile` power-level shapes,
`RoomHeader.tsx`'s heading block, `SpacePanel.tsx`'s footer, and the SDK imports
(`SdkConfig`, `MatrixClientPeg`, `room.currentState.getStateEvents`) are pinned to
`ELEMENT_VERSION`.

## Report to organizers (`RednetReportDialog.tsx` + `report-to-organizers.patch`)

The **positive counterpart** to removing native Report (`hide-affordances.patch`): native
Report POSTs the event + reason to the homeserver admin — the party our threat model distrusts.
This replaces it with a right-click **Report to organizers** on any message → a dialog (shows
the sender + a reason field) that sends `!report @sender --detail "<reason> [message <id> in
<room>]"` to the member's DM with `@rednet-gov` (the gov bot's `handle_report` alerts organizers
in #gov-bot). Available to **every** member (unlike the organizer-only member actions) — it's
the member safety tool; the reported user is never notified.

- `RednetReportDialog.tsx` copied into `src/components/views/dialogs/`; the patch adds the
  `MessageContextMenu.tsx` menu item.
- **Composes with `hide-affordances.patch`**, which also edits `MessageContextMenu.tsx` (it
  blanks the native Report _definition_; this adds an item to `commonItemsList`). The hunks
  don't overlap — verified to `git apply` cleanly to **both** the pristine and the
  hide-affordances-patched tree, so CI (independent per-patch `--check`) and the Dockerfile
  (sequential apply, hide-affordances first) both work.

**Graceful** apply. ⚠️ **Re-anchor per release** with the `MessageContextMenu` option list.

## Member governance actions (`RednetMemberGovDialog.tsx` + `member-gov-actions.patch`)

Organizer-only member actions from the UserInfo panel. A **Manage member** item appears in the
admin-tools section only for a PL≥75 viewer (`RoomAdminToolsContainer`, gated on `me.powerLevel`
and not self), opening a dialog that runs the SAME governance commands an organizer would type
in #gov-bot — `!gov role @user moderator|organizer` and `!gov revoke @user --reason "…"` — sent
to the #gov-bot room (resolved by alias; the organizer is a member there, and `handle_command`
enforces the real PL authorization + writes the audit record). Nothing is authorized
client-side; it's a convenience surface over the existing chat commands, which is why it's the
lowest-priority Part-B item.

- `RednetMemberGovDialog.tsx` copied into `src/components/views/dialogs/`; the patch adds the
  `MenuItem` to `RoomAdminToolsContainer`, reusing UserInfo's already-imported `MenuItem`,
  `Modal`, and `BlockIcon` (no new icon import to re-anchor).

**Graceful** apply. ⚠️ **Re-anchor per release** with `RoomAdminToolsContainer`'s render block.

## First-run onboarding checklist (`RednetOnboardingDialog.tsx` + `onboarding-checklist.patch`)

The safety basics a new member needs — save your passphrase, kill lock-screen previews, keep
your identity out of chat, know the retention window — as a one-time in-app modal after login,
instead of only a gov-bot chat message that scrolls away.

- `RednetOnboardingDialog.tsx` copied into `src/components/views/dialogs/`; the patch adds a
  trigger at the end of `MatrixChat.onShowPostLoginScreen`, shown **once per device** via a
  `rednet_onboarding_seen` localStorage flag (set before the modal opens, so a reload mid-dialog
  can't re-show it).
- **Deliberately SEPARATE from `integration.patch`** — that patch drives the recovery-critical
  silent-onboarding crypto bootstrap (in `postLoginSetup`), where a re-anchor mistake breaks
  N=1 / new-device recovery. This checklist patches a _different_ method (`onShowPostLoginScreen`)
  with a non-overlapping import anchor (after `import Modal`, far from integration.patch's import
  hunk), so it can never affect crypto setup. **Verified** to `git apply` cleanly to **both** the
  pristine and the integration-patched tree.

**Graceful** apply (onboarding is unaffected if it stops applying). ⚠️ **Re-anchor per release**
with `onShowPostLoginScreen`.

## Vouch provenance + hardened data route (`RednetVouchProvenance.tsx` + `vouch-provenance.patch`)

"Vouched by @x" in a member's UserInfo panel — the trust chain, from the gov-bot's vouch graph
(`claimed` records, written by `!gov confirm`). Shown to all members; best-effort (renders nothing
where there's no recorded voucher, which is common).

**Hardened data route (security fix, done first).** The graph lives in `vouch.jsonl`, which Caddy
previously `file_server`'d **unauthenticated** at `/governance/data/vouch.jsonl` — anyone reaching
the front could pull the whole trust network (the Caddyfile + compose comments flagged it). Now the
gov-bot serves it behind a **valid Matrix OpenID token** (`mint_endpoint._serve_vouch`, any member):
Caddy `reverse_proxy`s the route to `gov-bot:8091` (with `import sanitize`, which keeps the
`Authorization` header), and the `./vouch.jsonl:/srv/governance-data` Caddy mount is removed.
Unauthenticated + bad-token requests now get **401** (live-verified). Embedded dashboards use the
Widget API (unaffected); standalone dashboards have no token and fall back to manual paste.

- `RednetVouchProvenance.tsx` (copied into `src/components/views/right_panel/`) fetches the route
  with `Authorization: Bearer ${cli.getOpenIdToken().access_token}`, parses the ndjson, and shows
  the latest `claimed` voucher for the member. The patch inserts it in `BasicUserInfo`.
- **Composes with `member-gov-actions.patch`** (both edit `UserInfo.tsx`; non-overlapping hunks —
  verified `git apply` clean on both the pristine and the member-gov-patched tree).

**Graceful** apply. Gov-bot unit tests lock the 401/serve gate (`TestVouchServeAuth`). ⚠️
**Re-anchor per release** with `BasicUserInfo`'s render + the `import BaseCard` anchor.

## Room lifecycle (`RednetRoomLifecycleDialog` + `RednetRoomLifecycleOptions` + `room-lifecycle.patch`)

Organizer/admin room-lifecycle actions in a room's right-click menu (`RoomGeneralContextMenu`):
**Archive room** (organizer, PL≥75 in #governance) and **Delete room** (admin, PL≥100), each
behind a **typed-confirm** dialog (you must type the room's name to enable the button). They send
`!gov archive <roomId>` / `!gov delete <roomId>` to #gov-bot, where `handle_command` enforces the
real PL and does the work (archive locks the room read-only + unlinks it from its space; delete
purges it). `resolve_room_ref` accepts a raw `!roomId`, so no alias is needed.

- `RednetRoomLifecycleOptions.tsx` (copied into `src/components/views/context_menus/`) gates on
  the viewer's #governance PL and renders the menu items after Leave; `RednetRoomLifecycleDialog.tsx`
  (copied into `dialogs/`) is the typed-confirm. `room-lifecycle.patch` inserts the options
  component into `RoomGeneralContextMenu`.

**Graceful** apply. ⚠️ **Re-anchor per release** with `RoomGeneralContextMenu`'s render block.

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
