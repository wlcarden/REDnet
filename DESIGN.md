# REDnet — Design & Threat Document

**Status:** Draft / design stage (2026-06-16). Vetted, not yet implementation-ready. This doc is the reasoning-of-record and the eventual coding-agent brief. It captures _why_, not just _what_.

**How to read this:** §1 (scope) and §4 (tier framework) are the conceptual spine. §5–§8 are the architecture. §9 (compromise map) and §10 (controls) are the security floor nothing else may breach. §11 (governance) is the social layer. §13 tracks what's settled vs. open.

---

## 1. What REDnet is — and is not — for

**REDnet is** approachable, sovereign, self-hosted infrastructure for an at-risk community's **organizing and coordination** (~250 users) — the "town square." It keeps message _content_ private (E2EE), stays usable by non-technical people (install from an app store or open a browser; **no sideloading**), and is deployable by any group as a whitelabel appliance. It is the **Tier-1 tool** in a larger ecosystem (see §4), paired with — never replacing — a metadata-minimal Tier-2 tool ([[cairn]] / SimpleX) for sensitive exchanges.

**REDnet is _not_:**

- **Individual-target protection.** It does not defend a specifically-hunted person whose own _device_ is under active state attack (Pegasus-class spyware, forensic phone extraction). That lives on the device; no chat system solves it. Pretending otherwise is false comfort, which is a harm.
- **Metadata-minimal messaging.** A hosted Matrix server is, by design, a **metadata honeypot** (§9). It protects what is _said_, not _who said it to whom and when_. That tradeoff is acceptable _only because_ the sensitive layer lives in Tier 2, not here.

> **One-line scope:** REDnet protects _content_ and provides _approachable coordination_; it cannot hide the _social graph_ from a seized server, and it cannot protect a _compromised endpoint_. Conflating these layers is the central error we avoid.

## 2. Design history: why hosted Matrix, not a leave-behind mesh

Earlier drafts of REDnet were a "leave-behind / self-healing mesh" of cheap boxes on parasitic public Wi-Fi. After deep research (2026-06) that direction was **retired**. Recorded here so it isn't re-litigated:

1. **Matrix can't be a mesh.** It's single-writer; its own maintainers say a hot-spare can't work (cache coherence). Matrix.org itself rode out a 2025 DB loss with a multi-day cold restore — there is no off-the-shelf Matrix replication/failover. "More nodes = more robust" is not achievable on Matrix.
2. **Onion-mesh at scale on flaky Wi-Fi is unproven and fragile** (captive portals, no stable inbound address, the documented onion-federation breakages).
3. **The decider — approachability is the hard constraint.** The point of REDnet is adoption (1:1 is already solved by Cairn/Signal). The realistic UX bar is "app store or browser, no sideloading." Only Matrix/Element and DeltaChat clear it; the leave-behind-purist tools (Cwtch, Reticulum, Briar) all fail it. Holding approachability **forces** the server tier. Of the two survivors, Matrix — not DeltaChat — has the community/moderation features that are the whole point.

There is no viable fallback substrate either: P2P Matrix (Pinecone) is dormant; Nostr's mature group chat (NIP-29) is plaintext-to-relay, and its private path (Marmot) is unaudited alpha.

So: **a well-hosted, hardened Matrix server, made as approachable and low-footprint as possible.** Several pre-pivot conclusions survive intact: the scope (§1), the tier discipline (§4), governance (§11), and honest exposure disclosure.

## 3. Design principles (the _why_)

1. **The server is a honeypot — minimize what's in it.** Assume seizure/subpoena. Push content confidentiality to the _client_ (E2EE); minimize server-side metadata (retention, closed federation, no logging you don't need).
2. **Tier by risk; never oversell a tier.** Spend friction only where the threat justifies it, and tell users — in the UI — exactly what each tier does and does not protect.
3. **Minimize blast radius; never claim zero.** Every control caps an exposure; none eliminates it. Say so.
4. **Minimize the exposure footprint along all four axes** (§6): component count, internet-facing surface, data-at-rest, identity/attribution trail.
5. **Gate the control action, not the boot.** Authorization lives at a deliberate control action (deploy, key-release, promotion) an adversary can't perform — via the GitOps repo — not as standing admin access that can be coerced.
6. **REDnet enforces exactly one technical tier (Tier 1).** Anything above it is comms discipline the product _eases_ but does not _contain_ (§4).

