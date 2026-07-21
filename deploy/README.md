# REDnet deployment stack

The runnable, hardened REDnet deployment. Assembles the components proven in `../spikes/` and `../prototype/` into one coherent stack with production hardening, parameterized by a single config file.

> **Status:** all checklist items landed. **Verified running** in-sandbox: core+front stack, system
> rooms + auto-join, backup/restore + restic + heartbeat, Draupnir moderation, Prometheus/Grafana
> monitoring. **Scaffolded** (build/provision happens at deploy time, can't run in-sandbox): the
> Element Web soft fork (`element-web/`) and the two-host Ansible wrapper (`ansible/`). Next is a real
> deploy-target dry-run: build the client, run the Ansible against throwaway hosts, finalize the
> onboarding patch + recovery-key custody. See the checklist + the per-directory READMEs.

## What this is

- **Single-host** (dev / Raspberry Pi / small deploy): everything runs in one `docker compose`; only Caddy (the FRONT role) publishes a port.
- **Production** is the _same services_ split across two boxes: Caddy on a disposable FRONT box, the rest on a no-public-IP CORE box, with WireGuard between them (`ARCHITECTURE.md §1-2`). The compose here is the canonical service+config definition both topologies use.

## Quick start

```bash
cp rednet.env.example rednet.env     # edit REDNET_DOMAIN etc.
./deploy.sh                           # full first-time setup — stack, rooms, governance, operator account
```

`deploy.sh` is the single entry point for first-time deployment. It checks prerequisites, renders
configs, starts the stack, chains the full bootstrap sequence, builds Element Web, creates your
admin account, posts setup instructions to the rooms, and prints credentials. Pass `--operator <name>`
for non-interactive use. Under the hood it calls `setup.sh` (secrets, configs, health check) followed
by each bootstrap script in dependency order.

## Config surface (`rednet.env`)

The whole deployer-facing knob set. `REDNET_DOMAIN` is **immutable after first deploy** (Matrix `server_name`).

## Hardening applied (from `SPEC §4`)

Mandatory E2EE · closed federation (no listener, whitelist `[]`) · MAS-delegated auth (no native login/registration) · **presence off** · URL previews off · short retention (`REDNET_RETENTION_DAYS`) for events + media · `user_ips_max_age` short · redaction scrub fast · tightened rate limits · `/_synapse/admin` denied at the front.

## Admitting users: registration is INVITE-TOKEN ONLY (SPEC §5)

Registration is gated: MAS is configured `password_registration_token_required: true`, so **no one can
self-register** without a token an organizer minted (verified by setup.sh's self-check; a token-less
registration creates no account). The append-only list of minted tokens is the **coercion canary**
(DESIGN §7/§11): every admitted member traces to who vouched for them.

Mint a **single-use** registration token (organizer action):

```bash
# --usage-limit 1 is REQUIRED for single-use: omit it and MAS issues an
# UNLIMITED-use token, so one leaked/coerced card can register many accounts
# under a single vouch hash. mint-invite.sh (below) always passes it for you.
docker compose exec mas mas-cli manage issue-user-registration-token \
  --usage-limit 1 --expires-in 604800 --config /config.yaml
#   -> Created user registration token: ZF0PNzXZaXy3
```

Give that token to the invitee. They can register via the MAS registration page at the front, or use
the **attributed QR invite flow** (preferred — see Governance tooling below):

```bash
./mint-invite.sh --label "Maria, Tuesday group"       # mint + QR card + vouch record
./mint-invite.sh --label "workshop batch" --batch 5    # mint 5 attributed invites
./mint-invite.sh --label "existing" --token TOKEN      # card for an already-minted token
```

The script produces a branded HTML card in `invites/` (one per token), records the vouch in
`#vouch-log` + `vouch.jsonl`, and attributes the invite to you (`REDNET_OPERATOR`). Open the card
in a browser and print. The QR encodes `https://DOMAIN/join#TOKEN`, which loads a security-aware
onboarding flow: handle OPSEC guidance, the token, registration steps, and post-setup instructions.
The landing page is served by the Element container at `/join`. After setup, new members are
linked to `/member-guide` for day-to-day usage: messaging, encryption, privacy practices,
device management, and how to report problems.

Operators are bootstrapped with `bootstrap-operator.sh` (creates MAS account, invites to all
rooms, sets power levels, adds to Draupnir management — one command).

## Build checklist

- [x] Core+front stack (Synapse hardened + MAS delegated + Postgres + Caddy two-tier split)
- [x] Config surface + secret generation + self-check
- [x] Space + channels + auto-join (`bootstrap-rooms.sh`: creates a Space + 4 E2EE channels; `auto_join_rooms` fires for interactive registration but **not** for `mas register-user` CLI users; the module's `joinStarterRooms()` handles interactive; `invite-to-community.sh` handles CLI-provisioned users)
- [x] Backup capture + restore runbook (`backup.sh`/`restore.sh`, per Spike 04: captures both DBs + MAS key + signing key + media; restore mirrors the verified ownership-fix drill)
- [x] Draupnir moderation bot (`bootstrap-draupnir.sh`, verified: online against MAS-delegated Synapse, monitors rooms, replies to operator `!draupnir` commands; acts on E2EE rooms without decrypting them). _Retention-preset chat command deferred; it's a custom Draupnir extension, not native; retention is set at room creation today._
- [x] `push.include_content: false` (metadata hygiene, verified in self-check) + Synapse metrics listener (CORE-internal)
- [x] Prometheus + Grafana + Pushgateway + **Alertmanager** (`monitoring` profile, localhost/WireGuard-only, verified: scrapes Synapse, alert rules load, alerts route through Alertmanager to a receiver). Set the real out-of-band channel in `monitoring/alertmanager.yml` before production.
- [x] restic transport wrapper + backup heartbeat (`backup.sh`, verified: restic snapshot created, heartbeat reaches Prometheus and clears `BackupHeartbeat*` alerts)
- [x] Element Web **soft fork** build context (`element-web/`: config locks to our server + CryptoSetupExtensions module + integration.patch + Dockerfile + `web` profile, front proxies to it). _Build context only: the webpack build runs at deploy time (`element-web/build.sh`). Phase-1 passphrase recovery: browser E2E proven (2/2 PASS, 2026-06-19), silent onboarding + passphrase recovery work end-to-end._
- [x] Ansible two-host wrapper (`ansible/`: CORE+FRONT split, WireGuard overlay, front Caddyfile, **front-tripwire** seizure alert + heartbeat). _Scaffold: YAML/compose validated; not run against real hosts._
- [x] QR-card onboarding (`mint-invite.sh` + `/join` landing page + security-aware onboarding flow + `/member-guide`, `/moderator-guide`, `/operator-guide` role-level guides). _Scaffold: needs live-stack validation._
- [x] Phase-2 recovery lifecycle (`escrow-lifecycle.ts` + `directory.ts` + `events.ts`, 47/47 crypto+lifecycle tests). _Moderator approval tool + coordination bot not built._
- [x] Group calls module (`bootstrap-calls.sh`, LiveKit + JWT + Caddy + Element config, `calls` profile). _Scaffold: needs live-stack + production media node._
- [x] matrix-viewer public preview (`bootstrap-viewer.sh`, `viewer` profile). _Scaffold: OFF by default, conflicts with mandatory E2EE (SPEC §11)._
- [x] Governance tooling: attributed invite minting (`mint-invite.sh`), vouch provenance (`vouch-tree.sh`, `confirm-vouch.sh`), compartment management (`create-compartment.sh`, `set-role.sh`), coercion canary (`audit-vouches.sh`), member/bulk revocation (`revoke-member.sh`), in-client governance widget (Matrix Widget API, `element-web/governance-widget/`), governance bot (`bootstrap-gov-bot.sh`, `gov-bot/`, `governance` profile — `!gov` commands for report/confirm/revoke/role/audit). 4-tier role model: Member (PL0), Moderator (PL50), Organizer (PL75), Admin (PL100). _Scaffold: needs live-stack validation._

## ⚠️ Before production

Image digests are pinned (PRODUCTION.md §2). Move the front to a separate box. Run backups (`backup.sh` with `RESTIC_REPOSITORY`/`RESTIC_PASSWORD` set, repo password held off-core) + monitoring (`--profile monitoring`) + the WireGuard tunnel. Run the Spike 04 restore drill. Bootstrap operators with `bootstrap-operator.sh` (creates account, invites to all rooms, sets power levels, adds to Draupnir management room). Then `!draupnir rooms add` the community rooms. Run `invite-to-community.sh` for any CLI-provisioned users. Fill in the public `/reference` page (`element-web/branding/reference.html`) — it's served live by the front (edit + save, no rebuild).

## Operational profiles

```bash
./deploy.sh                                  # full first-time setup (calls everything below)
# --- or individually: ---
./setup.sh                                   # core+front stack (generates secrets, starts services)
./bootstrap-rooms.sh                          # community space + starter channels
./bootstrap-governance.sh                     # #vouch-log + #governance (organizer audit trail)
./bootstrap-draupnir.sh                       # + moderation (compose --profile moderation)
./bootstrap-gov-bot.sh                        # + governance bot (compose --profile governance)
./bootstrap-operator.sh alice                 # create operator (admin, all rooms, Draupnir)
./bootstrap-calls.sh                          # + group calls (compose --profile calls; DESIGN §8)
docker compose --profile monitoring up -d     # + Prometheus/Grafana/Pushgateway/Alertmanager (localhost-bound)
RESTIC_REPOSITORY=s3:... RESTIC_PASSWORD=... ./backup.sh   # encrypted off-box backup + heartbeat
```

### Operator bootstrap

Create and provision operator accounts in one pass. Run after `setup.sh` + `bootstrap-rooms.sh`.
The system account handles all invites and power-level assignments.

```bash
# First operator (full admin):
./bootstrap-operator.sh alice

# Scoped moderator (PL50 instead of PL100):
./bootstrap-operator.sh bob --role moderator

# Existing account (skip MAS registration):
./bootstrap-operator.sh carol --existing

# Skip Draupnir management room:
./bootstrap-operator.sh dave --role moderator --no-draupnir
```

The script creates the MAS account, invites the user to all community + governance rooms,
sets power levels, and optionally adds them to `#rednet-mod` (Draupnir management). The
operator's temporary password is printed once — they should change it on first login.

### Governance tooling (DESIGN §11)

Attributed invite minting, vouch provenance, compartmented sub-spaces, and coercion
canary. All actions logged to `#vouch-log` (append-only, E2EE, ≤30 days like every room) and to
**`vouch.jsonl` — the permanent on-disk audit trail**, immune to Matrix retention.

```bash
# Set your operator identity (or add to rednet.env):
export REDNET_OPERATOR=@yourname:example.org

# Mint an attributed invite (voucher = you, automatically):
./mint-invite.sh --label "Maria, Tuesday group"
./mint-invite.sh --label "workshop batch" --batch 5
./mint-invite.sh --label "for Bob's contact" --voucher @bob   # override: Bob is vouching

# Confirm a new member's vouch (posts join announcement to #welcome):
./confirm-vouch.sh @maria

# Query the provenance graph:
./vouch-tree.sh @maria                  # who vouched for this person?
./vouch-tree.sh --voucher @organizer    # everyone they vouched for
./vouch-tree.sh --tree                  # full graph
./vouch-tree.sh --stats                 # per-voucher summary

# Create a compartmented sub-space (DESIGN §11 compartmentalization):
./create-compartment.sh "Ops Team" --rooms "ops-general,ops-planning" --moderators "@alice,@bob"
./create-compartment.sh "Regional NW" --rooms "nw-general" --join-rule restricted

# Assign scoped moderation roles:
./set-role.sh @alice moderator --space "#ops-team"     # PL50 in all space rooms
./set-role.sh @alice moderator --rooms "#general"      # PL50 in specific rooms

# Coercion canary (burst minting, stale tokens, high unclaimed rate):
./audit-vouches.sh                      # full report
./audit-vouches.sh --canary             # anomaly check only (for cron)

# Revocation:
./revoke-member.sh @compromised --reason "..."
./revoke-member.sh --minted-by @organizer --reason "organizer compromised"
./revoke-member.sh --minted-by @organizer --after 2026-06-01 --reason "post-compromise"
```

### Governance dashboard

The governance dashboard is a standalone page at `/governance/` served by the Element Web
container. It shows a live dashboard, provenance search, vouch tree visualization, and
coercion canary alerts across four tabs. The dashboard reads `org.rednet.vouch` / `.claimed`
/ `.revoked` events from #vouch-log via the Matrix Widget API (iframe postMessage). No
server-side component — it's a static HTML file. Falls back to manual paste mode (vouch.jsonl)
if the Widget API is unavailable.

### Governance bot (in-client moderation)

`bootstrap-gov-bot.sh` creates a `@rednet-gov` bot account, a non-E2EE `#gov-bot` command
room (same pattern as Draupnir's `#rednet-mod` — Widget API can't send events in E2EE rooms),
and starts the `governance` profile. Organizers and admins issue `!gov` commands in `#gov-bot`
instead of SSHing into the server.

```bash
# Stand up the gov bot (after bootstrap-governance.sh):
./bootstrap-gov-bot.sh

# Bootstrap an organizer (PL75 — can mint invites, confirm vouches, assign moderators):
./bootstrap-operator.sh carol --role organizer
```

**Commands** (issued in `#gov-bot`):

| Command                                     | Min PL | Action                                           |
| ------------------------------------------- | ------ | ------------------------------------------------ |
| `!gov help`                                 | 0      | List commands                                    |
| `!gov status`                               | 0      | Network summary (members, vouches, alerts)       |
| `!gov audit`                                | 50     | Run canary checks (burst minting, stale tokens)  |
| `!gov report @user --detail "evidence"`     | 0      | Flag account as compromised                      |
| `!gov confirm @user`                        | 75     | Confirm a pending vouch claim                    |
| `!gov role @user moderator\|organizer`      | 75     | Assign moderation role across all rooms          |
| `!gov revoke @user --reason "..."`          | 100    | Revoke member: PL -1 in all rooms + kick         |
| `!gov revoke-chain @voucher --reason "..."` | 100    | Revoke a voucher and all members they introduced |

The bot uses two tokens: its own (`GOV_BOT_TOKEN`) for replies, and a system token
(`SYS_TOKEN`) for admin operations (PL changes, kicks). Both are in `gov-bot/.env` (gitignored).

The [governance dashboard](/governance/) provides clipboard-based command composition: buttons
copy the appropriate `!gov` command to the clipboard, the organizer pastes it into `#gov-bot`
and sends. The graph tab's node tooltips also expose Report/Revoke/Role buttons.

### Role model (DESIGN §11)

| Role      | PL  | Capabilities                                                              |
| --------- | --- | ------------------------------------------------------------------------- |
| Member    | 0   | Send messages, view rooms                                                 |
| Moderator | 50  | Kick, ban, redact, set topic, run audits                                  |
| Organizer | 75  | Mint invites, confirm vouches, assign moderators, all moderator actions   |
| Admin     | 100 | Change power levels, revoke members, revoke chains, all organizer actions |

Assign roles with `set-role.sh` or via the gov bot (`!gov role`).

### Group calls module (DESIGN §8)

E2EE group video/voice via Element Call (MatrixRTC + LiveKit SFU). A deferred post-v1 module —
**not deployed by default**. In production, the LiveKit SFU runs on a **separate public-IP box**
(WebRTC needs direct UDP; can't go behind a proxy). The media node has no DB, no inbound path to
the core, and stores no history. Seizure yields live-call metadata only.

```bash
# Set in rednet.env:
REDNET_CALLS_ENABLED=true

# Generate LiveKit secrets + start the calls profile:
./bootstrap-calls.sh

# Rebuild Element Web with call features enabled:
./element-web/build.sh
```

The bootstrap generates LiveKit API keys (gitignored), renders the `.well-known/element/call.json`
discovery endpoint, and starts the LiveKit SFU + JWT auth service. Caddy routes `/_livekit/*` to the
JWT service and serves the well-known. Element Web picks up call support via `element_call` config +
feature flags (rendered from `REDNET_CALLS_ENABLED`).

#### ⚠ Before enabling — hardening checklist (2026-07 security research)

Group calls are the biggest metadata tradeoff in the design and are deferred deliberately. A
current-sources review confirmed the picture: **call content is genuinely E2EE** (the SFU only
relays ciphertext frames, keyed over Matrix's own audited Olm), but the media node
**irreducibly exposes each participant's real IP, co-presence, and call timing** — WebRTC is UDP
and cannot ride Tor, so this cannot be hidden (comparable to Signal's own group-call exposure).
Element Call's E2EE implementation is **not independently audited**, and its SFrame layer has
**no per-sender authentication** (a malicious in-call member can forge another's media — an
insider attack, bounded by vouched membership). Enable only as an **opt-in module on a SEPARATE
public-IP box** (never the core), for communities that accept that tradeoff.

Do all of the following before setting `REDNET_CALLS_ENABLED=true` in production:

1. **Re-verify image currency, then pin.** These images move fast; the pins were last bumped
   2026-07-21 to `livekit-server:v1.13.4` and `lk-jwt-service:v0.5.0`. Check for newer releases.
2. **Set `LIVEKIT_FULL_ACCESS_HOMESERVERS` to your domain — never `*`.** `lk-jwt-service` v0.5.0+
   requires it and refuses to start without it; every release before v0.5.0 defaulted to a `*`
   wildcard that let any federated user trigger SFU room creation. `bootstrap-calls.sh` now
   renders it to `REDNET_DOMAIN`; if you already have a `livekit/.env`, add the line by hand.
3. **Verify the discovery format + CORS.** Current clients discover the SFU via the
   `org.matrix.msc4143.rtc_foci` key inside `/.well-known/matrix/client` (served with
   `Access-Control-Allow-Origin` + `application/json`), not the legacy separate
   `/.well-known/element/call.json` this module still renders. Confirm which your client versions
   use and that CORS is present — a documented Element X self-host failure was a missing-CORS
   well-known.
4. **Confirm LiveKit is not logging participant IPs**, or the "disposable, no-data media box"
   property doesn't hold.
5. **Run the SFU on a dedicated public-IP host, not the core** (DESIGN §8: the media node needs
   ~201 open UDP ports and cannot hide behind the front). Add an honest in-call notice that a
   call exposes the participant's IP and who is on it; route the highest-risk _who-hidden_ voice
   need to async encrypted voice notes instead.
