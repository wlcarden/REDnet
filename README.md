# REDnet

Hardened, self-hosted Matrix infrastructure for at-risk communities. Protects message content with end-to-end encryption. Non-technical users install from a public app store, scan a QR code, and join.

> **Status: pre-production.** All in-house verification complete (crypto, E2E, CI, operational drills). Pending an independent external security review before deployment with real users. See [Project status](#project-status).

---

## What REDnet is

REDnet is a whitelabel, forkable deployment of a hardened Matrix homeserver for communities facing state-level adversaries. It is the **Tier-1 tool** in a two-tier communications strategy:

| Tier                  | Protects                  | Tool             | Access                     |
| --------------------- | ------------------------- | ---------------- | -------------------------- |
| **Tier 1 (REDnet)**   | Message _contents_ (E2EE) | Matrix / Element | App store or browser       |
| **Tier 2 (separate)** | Contents _+ who_          | SimpleX / Cairn  | High-friction, out-of-band |

REDnet protects **what is said**. It cannot hide **who said it to whom and when**; that metadata lives on the server. Group coordination lives here, protected by E2EE. Sensitive exchanges belong on a separate, metadata-minimal tool that REDnet complements but never replaces.

### What REDnet is not

- **Individual-target protection.** It does not defend against Pegasus-class spyware or forensic extraction of an unlocked device. No chat system does.
- **Metadata-minimal messaging.** A hosted Matrix server is a metadata honeypot. REDnet bounds that exposure.
- **A mesh or decentralized network.** REDnet is a centralized, hardened server. The project [evaluated and retired](DESIGN.md#2-design-history-why-hosted-matrix-not-a-leave-behind-mesh) decentralized alternatives.

## Architecture

```
             ┌──────────────── CLIENTS ────────────────┐
             │  Element Web (browser) · Element X (mobile) │
             └──────────────────┬──────────────────────┘
                                │ HTTPS :443
                   ┌────────────▼────────────┐
                   │  FRONT (disposable VPS)   │
                   │  Caddy · Element Web      │
                   │  .well-known · TLS        │
                   └────────────┬────────────┘
                                │ WireGuard
         ┌──────────────────────▼──────────────────────┐
         │  CORE (no public IP)                          │
         │  Synapse · MAS · PostgreSQL · Draupnir        │
         │  Prometheus/Grafana · synapse-admin (WG-only)  │
         └───────────────────────────────────────────────┘
```

The front proxy is a cheap, rotatable VPS that terminates TLS and reverse-proxies to the core over WireGuard. The core has no public IP. Seizing the front yields the tunnel path. Seizing the core yields the metadata honeypot. Message content stays encrypted in both cases.

For the full component table, runtime wiring, and the optional media node (deferred), see [ARCHITECTURE.md](ARCHITECTURE.md).

## Quick start

Prerequisites: a Linux host with Docker and Docker Compose.

```bash
# Clone and configure
cd deploy/
cp rednet.env.example rednet.env
# Edit rednet.env — set REDNET_DOMAIN (immutable after first deploy)

# Deploy
./setup.sh
# Generates secrets, renders hardened configs, starts the stack, runs self-checks
```

`setup.sh` is a **fresh-deploy script** that always starts clean (`docker compose down -v`). It generates all secrets (signing key, MAS secrets, Synapse↔MAS shared secret, DB password) into gitignored files, renders hardened configs, starts the stack, and verifies:

- MAS healthy and serving OIDC discovery
- Synapse up and delegating auth to MAS
- A MAS-issued bearer token accepted through the front

To admit users, mint a registration token:

```bash
docker compose exec mas mas-cli manage issue-user-registration-token --config /config.yaml
# → Created user registration token: <token>  (single-use by default)
```

For production two-host deployment, see [deploy/ansible/](deploy/ansible/).

## Hardening

The deployment enforces these controls by default. They are not optional or configurable.

- **Mandatory E2EE.** No plaintext rooms.
- **Closed federation.** No federation listener, whitelist `[]`, no `.well-known/matrix/server`.
- **No-PII accounts.** No email, no phone number, registration by invite token only.
- **MAS-delegated auth.** Synapse runs no auth of its own; `password_config.enabled: false`.
- **Short retention.** 7-day default (configurable per-room), media ≤ text.
- **Metadata scrubbing.** `scrub-metadata.sh` purges client IPs from Synapse + MAS tables.
- **Admin denied at the front.** `/_synapse/admin` blocked at the reverse proxy.
- **No third-party telemetry.** Element Web analytics off, self-hosted fonts/assets, strict CSP.
- **No standing admin access.** All changes via the GitOps repo, not live credentials.
- **Digest-pinned images.** All 8+ container images pinned to `@sha256:` digests.
- **Encrypted off-box backups.** Restic with the repo key held off-core.

See [SPEC.md §4](SPEC.md) for the full hardened `homeserver.yaml` reference.

## Silent onboarding

REDnet ships a custom Element Web build with a [CryptoSetupExtensions module](deploy/element-web/rednet-module/) that replaces Element's standard setup ceremony. On first login:

1. Cross-signing, secret storage, and key backup all bootstrap on login
2. A 7-word diceware recovery passphrase surfaces once ("save this, it's the only way back in")
3. The user auto-joins the community space

Element's standard "verify this device" and "set up Secure Backup" dialogs are gone. Two visible steps from QR scan to room list.

On a returning device, the module prompts for the passphrase and recovers identity + key backup. Browser E2E tests confirm both paths work end-to-end (2/2 PASS).

## Project status

### Verified (in-house, no external review)

| Track                  | Status                                           | Evidence                                             |
| ---------------------- | ------------------------------------------------ | ---------------------------------------------------- |
| **CI harness**         | 3 tiers: static lint, integration, Docker build  | `deploy/ci-check.sh`, all tiers GREEN                |
| **Silent onboarding**  | Module typechecks, builds, wires into Element    | Browser E2E 2/2 PASS (Playwright)                    |
| **Operational drills** | Metadata scrub, backup/restore, restic           | All 3 drills PASS on live stack                      |
| **Escrow crypto**      | Shamir + ECIES + scrypt + HKDF + AES-GCM         | 37/37 checks PASS (14 ECIES + 10 Shamir + 13 escrow) |
| **Escrow lifecycle**   | Directory auth, event protocol, deposit/recovery | 10/10 checks PASS (Ed25519 + round-trip + handshake) |
| **Two-host isolation** | Docker firewall bypass, WG aperture              | In-sandbox + KVM validation PASS                     |
| **Supply chain**       | All images digest-pinned                         | Smoke-tested, boots + self-checks PASS               |
| **Security review**    | AI-assisted, 9-dimension swarm (71 agents)       | 53 findings; all critical/high remediated            |

### Remaining (external, not skippable)

- **Independent security review** by a specialist with Matrix-E2EE + applied-crypto expertise ([PRODUCTION.md §1](PRODUCTION.md)). The in-house review is strong at concrete, checkable flaws; weak at novel-attack creativity and live-protocol behavior under attack.
- **Real two-host dry-run** on throwaway infrastructure (the topology is validated in KVM, not on real hosts).
- **Element X mobile E2E**: stock Element X from a public app store against the live server.
- **Load test** at ~250 users on the target hardware sizing.

### Not yet built

- QR-card printing and batch invite workflow (generate-invite.sh + /join landing page built; needs live-stack validation)
- Phase-2 recovery: crypto + lifecycle built (47/47 tests); moderator approval tool + coordination bot not built ([RECOVERY.md §12](RECOVERY.md))
- Group calls: scaffolded (LiveKit SFU + JWT service + Caddy routing + Element config); needs live-stack validation + production media-node deployment ([DESIGN.md §8](DESIGN.md))
- matrix-viewer: scaffolded (compose profile + Caddy routing + bootstrap script); OFF by default — conflicts with mandatory E2EE ([SPEC.md §11](SPEC.md))

## Threat model summary

REDnet assumes the server **will** be seized. These controls bound what a seizure yields:

| Scenario                     | Adversary learns                                                        | Stays protected                                           |
| ---------------------------- | ----------------------------------------------------------------------- | --------------------------------------------------------- |
| Core seized                  | Social graph, message envelopes (who/when/room), device records         | Message **content** (E2EE), history older than retention  |
| Front seized                 | That it's a REDnet front, connecting client IPs, WireGuard path to core | Content, core data-at-rest                                |
| Device unlocked (AFU)        | Local message history within retention, pseudonym, room list            | Expired content, rooms the device wasn't in               |
| Device compromised (spyware) | **Everything, real-time**                                               | Nothing. REDnet does not defend against device compromise |

The full 9-scenario compromise map is in [DESIGN.md §9](DESIGN.md).

## Documentation

| Document                                 | Purpose                                                              |
| ---------------------------------------- | -------------------------------------------------------------------- |
| [DESIGN.md](DESIGN.md)                   | Why: threat model, tier doctrine, design decisions                   |
| [ARCHITECTURE.md](ARCHITECTURE.md)       | How: runtime wiring, E2EE mechanics, traced lifecycles               |
| [SPEC.md](SPEC.md)                       | What to build: components, versions, hardened config                 |
| [RECOVERY.md](RECOVERY.md)               | Phase-2 escrow design: Shamir + ECIES construction                   |
| [PRODUCTION.md](PRODUCTION.md)           | Gap list between verified-in-sandbox and real deployment             |
| [SAFETY.md](SAFETY.md)                   | Plain-language guide for end users (no technical background needed)  |
| [SECURITY-REVIEW.md](SECURITY-REVIEW.md) | AI-assisted security review findings + remediation status            |
| [BRAND.md](BRAND.md)                     | Visual identity: color palette, typography, voice, design principles |
| [deploy/](deploy/)                       | The runnable deployment stack                                        |

### Spike validation

Empirical verification spikes, each with a self-contained README:

| Spike                                             | Proves                                                  |
| ------------------------------------------------- | ------------------------------------------------------- |
| [01, retention purge](spikes/01-retention-purge/) | Synapse retention purges encrypted events               |
| [03, two-tier proxy](spikes/03-two-tier/)         | Front→core WireGuard proxy + MAS auth delegation        |
| [04, backup/restore](spikes/04-backup-restore/)   | Encrypted backup round-trip, hardening survives restore |
| [05, recovery escrow](spikes/05-recovery-escrow/) | Shamir + ECIES escrow construction                      |
| [06, moderator keys](spikes/06-moderator-keys/)   | Per-moderator ECIES key management                      |
| [07, escrow store](spikes/07-escrow-store/)       | Escrow blob storage + retrieval                         |
| [08, quorum growth](spikes/08-quorum-growth/)     | Re-sharing when moderator roster changes                |
| [09, escrow auth](spikes/09-escrow-auth/)         | AAD binding + cross-context rejection                   |

## Security

See [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## License

[AGPL-3.0-only](LICENSE)