## 4. The security-tier framework (tech tier vs. comms doctrine)

"Tier" does two different jobs, and we keep them separate:

- A **technical enforcement level** = what _one product's tech actually guarantees_. It is only a "design" feature if a single system can offer and enforce more than one level.
- A **shared safety vocabulary across tools** = a doctrine telling users "this is the kind of conversation that's safe here."

**REDnet enforces one technical tier.** Matrix can protect message contents but structurally cannot hide _who_ from its own infrastructure (identity-on-a-homeserver is the model). The climb to "identity-hidden" _is_ leaving Matrix for a different protocol. So REDnet is the **Tier-1 tool, full stop**; the ladder above it is **ecosystem doctrine**, not REDnet's design.

**Universal floor (every tier):** content E2EE; no-PII identity; honest in-UI exposure disclosure; no third-party telemetry.

**The ladder** (defined by what an adversary who compromises the _infrastructure_ learns). The tier _name_ says what's protected; the _explanation_ must state where protection ends — otherwise the reassuring name is the false-comfort trap.

| Tier  | Name (what's protected)     | Infra-compromise still reveals | Tool                           | Access              |
| ----- | --------------------------- | ------------------------------ | ------------------------------ | ------------------- |
| **1** | **Message contents secure** | who + when                     | Matrix / REDnet                | app store / browser |
| **2** | **Contents + who secure**   | that something happened, ~when | SimpleX / Cairn                | app + invite        |
| **3** | **Nothing observable**      | —                              | mixnet / in-person / dead-drop | high friction       |

**Feature set is coupled to tier** — richness and metadata-hiding trade off directly. This is not a choice; for live group calls it's a proven impossibility (Anonymity Trilemma — see §8):

| Feature                                    | T1  | T2                | T3        |
| ------------------------------------------ | --- | ----------------- | --------- |
| Text / async messaging                     | ✅  | ✅                | ✅ (slow) |
| Channels, moderation, 250-person community | ✅  | weak              | ❌        |
| Async voice/video **messages**             | ✅  | ✅                | ~         |
| **Live group voice/video calls**           | ✅¹ | ❌ _(impossible)_ | ❌        |

¹ **Tier-1-capable, but a separable add-on — NOT deployed by default.** Element Call (MatrixRTC + a LiveKit
SFU) needs its own public-IP media node and is **deferred** (ARCHITECTURE.md §6). The base deploy ships
text/threads/files/voice-messages; add the media node + Element Call when a deployment wants live calls.

**REDnet's responsibilities toward the ladder:** (a) be excellent at Tier 1; (b) label itself honestly in-UI (name + exposure — this label _is_ the exposure banner); (c) **ease the hand-off up the ladder** (let a user drop a Cairn invite, or "escalate to secure channel," as a client affordance); (d) ship the tier vocabulary as doctrine docs for deploying orgs. The product implements Tier 1 and _eases_ the discipline; it cannot _enforce_ the higher rungs.

**Co-hosting Tier 2 is rejected.** Putting a SimpleX relay on the REDnet box (or posting its join-link in a Matrix room) destroys Tier 2 two ways: **fate-coupling** (one seizure takes both tiers) and **correlation** (shared box/IP/timing + the discovery-link-in-the-honeypot let the adversary re-derive the "who" Tier 2 exists to hide). What that co-hosted design would actually deliver is **hardened Tier 1, not Tier 2** — and if you want that, build it as a short-retention Matrix room (no SimpleX needed), labeled honestly. **True Tier-2 stays separate infrastructure, joined out-of-band**; the easy "call for it from the main chat" is a _client hand-off_, never an infrastructure bridge.

> Tiers describe **infrastructure** compromise, not a hacked phone (that defeats every tier — §1). Tier-2's "when, not who" has a residual: enough timing correlation can sometimes re-derive who.

## 5. Architecture — the gold-standard hosted Matrix stack

### 5a. Components

**Core (must run):** hardened **Synapse** + **PostgreSQL**; a **reverse proxy** (Caddy/nginx); **Element Web** (static, pre-baked to this server); the **custom onboarding page** (the one bespoke piece — §7). **MAS** (Matrix Authentication Service) is included for first-class Element X mobile (see §7). **Draupnir** (moderation bot). **matrix-viewer** (account-free read-only room preview, since Matrix guest access is dead) — nice-to-have, can defer.

**Clients:** self-hosted **Element Web** (the browser door) + **Element X** (iOS/Android app), pointed at this server via a one-tap provisioning deep link.

### 5b. The three-box topology

| Box                                   | Internet exposure                            | Holds                                             | Disposable?            |
| ------------------------------------- | -------------------------------------------- | ------------------------------------------------- | ---------------------- |
| **Core**                              | none (no public IP)                          | Synapse + DB (the honeypot), MAS, onboarding page | No — protect it        |
| **Front proxy**                       | clearnet (443 only): web + client-server API | nothing persistent                                | Yes — rotatable cattle |
| **Media node** _(only if calls — §8)_ | **directly exposed, public IP**              | nothing persistent                                | Yes                    |

The **front** is a cheap, disposable, _monitored_ reverse-proxy VPS reachable by clients; it tunnels to the core over WireGuard. Run two or three and fail over; a front going dark is a **tripwire** (seizure/block signal). This delivers the leave-behind _instinct_ (cattle, tripwire, instant replace) without parasitic-Wi-Fi fragility — a front needs a stable, reachable address, which café Wi-Fi cannot provide. Honest residual: a seized _running_ front holds the WireGuard path to the core, so front seizure can reveal the core's _location_ (not its data — that needs a separate core seizure, and content stays E2EE). Origin-hiding here is **obfuscation against remote discovery, not protection against front seizure.**

### 5c. What we cut (each removal is surface gone)

Federation listener (closed federation → never opened); voice/video by default (text + files for v1 — §8); guest access (dead anyway); URL previews (SSRF); public room directory; **bridges to other platforms** (huge surface + metadata firehose — never); **all third-party telemetry** (Element Web phones home by default — off; self-host fonts/assets, strict CSP).

## 6. Hosting & exposure-footprint minimization

Exposure footprint = four independent axes; each gets a different move.

**Axis 1 — component count.** Run the minimum (§5a/5c). Every service is surface.

**Axis 2 — internet-facing surface.** Only **443 on the front** is public. PostgreSQL binds **localhost only** (it's the honeypot — zero internet exposure). **No federation port.** No world-exposed SSH — admin plane only over **WireGuard**, and ideally **no standing admin access** (deploy from the GitOps repo — §11). The onboarding page's token-minting/admin endpoints bind localhost, reached via the tunnel.

**Axis 3 — data-at-rest.** Short **retention** (the single biggest honeypot lever); **LUKS** full-disk encryption (protects a powered-off/decommissioned disk only — useless against a running box or compelled operator); **encrypted off-box backups** with the key _not_ stored on the server; minimal logging + short log retention; no third-party log services. Irreducible residual: while running, the DB holds the membership graph + the unencrypted who/when/which-room envelope of every message + fresh client IPs (Synapse has **no IP-logging off-switch**, only a short window) + receipts/typing (cannot be disabled server-side). That is the honeypot tax — bounded here, never erased; which is exactly why dangerous content goes to Tier 2.

**Axis 4 — identity/attribution.** Domain via a privacy-front registrar (Njalla-style) on a non-US ccTLD (the domain is often the softest takedown target); hosting **foreign-owned** (not a US firm's overseas region — CLOUD Act reaches US-nexus providers), **paid privately**; no personal emails/accounts tied to the infrastructure.

### 6b. Jurisdiction = whitelabel config, not a baked choice

Because REDnet is **agnostic/whitelabel**, we do not pick a country. We ship (a) a **decision framework** (host where the provider is foreign-owned relative to the deployer's adversary, ideally outside the 5/9/14-Eyes orbit, with slow legal cooperation), (b) **sane defaults** (Iceland, Switzerland — with the honest caveat that "data haven" reputations are partly marketing; foreign-ownership + litigated track record is what holds up), and (c) a **deploy-time config parameter**. Each deploying org picks based on _their_ users and _their_ adversary.

### 6c. Hardware sizing

Synapse for ~250 mostly-text users, closed federation: **~4–8 vCPU, 16 GB RAM, NVMe, ~100–200 GB disk** (budget DB growth; retention + closed federation keep it slow). A ~$25–60/mo VPS class. (This resolves the old lightweight-vs-Synapse question: server-side message **retention** is a core honeypot mitigation and only Synapse does it; a hosted box can afford Synapse.) The front proxy is tiny. The media node, if added, is a different class entirely (§8).

## 7. Onboarding & key management

**The approachable path (~2 taps):** a physical card with a QR encodes a URL carrying a single-use registration token. Scanning opens a **thin custom web onboarding page** (which we build) that auto-registers a **pseudonymous, no-PII account** via the token, auto-enrolls **key backup**, auto-bootstraps cross-signing, and the server **auto-joins** the welcome room. The user picks a display name and is in. No email, no phone, no password ceremony, no server picker. Element Web is **pre-baked** (server hard-set, picker hidden); Element X is reached by a one-tap provisioning deep link.

**Why MAS is included:** Element X (the strategic mobile client, and the one that cleanly handles the **Oct-2026 mandatory device-verification cutover**) requires OIDC/MAS for in-app account creation. For mobile-from-day-one, MAS is effectively required. Its _external_ surface cost is low (it sits behind the proxy, internal); the cost is operational complexity.

**Recovery — v1 is accept-loss (decided).** Matrix accounts live on the _server_, not the device; phone and web are two devices under one account that share keys via cross-signing. So device-loss is only catastrophic for a _single-device_ user with no recovery key. v1 takes the threat-model-clean path:

- **No escrow, ever** (an operator-held key store would break E2EE and be a catastrophic seizure target).
- **Device redundancy is the recovery story** — nudge users to also stay logged in on web; a second verified session survives a lost phone and re-verifies a replacement.
- **Lost your only device → re-onboard as a fresh pseudonym.** Short retention (§10) makes the history loss trivial; rooms are re-joined via a new token.
- **Recovery path left open for v2 (forward-compat hooks baked into v1, since they can't be retrofitted onto distributed cards):** the card carries a dormant per-account **claim secret** — a low-sensitivity claim token, _not_ a decryption key; the server stores `hash(claim secret) → account` at onboarding; the governance log persists `token → organizer → account`; users keep the card as a "re-entry pass." A later v2 flow then does **governance-gated identity recovery** (claim secret + M-of-N moderator sign-off → restore account/rooms, _not_ old history — still no escrow). The single-use registration token burns at onboarding regardless.

**The other UX edge:** device verification becomes mandatory (Oct 2026) → standardize on Element X; pre-verify the moderation bot.

**Key-management UX is _mostly_ tamed in 2026** (auto key backup, invisible first-device verification — a single-device user can go months without a key wall).

## 8. Calls — a deferred Tier-1 module

**Capability is real:** Element Call (MatrixRTC + a LiveKit SFU) gives **E2EE group video/voice**, on by default in Element X and Element Web, with grid/spotlight, screen share, reactions, raise-hand. It's genuinely Discord-ish — but still **formally beta**, **hard to self-host** (multi-service, footgun-prone), **no independent crypto audit**, and missing the polished "voice-channel feel."

**Calls are Tier-1-only, by proof not engineering.** Who-hidden live group calling is impossible against our adversary (Anonymity Trilemma: can't have strong-anonymity + low-latency + low-bandwidth at once; real-time media needs the two that exclude anonymity). Every metadata-private real-time-voice system is research-only; even Signal exposes call IPs + co-presence to its SFU.

**Calls break the two-tier model — they force a third, directly-exposed box.** WebRTC advertises the SFU's real public IP to every participant (media is UDP straight to it); the config literally forbids putting the media port behind a proxy. So group calling adds a **public-IP media node**. The saving grace: it needs **no DB, no inbound path to the core, stores no history** (auth is an outbound token check), so it's compartmentalizable as a separate disposable box whose seizure yields _live-call metadata only_. Costs: **bandwidth jumps ~3–4 orders of magnitude** (a 50-way video call ≈ 1+ Gbps egress, 10 Gbps NIC), and the irreducible metadata is the worst in the stack (participant IPs + live co-presence + timing; self-hosting + Element's hashed pseudonyms don't protect you because you run both ends; WebRTC can't ride Tor).

**Decision: defer to a post-v1 module.** Ship text + files first. Add Element Call later as an **isolated, clearly-labeled Tier-1 module** on its own box, once the core is proven and the exposure is deemed worth it. For Tier-2 "secure voice," the answer is **async encrypted voice notes** (a padded ciphertext blob rides SimpleX/Cairn at who-hidden Tier 2 where a live call never can; cleanest for one-shot drops, since rapid back-and-forth voice notes start to leak call-like timing).

## 9. Compromise → exposure map ("what is actually known if X happens")

E2EE means message **content** is ciphertext server-side in every row. "Metadata" = who/when/which-room, which Matrix keeps in plaintext server-side even for encrypted rooms.

| Scenario                                                       | Adversary learns                                                                                                                                                                                              | Stays protected                                                                                  | What limits it                                                                                                                                                                         |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **1. Core (Synapse+DB) seized or subpoenaed** — _the honeypot_ | Social graph (room memberships); event envelope (sender pseudonym, time, room, type) of every message incl. E2EE; account/device records; **fresh client IPs** (no off-switch); receipts/typing on a live box | Message **content** (E2EE); history older than retention; encrypted cross-signing/backup secrets | Short retention; closed federation; presence/receipts minimized; short IP window; LUKS (powered-off only); jurisdiction; no standing admin. **This is the irreducible Tier-1 ceiling** |
| **2. Front proxy seized**                                      | It's a REDnet front; live connecting-client IPs + SNI; **the WireGuard path to the core (core location may leak)**                                                                                            | Message content; the core's data-at-rest (needs separate core seizure)                           | Rotate fronts; treat as burnable; core has no public IP. Origin-hiding = obfuscation, not seizure-proofing                                                                             |
| **3. Media node seized** _(only if calls)_                     | Live-call participant IPs + co-presence + timing                                                                                                                                                              | Message history, DB (none on this box), call content (E2EE)                                      | Separate disposable box; isolate; no DB/inbound-to-core                                                                                                                                |
| **4. Network observed near a USER**                            | Clearnet TLS to the domain → **participation exposed** (SNI/DNS); content E2EE                                                                                                                                | Message content                                                                                  | Inherent to the approachable clearnet door; innocuous domain; high-risk users use Tier 2                                                                                               |
| **5. User device — BFU** (powered off, locked)                 | Little, with a strong passcode + current OS                                                                                                                                                                   | On-device content & keys (mostly)                                                                | **Power off before risk**; strong passcode; updated OS — far weaker forensics against BFU                                                                                              |
| **6. User device — AFU / unlocked**                            | Decrypted local history (within retention); pseudonym; room/contact list; tokens. Ties pseudonym → person                                                                                                     | Expired/disappeared content; rooms the device wasn't in                                          | Aggressive retention; biometrics-off before checkpoints; Lockdown Mode                                                                                                                 |
| **7. Device live-compromised** (Pegasus)                       | **Everything, real-time** — content, keystrokes, contacts, location, mic/cam                                                                                                                                  | Nothing the user sees or types                                                                   | **None at the app layer.** Device-layer only. _The ceiling REDnet does not defend._                                                                                                    |
| **8. Trusted member turned / informant**                       | Full plaintext of every room they're in; that membership                                                                                                                                                      | Rooms they are _not_ in                                                                          | Vouching at entry; compartmentalize into small need-to-know rooms. _Crypto can't help against an authorized reader_                                                                    |
| **9. Onboarding token intercepted before use**                 | Could redeem the single-use token → unauthorized insider (→ row 8)                                                                                                                                            | Useless once the legit user redeemed it                                                          | Single-use + short expiry; out-of-band card; "already used" is visible                                                                                                                 |

**Nuances the table compresses:**

- **The core is the irreducible honeypot.** E2EE protects content, never the who/when/which-room envelope. This is the Tier-1 ceiling — bound it (retention, closed federation, jurisdiction), don't pretend to erase it, and keep anything that endangers a _named_ person in Tier 2.
- **Cross-signing must stay enforced even though its UI is hidden.** It's the only thing stopping a compromised core from injecting a malicious device to read future E2EE messages. Auto-bootstrap it; never disable it for "simplicity."
- **BFU vs AFU is the single highest-leverage user behavior.** A powered-off phone is dramatically harder to extract than a locked-but-once-unlocked one.
- **Device loss ≠ account loss.** The account + (encrypted) history live on the server; a lost phone costs decryption _access_, not the account — unless it was the user's _only_ device. v1 is accept-loss (re-onboard fresh); a second session (web) is the free recovery; a governance-gated identity-recovery path is reserved for v2 (§7).

## 10. Controls — enforced (system) vs. recommended (user)

### 10a. Enforced (mandatory; users can't misconfigure away)

**Homeserver:** mandatory E2EE, no plaintext rooms; cross-signing auto-bootstrapped + required (invisible but ON); **retention** — 7-day server-wide default, **per-room configurable** (named presets — e.g. Ephemeral 1h / Sensitive 24h / Standard 7d / Reference 30d — are nice-to-have, not mandatory), **media ≤ text**, paired with a **durable-reference surface** (pinned messages / a docs space) so short retention doesn't drive screenshotting; URL previews off; remote-media caching off; presence/typing/receipts minimized (honest: receipts/typing can't be fully disabled server-side); guest access off; public directory off; **closed federation** (whitelist `[]` + no federation listener).

**Identity/onboarding:** single-use, short-expiry, **no-PII** registration tokens; no email/phone; **MAS** for OIDC/Element X; **accept-loss recovery** (no escrow), with dormant v2 recovery hooks reserved on the card (§7).

**Transport/host:** clearnet **front proxy** is the only public face (443); **DB binds localhost**; no federation listener; client-IP retention window short (can't disable); **LUKS**; **no standing admin access** (all changes via the GitOps repo — §11); **no third-party telemetry**, self-hosted client assets, strict CSP; admin plane **WireGuard-only**; media node isolated if calls are enabled.

### 10b. Recommended (teach + nudge in-product)

- **Power the device fully off before checkpoints/borders/raids** (forces BFU — biggest single win).
- Strong non-trivial passcode; consider disabling biometrics before risky situations (jurisdiction-dependent legal nuance; commonly-taught practice, not legal advice).
- Keep OS current; enable Lockdown Mode (iOS) for high-risk users.
- **Treat Tier 1 as semi-public.** Move anything that could endanger a named person to Tier 2.
- **Don't screenshot** (defeats disappearing messages; lands plaintext in the camera roll).
- Store the onboarding card safely; report a lost or already-used token.
- Don't install on a phone you suspect is compromised.

## 11. Governance

Governance is the most _social_ layer — the real threats are informants and coerced organizers, and Matrix concentrates power in whoever holds the server. So split that power up.

- **Four authorities, kept separate:** admission, moderation, infrastructure, crisis. No single role does all four.
- **Admission:** organizers mint single-use invite tokens through a small service with an **append-only log** (who minted what). Distribution by physical card on an **attributable vouch**. A compromised organizer minting a burst of tokens is a visible anomaly — a built-in canary.
- **Revocation (v1):** M-of-N organizers revoke, including bulk-revoke-by-mint-time for a compromised organizer. Branch-aware tooling is v2. Revocation stops _future_ access only — vetting at the door matters more than cleanup.
- **Moderation:** explicit named roles (mods + a small admin set). **Algorithmic/reputation authority is rejected** — gameable by a patient state adversary, concentrates power in high-rep targets, opaque. Diffuse power by drawing more small rooms, not computing a trust score.
- **Infrastructure (GitOps):** the only way to change a deployment is a signed, reviewed commit requiring M-of-N to merge; the stack deploys from it via Ansible. No standing admin access = no live god-credential to coerce.
- **Compartmentalization — the master defense:** most members see only broad rooms; sensitive work happens in small, separately-vouched, need-to-know rooms. Bounds what any one informant or coerced admin can expose.

Honest limit: coercion-_resilient_, not coercion-_proof_. Detecting a compromised insider before damage is a social/operational problem, not a cryptographic one.

## 12. Whitelabel & deployment model

REDnet ships as a **forkable repo**: a deploying org sets jurisdiction, domain, branding, and retention in a config file and runs an **Ansible** playbook that provisions the three-box stack (core + front[s] + optional media). The **GitOps repo is the control plane** (§11) — changes flow through signed, M-of-N-merged commits, not standing logins. This makes REDnet **agnostic** (no target group assumed), keeps jurisdiction a per-deployment choice (§6b), and gives every deployment the same coercion-resistant control posture. The product ships the Tier-1 implementation + honest labeling + tier-doctrine docs; the deploying org supplies the comms discipline (§4).

## 13. State of settlement

### Locked

- **Hosted gold-standard Matrix** (leave-behind/mesh retired — §2).
- Single technical tier (Tier 1 = content secure); ladder above is comms discipline; **co-hosted Tier-2 rejected** (§4).
- **Three-box topology:** hidden core + disposable front(s) + optional isolated media node (§5b).
- Synapse + PostgreSQL (retention needs Synapse); **MAS included** for Element X mobile.
- Onboarding via thin custom web page → pseudonymous no-PII account → auto key-backup → auto room-join; Element Web pre-baked.
- **Recovery: accept-loss for v1** (no escrow; device redundancy / "also log in on web" is the recovery story); governance-gated identity-recovery hooks (dormant claim secret on the card) reserved for v2 (§7).
- **Retention: 7-day default, per-room configurable** (presets optional), media ≤ text, paired with a durable-reference surface (§10).
- **No onion** (hurts non-technical access; the Orbot niche belongs to Tier 2).
- Exposure-footprint minimization across the four axes (§6); no third-party telemetry.
- **Calls deferred** to an isolated post-v1 Tier-1 module; Tier-2 voice = async voice notes (§8).
- Governance: attributed token minting + append-only log; M-of-N revocation; explicit moderation roles; GitOps/no-standing-admin; compartmentalization.
- Whitelabel fork-and-configure deployment (§12).

### Open decisions (yours)

- `TODO` **Calls:** ship the Tier-1 calling module post-v1, or not at all? (Discord-UX appeal vs. the third exposed box + bandwidth.)
- `TODO` **Topology detail:** how many front boxes; same/different jurisdiction for front vs. core vs. media.
- `TODO` **Admission strictness:** liberal (scales fast, more informant risk) vs. strict per-vouch.
- `TODO` **Coercion machinery in v1:** minimum (peer lockout + revocation) vs. add duress codes / canaries now.
- `TODO` **matrix-viewer preview:** include in v1 or defer.

### Spikes (verify before/within build — hands-on, not research)

- `SPIKE` Stand up the stack and **load-test ~250 users** on the §6c sizing; confirm real DB growth under the chosen retention.
- `SPIKE` Build the **custom onboarding page** end-to-end (token-in-URL → pseudonymous account → auto key-backup → auto-join) and **get it security-reviewed** (it touches account creation + E2EE bootstrap for at-risk users).
- `SPIKE` Verify **Synapse retention actually purges encrypted-room events** at the chosen window (historically flaky), and characterize the **device-local-history residual** (a device can out-retain the server; does client-side expiry help?).
- `SPIKE` Validate the dormant **v2 recovery hooks** (claim secret on card + stored hash + governance-log mapping) add no v1 leak or weakness.
- `SPIKE` Validate the **two-tier front→core** WireGuard model + front rotation/failover + tripwire alerting.
- `SPIKE` Confirm **Element X** provisioning deep-link + MAS registration UX end-to-end on iOS and Android.
- `SPIKE` (If calls) self-host Element Call and verify reliability + isolation of the media node.

---

_This document supersedes the leave-behind/mesh design. The two gating decisions (recovery model, retention) are settled; the remaining §13 open decisions are deferrable or per-deployment. The architecture is ready for a reference implementation, gated only by the §13 spikes._
