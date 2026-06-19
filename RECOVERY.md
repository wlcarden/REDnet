# REDnet — Governance-Gated Recovery-Key Escrow (design exploration)

> Status: **design exploration**, not a build spec. It maps the construction, the threat analysis,
> the component inventory, and the open decisions so we can choose deliberately before writing code.
> This is the single most cryptographically novel piece of REDnet — everything else leverages
> existing Matrix/Synapse/Draupnir; this we assemble ourselves.

## 0. Lead with the hard parts

Three problems make this more than "encrypt the key and store it." Naming them up front because they,
not the happy-path crypto, decide whether this is buildable and approachable:

1. **Fresh-device trust bootstrap.** Recovery happens _because_ the member lost their device. The new
   device is unverified — but the whole point of the recovery key is to establish that trust. So shares
   can't simply be "sent to the member's device": the moderators must verify the human out-of-band
   before releasing anything. The cryptography is the _easy_ half; the human verification workflow is
   the security backstop.
2. **The card is a thing to lose.** A member-held factor is what stops a coerced moderator quorum from
   reading everyone. But "lose your device _and_ your card → unrecoverable," and asking a non-technical
   user to safeguard a card cuts against the Signal-level UX bar. This is a real tension, not a detail.
3. **Moderators get arrested (first-class, per the threat model).** When a moderator is compromised,
   their share is potentially in adversary hands. Fully healing requires re-randomizing the escrow —
   and because the escrow is bound to the member's card, **healing requires the _member_ to re-escrow**,
   not just an admin action. The lifecycle, not the construction, is where the work is.

## 1. What we're escrowing, and why it's the crown jewel

The verified onboarding (`prototype/onboarding/onboard.mjs`, milestone A) generates a Matrix **4S
secret-storage recovery key** `K`. `K` decrypts the user's `account_data` secrets:

- the **cross-signing private keys** (master/self-signing/user-signing) — identity; whoever holds them
  can impersonate the user's device-verification, and
- the **key-backup decryption key** — unlocks the server-side megolm key backup, i.e. **every message
  the user has ever backed up**.

So `K` is the one secret that turns "encrypted history on a seized server" into plaintext. Escrowing it
badly would hand an adversary exactly what the rest of the design works to deny them. The escrow's
prime directive: **a fully seized core must yield nothing usable.**

## 2. The access structure we want

