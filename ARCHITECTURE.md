# REDnet — System Reference (how it all works, and what you get)

**Status:** Architecture shakedown (2026-06-16). The third doc: `DESIGN.md` = _why_, `SPEC.md` = _what to build_, this = **_how it works end-to-end + what features the community actually gets_**. Goal: nothing about the running system is a surprise before it touches hardware. **Build status (2026-07-04):** the stack described here is built and CI-verified in-sandbox ([deploy/](deploy/)); the real-infra + external-review items are in §12 and [README § Project status](README.md#project-status).

Everything here is either empirically verified in `spikes/` + `prototype/` (flagged ✅) or primary-source-researched (flagged with the source area). Genuine unknowns are in §12.

---

## 1. The running system — every process, where it lives

REDnet is **three roles** (boxes). v1 is the first two; the third only exists if you add calls.

```
                 ┌─────────────────────────── CLIENTS ───────────────────────────┐
                 │  Customized Element Web (browser)   ·   Element X (iOS/Android) │
                 └──────────────────────────────┬────────────────────────────────┘
                                                │  HTTPS :443
                          ┌─────────────────────▼─────────────────────┐
                          │  FRONT  (clearnet, disposable, public IP)  │
                          │  • Caddy (auto-TLS, reverse-proxy split)   │
                          │  • serves Element Web static bundle        │
                          │  • /.well-known/matrix/client (static)     │
                          └─────────────────────┬─────────────────────┘
                                                │  WireGuard (no public IP on core)
        ┌───────────────────────────────────────▼───────────────────────────────────────┐
        │  CORE  (no public IP — the metadata honeypot)                                   │
        │  • Synapse :8008  (Matrix homeserver, monolith, no workers)                     │
        │  • MAS    :8080   (auth: tokens, sessions, no-PII accounts)                     │
        │  • PostgreSQL (localhost) — TWO databases: `synapse` + `mas`                    │
        │  • Draupnir (moderation bot)  • synapse-admin (break-glass, WG-only)            │
        │  • Prometheus + Grafana (WG-only)  • WireGuard endpoint                         │
        └─────────────────────────────────────────────────────────────────────────────────┘
        ┌─────────────────────────────────────────────────────────────────────────────────┐
        │  MEDIA NODE  (only if calls — DEFERRED) — directly internet-exposed, no data     │
        │  • LiveKit SFU + lk-jwt-service (WebRTC media; cannot hide behind the front)     │
        └─────────────────────────────────────────────────────────────────────────────────┘
```

| Process                | Role            | What it is / does                                                                                                                           |
| ---------------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| **Synapse**            | core            | The Matrix homeserver. Stores rooms/events/state, fans out via `/sync`, serves media. Monolith (no workers needed at 250). The honeypot. ✅ |
| **PostgreSQL**         | core            | Two DBs: `synapse` (all Matrix state) and `mas` (auth/users/sessions). `LC_COLLATE=C`, localhost-only. ✅                                   |
| **MAS**                | core            | Matrix Authentication Service. Owns login, tokens, sessions, account creation. Synapse delegates _all_ auth to it. ✅                       |
| **Caddy**              | front           | TLS termination (auto-ACME) + reverse-proxy split + serves the Element Web bundle. The only public face. ✅                                 |
| **Element Web**        | served by front | The browser client — **a soft fork** (§7) for the silent-onboarding first-run + branding. Static files.                                     |
| **Element X**          | app stores      | The mobile client (iOS/Android). Stock works against our server; constrained (§6/§7).                                                       |
| **Draupnir**           | core            | Moderation bot — bans, policy/ban-lists, anti-raid protections; also writes per-room retention presets.                                     |
| **Prometheus+Grafana** | core (WG-only)  | Self-hosted monitoring. No third-party telemetry.                                                                                           |
| **synapse-admin**      | core (WG-only)  | Break-glass admin console. Never routed by the front.                                                                                       |
| **WireGuard**          | front↔core      | The private tunnel; the core has no public IP.                                                                                              |

## 2. How the pieces connect (the runtime wiring)

**Client → front → core.** A client hits `https://<domain>` (Caddy, :443). Caddy terminates TLS and reverse-proxies over WireGuard to the core, splitting by path (✅ verified, Spike 03):

- `^/_matrix/client/.*/(login|logout|refresh)` → **MAS** (:8080) — the auth endpoints
- `^(/_matrix|/_synapse/client)` → **Synapse** (:8008) — everything else
- `/.well-known/matrix/client` → static JSON on the front
- `/_synapse/admin` → **denied** at the front (admin is WG-only)
- everything else → the **Element Web** static bundle

**Synapse ↔ MAS (delegated auth).** ✅ verified (PWA-B). Synapse runs no auth of its own. On each authenticated request it validates the bearer token against MAS using the **shared-secret `matrix_authentication_service` integration** (Synapse → MAS over `http://mas:8080`, authenticated by a secret both sides hold). MAS answers "valid, this is `@alice`, device X" or "no." So: **MAS owns _who you are_; Synapse owns _what you can see_.** This is why a MAS-issued token returns `@alice` from Synapse's `/whoami` — that handshake _is_ the delegation.

**Synapse ↔ Postgres (`synapse` DB).** All Matrix state — events, room state, devices, keys, account data. **MAS ↔ Postgres (`mas` DB)** — users, sessions, tokens. Two separate databases (a backup gotcha — §8). Both localhost-only.

**The sync loop.** A logged-in client holds a long-poll: `GET /_matrix/client/v3/sync` (Element Web) or **Simplified Sliding Sync** (Element X — required by EX, served natively by modern Synapse). New events stream down this connection in near-real-time. ✅ (the prototype clients ran this loop.)

**Media.** Upload `POST /_matrix/media/v3/upload` → stored in Synapse's media store (the `synapse_data` volume on the core). Download `GET /_matrix/client/v1/media/download/...` (**authenticated media**, default in modern Synapse). In E2EE rooms the file is encrypted client-side before upload, so the media store holds ciphertext blobs. ✅ 10 MB media round-trips through the front intact (Spike 03).

**Push (⚠️ a metadata vector — read carefully).** When a client is backgrounded, Synapse notifies it via a push gateway → Apple/Google:

- **Stock Element X** uses **Element's own Sygnal gateway at matrix.org** → APNs/FCM. It works against your self-hosted Synapse with _no_ Apple/Google account of your own — but **push metadata (which account, when a notification fires, from which room indirectly) transits Element's gateway and Apple/Google.** For an at-risk community this is a real leak.
- **Android, Google-free:** Element X supports **UnifiedPush** with a self-hosted **ntfy** as push server + distributor (ntfy has a built-in Matrix→UnifiedPush gateway). No Google, no Element gateway. Requires EX ≥ ~26.04.3.
- **iOS:** there is **no Apple-free path** — APNs is unavoidable. iOS push either goes through Element's matrix.org gateway (stock app) or your own Sygnal + APNs cert + a custom app build.
- **Element Web:** no gateway needed, but notifications only fire while the tab is open (poll-based).

**No federation.** Closed island: no :8448 listener, `federation_domain_whitelist: []`, no `.well-known/matrix/server`. No server talks to any other server. This removes the biggest metadata-spread vector and a whole attack surface. ✅ (the restore spike confirmed no-federation removes the signing-key restore risk class.)

## 3. How Matrix end-to-end encryption actually works (the mechanics)

This matters because onboarding, recovery, and the honeypot all hinge on it.

- **Devices & keys.** Every login is a **device** with an **Olm account**: a Curve25519 identity key + an Ed25519 signing key (+ short-lived one-time keys). Keys live on the device; the server only stores the _public_ keys + a device list.
- **Olm** = a 1:1 Double Ratchet (the Signal algorithm) used for **device-to-device** messages ("to-device" events) — notably to hand room keys to other devices. Forward-secret per message.
- **Megolm** = a group ratchet for **room messages**. The sender creates a Megolm session, distributes its session key to each recipient device _over Olm_, then encrypts each message with Megolm. The server only ever sees the Megolm **ciphertext**. Sessions rotate (forward secrecy).
- **Cross-signing.** A user has three keys: **master**, **self-signing** (signs your own devices), **user-signing** (signs other users you've verified). Verify Alice once → trust all her current and future devices. The private cross-signing keys live encrypted in secret storage.
- **Key backup.** Your Megolm room keys, encrypted under a **backup key**, stored on the server so a new device can recover history. The server holds only the encrypted blob.
- **Secret storage (4S).** The cross-signing private keys + the backup key, encrypted with your **recovery key** (a ~59-char string) and stored in account_data. The recovery key is the master credential that unlocks everything.
- **Device verification.** A new device is untrusted until it's **cross-signed** — either by entering the recovery key (to unlock 4S and self-sign) or by another verified device. An unverified device can't read key backup and shows the "Verify this session" prompt. ✅ This is exactly why a _fresh_ Element Web login re-nags (PWA-D), and why onboarding must run in-session.

**What the server can and cannot see** (the honeypot boundary, ✅ verified in the spikes):

- **Never:** message plaintext, the cross-signing/backup private keys (encrypted in 4S), the recovery key.
- **Always (plaintext):** the social graph (who's in which room), the **envelope** of every message (sender pseudonym, time, room, type), device lists, public keys, account data. Plus the _encrypted_ backup/4S blobs. **Client IPs:** the front forwards a constant placeholder (`192.0.2.1`) instead of the real IP; `user_ips` bounded by 1-day retention; MAS tables scrubbed by `scrub-metadata.sh` — the core is no longer an IP honeypot.

## 4. End-to-end lifecycles (traced)

**Onboarding** (✅ browser E2E proven, 2/2 PASS): scan card QR → opens our **customized Element Web** → it logs in the **MAS-created no-PII account** on Element Web's _own_ session → a patched `postLoginSetup()` detects the CryptoSetupExtensions module → silently runs `bootstrapCrossSigning` + `bootstrapSecretStorage` + key backup → surfaces a **7-word diceware recovery passphrase** ONCE ("save this, it's the only way back in") → the module client-side joins the community Space + starter channels → user lands in the room list, on a verified device, fully encrypted. ~2 visible steps. Returning account on a new device: prompts for the passphrase with 3-attempt retry + error display.

**Sending a message** (E2EE room): client ensures it has the room's Megolm session (creating one + sharing keys to any new devices via Olm if needed) → encrypts → `PUT /rooms/{id}/send/m.room.encrypted/{txn}` → Synapse stores the ciphertext event + plaintext envelope → other devices receive it on their `/sync`. ✅ (the spikes sent/stored `m.room.encrypted` events.)

**Retention purge** (✅ Spike 01): a Synapse purge job deletes message events older than the room's window (server default 7d, or a per-room preset the Draupnir bot writes). Message bodies + `event_json` are genuinely deleted. **State events** (membership, room name, encryption) and the **last message** persist by design — so "everything disappears" is false; "message bodies expire, metadata and the last message remain" is true.

**Backup / restore** (✅ Spike 04): hourly `pg_dump -Fc --exclude-table-data e2e_one_time_keys_json` of **both** DBs + signing key + **MAS `secrets.encryption`** + media → restic (append-only, repo key off-core). Restore = provision a fresh box (so `/data` perms + media dir exist), restore both DBs, place secrets, start. Identical `server_name` is the one hard invariant. Cold restore; data-loss window = time since last backup (trivial under short retention).

**Moderation:** named-role power levels (mods at PL50) handle day-to-day kick/ban/redact in-client; **Draupnir** (bot) enforces cross-room bans, subscribable community ban-lists, and anti-raid protections, and writes the per-room retention presets. (Draupnir is _mandatory_ at this scale, not optional — Matrix's native moderation is coarse.)

## 5. The data model — what's stored where

| Store                            | Holds                                                                                                                                                                                         | Sensitivity                                                                                 |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| **Postgres `synapse`**           | events (ciphertext bodies + **plaintext envelopes**), room state (membership/name/encryption — **plaintext**), device lists, public keys, encrypted 4S/backup blobs, account data, `user_ips` | **The honeypot.** Content E2EE; metadata plaintext. Bounded by retention.                   |
| **Postgres `mas`**               | users (pseudonyms, **no email/PII** ✅), sessions, ephemeral password hashes, tokens                                                                                                          | Identity layer. No PII by config. Needs `secrets.encryption` to decrypt → back up together. |
| **Media store** (`synapse_data`) | uploaded files; for E2EE rooms, **encrypted blobs**                                                                                                                                           | Content encrypted; existence/size visible.                                                  |
| **Client devices**               | the real keys + decrypted local history                                                                                                                                                       | Out of REDnet's control (the ceiling — DESIGN §1).                                          |

## 6. Feature inventory — what the community actually gets

(Researched, 2026; `✅` works, `⚠️` caveat, `❌` absent.) **The headline: Element Web is full-featured; Element X (mobile) is good but has real gaps.**

| Capability                                              | Web (Element Web)                     | Mobile (Element X)          | Notes                                                                                       |
| ------------------------------------------------------- | ------------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------- |
| Rooms, **Spaces** (org hierarchy)                       | ✅                                    | ✅ (Spaces landed Mar 2026) | Channels = rooms grouped in a Space                                                         |
| **Threads**                                             | ✅ GA                                 | ⚠️ **Labs/beta only**       | Biggest web↔mobile gap                                                                      |
| Replies, reactions, edits, markdown, @mentions, `@room` | ✅                                    | ✅                          | Edits don't erase history (redact to remove)                                                |
| Pinned messages                                         | ⚠️ labs flag (verify default-on)      | ✅                          |                                                                                             |
| Polls                                                   | ✅                                    | ✅                          | Works despite not being spec-stable                                                         |
| Files/images/video (50 MB default)                      | ✅                                    | ✅                          | Raise reverse-proxy body limit too                                                          |
| Voice messages; static location                         | ✅                                    | ✅                          | Live location ❌ on mobile                                                                  |
| Stickers / custom emoji                                 | ⚠️ / ❌                               | ❌ / ❌                     | Custom emoji is an Element-wide gap                                                         |
| **Message search — unencrypted**                        | ✅                                    | ❌ **none**                 |                                                                                             |
| **Message search — encrypted**                          | ✅ **Desktop app only** (not browser) | ❌ **none**                 | ⚠️ Your primary mobile client **cannot search the archive** — a hard operational constraint |
| Notifications/push                                      | ✅ (tab open only)                    | ✅ (via gateway — §2)       | Push = metadata vector                                                                      |
| Moderation (roles/kick/ban)                             | ✅ + ACLs via devtools                | ✅ basic; ❌ advanced       | Draupnir applies to all clients                                                             |
| Element Call (voice/video)                              | ✅ (needs media node)                 | ✅ (needs media node)       | **Deferred**; separable add-on                                                              |
| Multi-account; widgets                                  | ✅                                    | ❌ / limited                |                                                                                             |

**Enabled in REDnet:** rooms, spaces, threads (web), replies/reactions/edits, formatting, mentions, pins, polls, files, voice messages, static location, search (web/desktop), power-level moderation + Draupnir; a public static `/reference` page for durable public-safe info (hotline / legal / mutual-aid links).

**Disabled by our hardening:** **presence** (server kill switch → ⚠️ everyone shows "Offline" permanently — the one clean server-side off-switch), URL previews, public room directory, federation, guest access. **Typing + read receipts have _no_ clean server-side off-switch** — only presence does; the honest mitigations are private read receipts + "don't send typing" enforced **by our Element Web fork** (stock clients can opt out but can't be forced). _This corrects the SPEC's "presence/typing/receipts off" to "presence off server-side; typing/receipts suppressed client-side via the fork."_

**Deferred:** Element Call (group voice/video) — adds a separate public-IP media box; nothing in messaging depends on it.

**Notably missing vs Discord/Slack** (so expectations are set): no invite-link "click and you're in" onboarding; mobile/encrypted search gaps; coarse moderation (no ban-from-Space, no AutoMod/audit-log/server-ACL UI → Draupnir mandatory); no native events/scheduling; weak custom-emoji/sticker culture; no always-on drop-in voice.

## 7. The clients — and the onboarding build reality

**Element Web = a soft fork (researched, verified patch point).** Config + the module API get ~80% but **cannot** silently create secret storage with an app-held recovery key at first-run. So:

- **Config** does branding (`brand`, `branding.*`, custom theme), homeserver lock (`default_server_config` + `disable_custom_urls`), and UI hiding (`UIFeature.*`).
- **A CryptoSetupExtensions module** (`rednet-module/`, `SHOW_ENCRYPTION_SETUP_UI=false`) handles all crypto: silent bootstrap, passphrase generation (7-word EFF diceware), recovery, malicious-core guard, and client-side room join. Browser E2E proven (2/2 PASS).
- **A 51-line fork patch** (`integration.patch`) at `postLoginSetup()` in `MatrixChat.tsx` wires the module's `rednetOnboard()` into the login flow and provides the `RednetRecoveryKeyDialog` modal UI (show-once + prompt-with-retry). Element already ships ~80% of the machinery; our net-new code is the module + one hunk.
- **Cost = maintenance, not authorship:** Element Web ships weekly/biweekly, pins matrix-js-sdk to a moving branch, and `MatrixChat.tsx` churns. **Model the discipline on Tchap** (French gov's maintained soft-fork with custom onboarding): marked `// :REDNET:` divergences, a long-lived rebase branch, a modifications manifest. **AGPL-3.0 §13:** a network-served fork must offer its source to users — fine for an open at-risk tool, but it means our modifications are publicly disclosable.

**Element X (mobile) = stock, with constraints.** It needs MAS + native sliding sync (both present ✅). Gaps: no search, threads labs-only, no multi-account on iOS. **Branding:** Element's "self-branded apps" is enterprise/contact-sales (likely out of budget); the budget path is a DIY `element-x-*` build or just **homeserver-lock via MDM/deep-link** (`account_provider=`) on the stock app. You still need your own Apple ($99/yr) + Google ($25) developer accounts to publish a custom build, and you'd be the named publisher.

## 8. Operations — running it

- **Deploy = GitOps.** Fork `matrix-docker-ansible-deploy`, add the hardened overlay (federation-off, MAS, retention, two-tier, Draupnir, the config surface). Changes flow through signed, M-of-N-merged commits → `ansible-playbook` provisions the boxes. No standing admin (DESIGN §11). The Element Web fork is built and served from the front.
- **Monitoring** (Prometheus/Grafana, WG-only): disk-free on core (the #1 self-inflicted outage), Synapse/Postgres/MAS up, **backup-success heartbeat**, **front reachability** (the tripwire). No third-party telemetry.
- **Backups:** restic, append-only, off-core key (§4). **Quarterly restore drill** is the P0 ops ritual — the MAS-key/two-DB coupling fails _silently_ until auth/E2EE breaks, so only a drill proves recoverability.
- **Upgrades:** Synapse releases ~weekly (security-relevant — keep current); the Element Web fork rebases on upstream (the real recurring cost); MAS + Draupnir track their releases. Pin versions in the repo; bump deliberately; re-run the retention spike (`spikes/01`) on any Synapse bump (retention is version-sensitive).
- **Failure & recovery:** front dies → a standby front + DNS failover, rebuild the cattle; core dies → cold restore from backup onto an identical `server_name`; a seized running core → metadata exposed (retention-bounded), content stays E2EE.

## 9. The security posture, in one place (recap)

- **Content:** E2EE everywhere; the server never sees plaintext. ✅
- **Metadata:** the core is a honeypot — social graph + message envelopes + client IPs are plaintext server-side, bounded by retention. This is the accepted Tier-1 tradeoff (DESIGN §4); sensitive comms go to Tier 2.
- **Push:** a _new_ metadata vector — stock-app push transits Element/Apple/Google. Decide per deployment (§12).
- **Transport:** clearnet front (origin-obfuscated, not hidden — a seized front can leak the core's location); no onion (it breaks non-technical access).
- **Identity:** no-PII pseudonyms ✅; recovery = accept-loss + reserved v2 governance-gated identity recovery.
- **The device is the ceiling:** a compromised phone defeats every layer — out of scope, by design.

## 10. What the community can and can't do (the honest summary)

**Can:** run a real organizing town square — Spaces of channels, threaded discussion (web), files/images, voice messages, polls, pinned info + a durable public `/reference` page, moderation with community ban-lists, on both web (full) and mobile (good). Content is encrypted; history auto-expires; joining is a 2-tap card scan with no PII.

**Can't / weak:** search history on mobile (or in the browser for encrypted rooms — desktop app only); casual drop-in voice; custom-emoji/sticker culture; native events/scheduling; Discord-style invite-link joining. Threads on mobile are beta. And the operator carries real load: a soft-forked client to maintain, push to decide, Synapse to keep current, Draupnir to run.

## 11. How this maps to the other docs

`DESIGN.md` (why/threat) → `SPEC.md` (what to build, versions, config) → **this** (how it runs + features) → `spikes/` + `prototype/` (empirical proof). The corrections this shakedown feeds back: onboarding is a **soft fork** (not a thin PWA — `SPEC §5` updated); **push** is a metadata decision to add to `SPEC`; **typing/receipts** are client-suppressed-via-fork, not server-killed.

## 12. Gap & decision register (resolve before / during deploy)

**Decisions surfaced by the shakedown (yours):**

- `DEC` **Push strategy.** Accept Element's matrix.org gateway (easy, leaks push metadata), vs. Android-only UnifiedPush+ntfy (Google-free, self-hosted, no iOS), vs. self-host Sygnal + own FCM/APNs + custom app builds (most private, most work). iOS can never avoid APNs.
- `DEC` **Element Web fork maintenance commitment** — who rebases it weekly-ish, and acceptance of AGPL §13 source disclosure.
- `DEC` **Mobile client & branding** — stock Element X + homeserver-lock (cheapest), vs. DIY `element-x-*` branded build (own dev accounts + updates), vs. Element Pro self-branded apps (enterprise budget).
- `DEC` **Mobile-search gap** — accept it, route archivists to Element Desktop, or run a search bot/bridge. (Real constraint for an archive-heavy org.)
- `DEC` **Threads on mobile** — enable the EX labs flag (beta), or keep discussion in flat rooms until GA.

**Verify-before-deploy (researcher thin-evidence flags):** EX Threads GA status; `feature_pinning` default-on; the UnifiedPush Android fix release tag (~26.04.3); whether `embedded_pages` HTML executes scripts (don't rely on it); Element's self-branded-apps branding scope + price. **Resolved since (built):** the `postLoginSetup` / `integration.patch` is pinned to `ELEMENT_VERSION` (v1.11.86) and CI `git apply --check`s it every PR (plus a full image build); **Draupnir runs against native-E2EE Synapse without Pantalaimon** (acts on encrypted rooms without decrypting — see `deploy/`).

**Already empirically settled (no longer open):** retention purges encrypted rooms ✅; two-tier topology + media ✅; backup is recoverable ✅; silent E2EE bootstrap ✅; MAS no-PII delegation ✅; Element-Web hand-off must be in-session ✅.
