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
./setup.sh                            # generates secrets, renders + hardens configs, brings it up, verifies
```

`setup.sh` generates all secrets (signing key, MAS secrets, the Synapse↔MAS shared secret, DB password) into gitignored files, renders the hardened Synapse + MAS configs from `rednet.env`, starts the stack, and runs a self-check (MAS healthy · Synapse up & delegating · a MAS-issued token accepted through the front).

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
docker compose exec mas mas-cli manage issue-user-registration-token --config /config.yaml
#   -> Created user registration token: ZF0PNzXZaXy3   (single-use by default)
# options: --usage-limit N  ·  --unlimited  ·  --expires-in <seconds>  ·  --token <specific-string>
```

Give that token to the invitee. They can register via the MAS registration page at the front, or use
the **QR invite flow**:

```bash
./generate-invite.sh                  # mint a token + generate a printable QR card
./generate-invite.sh --batch 5        # mint 5 tokens + 5 cards
./generate-invite.sh --token TOKEN    # card for an already-minted token
```

The script produces a branded HTML card in `invites/` (one per token). Open it in a browser and print.
The QR encodes `https://DOMAIN/join#TOKEN`, which loads a branded landing page with platform detection
(desktop vs. mobile), the token for copy-paste, and step-by-step instructions. The landing page is
served by the Element container at `/join`.

Admin/system accounts are created out-of-band with `mas-cli manage register-user` (admin path,
bypasses the token gate).

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
- [x] QR-card onboarding (`generate-invite.sh` + `/join` landing page + platform detection). _Scaffold: needs live-stack validation._
- [x] Phase-2 recovery lifecycle (`escrow-lifecycle.ts` + `directory.ts` + `events.ts`, 47/47 crypto+lifecycle tests). _Moderator approval tool + coordination bot not built._
- [x] Group calls module (`bootstrap-calls.sh`, LiveKit + JWT + Caddy + Element config, `calls` profile). _Scaffold: needs live-stack + production media node._
- [x] matrix-viewer public preview (`bootstrap-viewer.sh`, `viewer` profile). _Scaffold: OFF by default, conflicts with mandatory E2EE (SPEC §11)._

## ⚠️ Before production

Image digests are pinned (PRODUCTION.md §2). Move the front to a separate box. Run backups (`backup.sh` with `RESTIC_REPOSITORY`/`RESTIC_PASSWORD` set, repo password held off-core) + monitoring (`--profile monitoring`) + the WireGuard tunnel. Run the Spike 04 restore drill. Add operators to the Draupnir management room and `!draupnir rooms add` the community rooms. Run `invite-to-community.sh` for any CLI-provisioned users.

## Operational profiles

```bash
./setup.sh                                   # core+front (default)
./bootstrap-draupnir.sh                       # + moderation (compose --profile moderation)
./bootstrap-calls.sh                          # + group calls (compose --profile calls; DESIGN §8)
docker compose --profile monitoring up -d     # + Prometheus/Grafana/Pushgateway/Alertmanager (localhost-bound)
RESTIC_REPOSITORY=s3:... RESTIC_PASSWORD=... ./backup.sh   # encrypted off-box backup + heartbeat
```

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