Recovery of `K` should require **(the member's card `S`) AND (M-of-N moderators)** — both, not either.
Why this exact structure, justified against the threat model:

| If we used…                  | Failure under the model                                                                                                                                            |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Device-bound (no escrow)** | No recovery at all. Lose device → lose history + identity. Safe, but fails the "organizers need continuity" goal.                                                  |
| **Card-only escrow**         | Server is seizable (given). Server blob **+** a coerced card → that member's history. Card becomes as sensitive as `K`.                                            |
| **M-of-N moderators only**   | A coerced/compromised moderator quorum reads **everyone's** history. Catastrophic given ICE can coerce moderators.                                                 |
| **Card AND M-of-N** ✅       | Server seizure → nothing. Card seizure alone → nothing. Coerced quorum alone → nothing. Only (specific member's card) + (M mods) recovers, and only _that_ member. |

The card converts "compromise M moderators → read everyone" into "compromise M moderators **and** coerce
each specific member → read that member." That per-member binding is the property worth the complexity.

## 3. The construction

Vetted primitives only (Shamir from a reviewed library; libsodium/age for the envelope) — **no bespoke
crypto**. Per-member, at onboarding, on the member's trusted device:

```
K   = the 4S recovery key (to be escrowed)
S   = card secret: fresh 256-bit random, shown to the member ONCE as their recovery card (QR/base58)
E   = escrow key: fresh 256-bit random
DK  = HKDF(salt, ikm = S ‖ E)          # derivation key needs BOTH factors
Blob= AEAD_seal(DK, nonce, K)          # the wrapped recovery key

shares[1..N] = Shamir_split(E, threshold=M, shares=N)   # M-of-N over the moderator set
enc_share[i] = sealed_box(moderator_pubkey[i], shares[i])  # only moderator i can open theirs
```

**Stored on the core (all ciphertext it cannot read):** `Blob, nonce, salt, {enc_share[i]}, policy
{M, N, moderator_keyids, escrow_version}`. The core never sees `S`, `E`, `DK`, or `K`.

**Recovery:** M moderators each open `enc_share[i]` with their _own_ private key → submit shares →
reconstruct `E`; member supplies `S` from the card → `DK = HKDF(salt, S‖E)` → `K = AEAD_open(DK,
nonce, Blob)` → feed `K` into Element's stock 4S restore. History + identity return. **`K` is
reconstructed on the member's new device; it never exists server-side.**

`S` and `E` are wiped from the onboarding device after the escrow is built; `S` lives only on the card.

## 4. Threat analysis (the payoff) — ⚠️ READ BY MODE

REDnet ships **moderators-only by default**; the member passphrase is **opt-in** (§8). The two modes have
**very different** seizure properties — read the right column. (Earlier drafts of this table described a
card-AND-quorum construction and over-stated the default's protection; corrected here per the security review.)

| Adversary obtains                              | **moderators-only (default)**                                                               | **passphrase + M-of-N (opt-in)**              |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------- | --------------------------------------------- |
| Seized core alone (Blob + enc_shares + policy) | **No** — no moderator keys to open shares                                                   | **No** — also no passphrase                   |
| < M moderators (colluding)                     | **No** — Shamir threshold                                                                   | **No** — Shamir threshold                     |
| **M moderators + seized core**                 | **⚠️ YES — for EVERY member** (M shares == the wrap key; the core supplies the Blob)        | **No** — still need each member's passphrase  |
| **M moderators alone**                         | **⚠️ YES — for EVERY member**                                                               | **No** — still need the passphrase            |
| M moderators + that member's passphrase        | n/a (no passphrase in this mode)                                                            | **Yes** — that one member (the intended path) |
| Member's seized live device                    | N/A — a logged-in device always holds `K` (a device-security problem, separate from escrow) | same                                          |

**The honest headline:** in the **default** mode, a coerced/arrested **M-moderator quorum — with or without
the seized core — recovers the cross-signing identity + full backup history of _every_ member.** That is the
"compromise M moderators → read everyone" outcome §2 weighs; moderators-only **accepts** it for approachability,
backstopped by the §10 revocation machinery — which lowers the _probability_ of a quorum compromise, **not its
blast radius**. The clean "seizing the core yields nothing" property holds **only for passphrase-mode members**;
for default members it holds **only as long as the moderator quorum is never compromised**. Steer high-risk
members to the opt-in passphrase (§8) — it is the only thing that caps the blast radius per member.

## 5. What we'd build (component inventory)

| #   | Component                                                                                                                                                                                                                                                                                                          | Where                            | Effort / risk                         |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------- | ------------------------------------- |
| A   | **Crypto module** — Shamir + ECIES-to-mod-keys + HKDF + AEAD + passphrase layer + revocation. ✅ **VERIFIED on P-256** (`spikes/06-moderator-keys/`, PASS) through a secure-element ECDH-only interface; Curve25519 variant in `spikes/05`. Production: pin an audited Shamir + the HKDF (not the spike's SHA256). | shared lib                       | ✅ proven; **risk: audited Shamir**   |
| B   | **Escrow store + API** — dumb ciphertext store keyed by user; create-at-onboarding, fetch-for-recovery, record approvals. **Decided: Matrix-native** (blob in account_data / a dedicated room, approvals coordinated by a keyless Draupnir-style bot) for exposure-footprint minimization.                         | core                             | Medium                                |
| C   | **Moderator PKI** — **P-256** keypair per moderator, key bound to the secure element (binding decision: native keystore vs WebAuthn-PRF, §5b), publish pubkeys to clients, **rotation/revocation** (the arrested-mod path).                                                                                        | core + mod devices               | **High — the hard operational piece** |
| D   | **Moderator approval tool** — client-side, holds the mod private key, shows pending requests, supports out-of-band identity verification, decrypts + releases the share. A bot can coordinate but **must not hold keys**.                                                                                          | new mini-client / Element widget | High                                  |
| E   | **Onboarding escrow creation** — extend the CryptoSetupExtensions module (`element-web/rednet-module/`): fetch mod set + policy, build the escrow, display the card, wipe `S`/`E`.                                                                                                                                 | Element fork                     | Medium                                |
| F   | **Member recovery flow** — initiate, present card, bind the new device's pubkey to the verified session, collect M shares, reconstruct, restore 4S.                                                                                                                                                                | Element fork                     | Medium-High                           |
| G   | **Lifecycle/policy** — choose M,N; tie the moderator set to the governance trust graph; proactive re-sharing; "your escrow used a revoked moderator → please re-escrow" prompts.                                                                                                                                   | core + clients                   | Medium                                |

The Matrix side is mercifully thin: once `K` is reconstructed, recovery is **stock 4S restore**. The
bulk of the work is C/D (moderator PKI + tooling) and the F human-verification workflow.

### 5b. Secure-element binding — the open decision (changes the sealing)

Spike 06 proved the crypto on a P-256 key that does **only ECDH, no extraction**. Binding that key to
real non-extractable hardware splits two ways, and the split changes both the moderator UX and the seal:

- **Native keystore** (iOS Secure Enclave / Android Keystore): does P-256 ECDH directly → clean ECIES
  exactly as verified. Cost: the moderator's key lives in a **native app** (Element X), so approvals
  happen on their phone. The stronger, verified path.
- **WebAuthn PRF**: works in a **browser** (no native app), but the authenticator yields a _symmetric_
  PRF secret, not an ECDH key — so the seal becomes a symmetric wrap, **not** the P-256 ECIES proven in
  Spike 06 (it would need its own verification).

Saying "P-256 secure-element" points at **native keystore**. Settle this before building the moderator
approval tool (D), since it decides the platform and the sealing.

## 6. The moderator-churn wrinkle (important, easy to miss)

Because `Blob` is bound to `S‖E`, you **cannot fully re-key the moderator set without the member**: a
removed moderator already holds a valid share of the _same_ `E`, so re-distributing `E` doesn't revoke
them — you must change `E`, which changes `DK`, which needs `S` (the card). Consequences:

- **Proactive secret sharing (PSS)** re-randomizes shares of the same `E` to limit _creeping_ compromise,
  but does **not** help once a specific moderator is known-compromised (they kept their old share).
- A **known** moderator compromise (arrest) → affected members must **re-escrow** next time they're
  online (device + card present). The system must detect "your escrow references a revoked moderator"
  and nudge re-escrow. This is the "trim the corrupted trust branch" idea from the governance design,
  made concrete at the crypto layer.

This is acceptable but it must be designed in from day one, not bolted on.

## 7. Phasing (each phase is independently shippable) — and it tracks community size

Recovery scales with the community; the phases ARE the size regimes (see §11):

1. **Phase 0 — device-bound.** `custodyRecoveryKey()` discards `K`. No recovery; server-safe. The honest
   default before Phase 1 ships.
2. **Phase 1 — self-held passphrase. ✅ BROWSER E2E PROVEN (2/2 PASS, 2026-06-19).** Native Matrix 4S
   keyed by a 7-word EFF diceware passphrase (~90 bits). The CryptoSetupExtensions module
   (`deploy/element-web/rednet-module/`) drives `silentBootstrap` + `recoverWithPassphrase` silently.
   Works at ANY size incl. N=1; no moderator infra. Proven against live stack: fresh account's generated
   passphrase recovers identity + key backup on a fresh browser context. Server-seizure-safe; the
   passphrase must be diceware-grade (§8). **This is the bootstrap recovery model.**
3. **Phase 2 — governance gate.** Add the Shamir/M-of-N moderator layer (§3, crypto proven in
   `spikes/05-recovery-escrow/`) + tooling (§5 C/D/F) + churn/revocation (§6, §10). The growth feature —
   switched on once the trust graph has ≥3 organizers; the heavy lift.

Phase 1 is not a throwaway interim: for a small or solo community it's the right answer, full stop. The
moderator quorum is something a community **grows into**, not something the founder needs on day one.

## 8. Decisions — current leaning

1. **Member factor: moderators-only by DEFAULT, opt-in passphrase per member** (working assumption).
   Not "card vs. none" — the real fork is "any member factor, or none," and the answer is _per member_.
   Default is moderators-only (nothing to carry — meets the UX bar); a higher-risk member can opt into
   a **memorized recovery passphrase** that ANDs with the quorum, capping the blast radius of a coerced
   quorum (Spike 05 proves both modes are one record format + a `mode` flag). The passphrase replaces
   the physical _card_ (a thing to lose) with the card's _function_. Caveat: no trusted hardware to
   rate-limit guesses ⇒ the passphrase must be **diceware-grade**, not a short PIN.
2. **M and N** + **who the moderators are** — bind to the governance trust graph? Typical N=5–7, M=3.
   Higher M = safer against coercion, more friction to recover. _Still open._
3. **Matrix-native vs. micro-service** for the escrow store + approval coordination (§5 B). _Still open._
4. **Passphrase UX** for opt-in members — generated diceware shown once? member-chosen with a strength
   floor? _Still open, on the approachability line._
5. **Phase target** — ship Phase 0 now and treat the full build as a tracked sub-project, or go
   straight at it? _Still open._

## 9. Verification spike — DONE ✅ (`spikes/05-recovery-escrow/`, PASS 10/10)

Proved the load-bearing crypto for BOTH designs + revocation, with vetted primitives (PyCryptodome
Shamir, PyNaCl SealedBox/SecretBox/Argon2id):

- (a) moderators-only: 3-of-5 recovers; 2 blocks; record-alone blocks.
- (b) passphrase + M-of-N: 3+phrase recovers; 3+**wrong**/`**no**` phrase blocks; 2+phrase blocks.
- **The comparison, made concrete:** the same compromised 3-mod quorum **recovers** under (a) and is
  **blocked** under (b) — the passphrase is exactly the blast-radius cap.
- Revocation: after a proactive re-share, the arrested mod's OLD share + 2 NEW shares **blocks**; 3 NEW
  shares recover — i.e. a fresh polynomial invalidates the revoked share.

Same confidence for escrow that Spikes 01/03/04 gave for retention/two-tier/backup, before we invest in
the moderator PKI and tooling. Caveats (re-deal vs. distributed PSS; revocation can't reach backward;
spike KDF/params) are in the spike README.

## 10. Moderator revocation — break-glass & dead-man (the moderators-only safety net)

Moderators-only trades the member-factor blast-radius cap for approachability, so the **revocation
machinery is load-bearing**, not optional. The honest design (revocation limits _probability/window_;
it cannot reach backward to un-leak an already-extracted share):

- **Non-extractable moderator keys** (hardware / passkey / secure enclave). A seized phone yields no
  key — the single biggest mitigation for arrest, and it makes manual break-glass far less critical.
- **Dead-man's switch.** Auto-revoke + re-share if a moderator misses _K_ liveness check-ins. Handles
  arrest (they can't self-flag — the phone is gone at the moment of arrest) better than a manual button.
- **Manual break-glass + duress code.** For the cases where the moderator _can_ signal (coerced but
  still operating): a signed "revoke me" / a covert duress credential that flags the share burned.
- **Mandatory pairing with proactive re-share.** Every revocation triggers the remaining quorum to
  refresh shares onto a fresh polynomial and delete the old ones (Spike 05's verified property). De-auth
  _alone_ is cosmetic — only the re-share actually kills the revoked share.
- **Accounting goal:** keep _compromised-and-still-counted_ moderators **< M** over time. Shamir already
  makes any single compromise harmless; this machinery stops the count from creeping to M.
- **Residual:** if M are compromised _before_ detection, history is exposed and re-share can't heal it
  (only re-keying MK can, which reconstructs K). This is the price of dropping the per-member factor —
  and the reason the opt-in passphrase exists for members who can't accept it.

## 11. Recovery scales with community size (the "bootstrap from 1" model)

A community of 1 has no moderators, so the M-of-N quorum is **undefined** at the start. That's not a
problem to engineer around — it means the moderator escrow is something a community **grows into**:

| Community         | Recovery model                                                                                 | Infra                   |
| ----------------- | ---------------------------------------------------------------------------------------------- | ----------------------- |
| **1 (founder)**   | Self-held passphrase (Phase 1) — essentially stock 4S, made invisible by the silent onboarding | none                    |
| **2–handful**     | Still self-held passphrase (a 2-of-2 quorum has no fault tolerance; 1-of-2 is insecure)        | none                    |
| **≥3 organizers** | Moderator quorum switches on (Phase 2): default moderators-only + opt-in passphrase, M-of-N    | mod PKI + keyless bot   |
| **growing**       | Re-share to more moderators, raise M                                                           | proactive re-share (§6) |

**M/N policy when the quorum is on:** floor at **N≥3, M≥2** (M≥2 = no single moderator acts alone;
N>M = tolerate one being unavailable/arrested), then **M = majority = floor(N/2)+1** as N grows.
Caution for this threat model: don't push M too high — moderators get arrested, and if recovery needs
more of them than are reachable, legitimate recovery becomes impossible. Majority-of-a-small-N
(2-of-3, 3-of-5) balances coercion-resistance against the reality that quorum members are themselves
targets. The moderator set = the high-trust organizers in the governance trust graph, which only
exists once the community has grown.

**The elegant inversion:** the member passphrase matters _most_ when the community is smallest (at N=1
it's the only recovery; at small N the quorum is easy to compromise so the impact-cap is critical), and
the moderator quorum matters _most_ when it's largest. So the _default itself_ shifts from "passphrase
(no quorum yet)" to "moderators-only (robust quorum)" as the community ages. You don't choose one model
forever — the community grows through them.

### The quorum is a curated committee, NOT proportional to the community

The trap to avoid: "more members → more moderators → bigger N." Shamir punishes that — a fixed threshold
over a larger pool is _easier_ to compromise (any M of more targets), and raising M with N makes recovery
harder (gather more people, and yours get arrested). You can't scale N with the community. So the
recovery quorum is a **small, bounded, curated committee** of the most-trusted organizers that **stops
growing** while the community keeps growing. A 10,000-person network runs a 5-of-7 quorum.

Bounded progression (recommended defaults; the governance can tune):

| Trusted + available organizers | Quorum                         | Why                                                       |
| ------------------------------ | ------------------------------ | --------------------------------------------------------- |
| 0–2                            | **none** — self-passphrase     | 2-of-2 has no fault tolerance; 1-of-2 is insecure         |
| 3–4                            | **2-of-3**                     | first viable: no single mod acts alone, tolerates 1 loss  |
| 5–6                            | **3-of-5**                     | majority; more arrest-tolerance                           |
| 7+                             | **4-of-7 / 5-of-7, then HOLD** | ceiling ~5-of-9; beyond that, curate membership, not size |

Two selection rules weigh as much as the numbers: **jurisdictional spread** (one raid mustn't grab M of
them) and **availability** (an arrested moderator can't approve, so M must stay reachable). Quorum
changes (adding the 4th/5th organizer, swapping someone out) are **re-share events**, verified to work —
the threshold rises, old/new shares can't be mixed (`spikes/08-quorum-growth/`, PASS), with the §6
deletion caveat. The moderator set is drawn from the **governance trust graph** (the high-trust
organizers), so "trim the corrupted branch" and "remove a recovery moderator" are the same action.

## 12. Phase-2 build status + the recovery-coordination handshake

### Verified (reference implementation in `spikes/`, Python)

The Phase-2 **crypto and storage are proven end-to-end** — but in the spikes' Python, NOT in the
TypeScript client. That distinction matters (see "To build" below):

| Verified                                                                                                                | Spike           |
| ----------------------------------------------------------------------------------------------------------------------- | --------------- |
| escrow construction: moderators-only + opt-in passphrase + revocation (re-share kills old shares)                       | 05 (PASS 10/10) |
| the same on **P-256 secure-element** keys (ECDH-only, no extraction)                                                    | 06 (PASS 7/7)   |
| **Matrix-native** store + producer round-trip (directory as room state, record in `account_data`, opaque to the server) | 07 (PASS 6/6)   |

### The recovery-coordination handshake (design — components D + F)

This is the part Spike 07 deliberately skipped (it handed the shares directly). The flow:

1. **Fresh device** generates an ephemeral P-256 keypair and posts a **recovery request** (its ephemeral
   pubkey + a member-identity claim) into a Matrix recovery room, coordinated by the **keyless bot**.
2. Each **moderator** is notified, **verifies the human out-of-band** (the open decision below), then
   uses their secure-element key to unseal _their_ share and **re-seals it to the fresh device's
   ephemeral pubkey** (ECIES, Spike 06). The bot relays ciphertext; it never holds a key.
3. The **fresh device** collects **M** re-sealed shares, reconstructs the wrap key, unwraps `K`, and runs
   stock 4S restore. `K` exists only on the member's new device — never the bot, never the server.

The crypto here is the same primitives already verified; what's genuinely unsolved is step 2's human gate.

### The fresh-device-trust / human-verification protocol — DECIDED: mechanism, not policy

Moderators-only has no member factor, so what stops an impostor on a fresh device is how rigorously the
moderators verify the human before re-sealing. **Decision: the software owns the _mechanism_, the
moderators own the _policy_.**

- **Mechanism (the software provides, always available):** bind the new device's ephemeral pubkey to the
  verified session — the member reads a short code / shows a QR that the moderator confirms in their
  approval tool. Without this, whatever social check happened doesn't actually protect the share delivery.
  The approval tool **offers** this step; it does not force a rigid flow.
- **Policy (moderators own, flexible by design):** _how_ they confirm the human is real is left to the
  quorum's own social mechanisms — software can't anticipate them. REDnet only **recommends**: live
  known-channel (video/voice they already trust) as the default, in-person as an escalation for the
  highest-risk recoveries, and **never a pre-registered challenge as the sole gate** (that's a weak member
  factor — the thing moderators-only chose to avoid; high-risk members use the opt-in passphrase instead).

This deliberately keeps verification flexible: the rigor scales with the quorum's judgment of the risk,
backstopped cryptographically by the opt-in passphrase for members who can't rely on social verification.

### ⚠️ Required hardening — authenticate the record + directory (security review finding #2)

Spikes 05–08 prove recovery against an HONEST core. **Spike 09 now proves the defense against a MALICIOUS
core** (items 1–3 below — PASS 8/8): with AAD binding + an org-signed directory, directory substitution,
policy downgrade, record replay, and version rollback all BLOCK; only the org-signed directory with the
correctly-bound context recovers. Items 4–5 remain before a port ships. The port MUST:

1. ✅ **PROVEN (spike 09)** — **Bind `{mode, policy{M,N}, directory-version, member-id}` into the AEAD
   associated data**, so a substituted or policy-downgraded record (e.g. served as M=1) fails the tag at recovery.
2. ✅ **PROVEN (spike 09)** — **Authenticate the moderator directory out-of-band** — sign it with an offline
   organizer key (Ed25519; its PUBLIC key pinned into the client, NOT fetched from the server). Never trust the
   directory as mere server-stored room state. This is the crypto half of the §0 fresh-device-trust problem.
3. ✅ **PROVEN (spike 09)** — **malicious-core tests**: a downgraded/re-sealed record + a substituted
   directory are served and recovery REJECTS them (8/8 — directory substitution ×3, downgrade, replay, rollback).
4. ✅ **PROVEN (spike 06 + test-vectors)** — **Validate the ECIES ephemeral point on unseal**. `_validate_point()`
   in spike 06 performs explicit on-curve + non-identity checks (P-256 curve equation, coordinate bounds)
   before ECDH — defense-in-depth for ports where the ECDH implementation may skip validation (secure-element
   syscalls). Four negative test vectors in `spikes/test-vectors/primitives.json` (`ecies_unseal_reject`):
   off-curve (y-bit-flip), identity (0,0), truncated, coordinates >= field prime. Spike 06: 11/11 PASS.
5. ✅ **DONE (test-vectors)** — **Test-vector oracle regenerated to the HARDENED (AAD-bound) construction**.
   `ecies_seal` in `primitives.json` now uses `aad = canonical{dir_version, m, member, mode, n}` — a port
   that passes `aad=None` fails the GCM tag. Self-check in `export.py` explicitly verifies `aad=None` rejects.

### To build (NOT yet done — deliberately not shipped as unverified code)

- **TS port of the crypto** into the Element fork (WebCrypto P-256 ECIES + an _audited_ JS Shamir lib),
  cross-checked against test vectors exported from spikes 05–07, **with the AAD/directory authentication
  above**. Not written yet: porting security crypto to an untested target would overstate "done."
- **Moderator approval tool** (D) — native app, secure-element binding (§5b decision: native keystore).
- **Coordination bot** (keyless) + the recovery room protocol (F).
- **Lifecycle** (G) — re-escrow prompts when a member's escrow references a revoked moderator.
