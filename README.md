<p align="center">
  <img src="deploy/element-web/branding/rednet-logo.svg" alt="REDnet" width="220">
</p>

<p align="center">
  Hardened, self-hosted communications for at-risk communities
</p>

<p align="center">
  <a href="https://github.com/wlcarden/REDnet/actions/workflows/ci.yml"><img src="https://github.com/wlcarden/REDnet/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>&nbsp;
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0--only-blue" alt="License: AGPL-3.0-only"></a>&nbsp;
  <img src="https://img.shields.io/badge/status-pre--production-E5A536" alt="Status: pre-production">
</p>

<br>

REDnet packages a hardened [Matrix](https://matrix.org) homeserver with silent end-to-end encryption, invite-only registration, and operational tooling for communities facing state-level adversaries. Users install [Element](https://element.io) from a public app store, scan a QR code, and start talking. No key ceremonies, no setup wizards.

> **Pre-production.** All in-house verification complete (47/47 crypto tests, browser E2E, CI, operational drills). An [independent security review](PRODUCTION.md) is required before deployment with real users.

---

## How it works

REDnet is **Tier 1** in a two-tier communications strategy:

|                       | Protects                  | Tool             | Access                     |
| --------------------- | ------------------------- | ---------------- | -------------------------- |
| **Tier 1 (REDnet)**   | Message _contents_ (E2EE) | Matrix / Element | App store or browser       |
| **Tier 2 (separate)** | Contents _+ metadata_     | SimpleX / Cairn  | High-friction, out-of-band |

REDnet protects **what you say**. It cannot hide **who you talk to or when**; that metadata lives on the server. Group coordination belongs here. Sensitive one-to-one exchanges belong on a separate, metadata-minimal channel that REDnet complements but does not replace.

## Architecture

```
                      ┌─────────── CLIENTS ───────────┐
                      │  Element Web  ·  Element X     │
                      └──────────────┬────────────────┘
                                     │ HTTPS
                        ┌────────────▼────────────┐
                        │    FRONT  (disposable)    │
                        │    Caddy · Element Web    │
                        └────────────┬────────────┘
                                     │ WireGuard
              ┌──────────────────────▼──────────────────────┐
              │    CORE  (no public IP)                      │
              │    Synapse · MAS · PostgreSQL · Draupnir     │
              └─────────────────────────────────────────────┘
```

The front is a cheap, rotatable VPS that terminates TLS and proxies to the core over WireGuard. The core has no public IP. Seizing the front yields the tunnel endpoint. Seizing the core yields encrypted data at rest. Message content stays protected in both cases.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full component table, runtime wiring, and optional media node.

## Quick start

Prerequisites: a Linux host with Docker and Docker Compose.

```bash
cd deploy/
cp rednet.env.example rednet.env
# Edit rednet.env — set REDNET_DOMAIN (immutable after first deploy)

./setup.sh
# Generates secrets, renders hardened configs, starts the stack, runs self-checks
```

`setup.sh` is a **fresh-deploy script** that starts clean (`docker compose down -v`). It generates all secrets into gitignored files, renders hardened configs, starts the stack, and verifies health: MAS serving OIDC, Synapse delegating auth, a bearer token accepted through the front.

To admit users:

```bash
docker compose exec mas mas-cli manage issue-user-registration-token --config /config.yaml
# → Created user registration token: <token>  (single-use by default)
```

For production two-host deployment, see [deploy/ansible/](deploy/ansible/).

## Hardening

These controls are enforced by default. They are not optional or configurable.

| Control                   | Detail                                                                 |
| ------------------------- | ---------------------------------------------------------------------- |
| **Mandatory E2EE**        | No plaintext rooms                                                     |
| **Closed federation**     | No federation listener, whitelist `[]`, no `.well-known/matrix/server` |
| **No-PII accounts**       | No email, no phone, registration by invite token only                  |
| **MAS-delegated auth**    | Synapse runs no auth of its own (`password_config.enabled: false`)     |
| **Short retention**       | 7-day default (configurable per-room), media ≤ text                    |
| **Metadata scrubbing**    | `scrub-metadata.sh` purges client IPs from Synapse + MAS tables        |
| **Admin denied at front** | `/_synapse/admin` blocked at the reverse proxy                         |
| **No telemetry**          | Analytics off, self-hosted fonts/assets, strict CSP                    |
| **Digest-pinned images**  | All container images pinned to `@sha256:` digests                      |
| **Encrypted backups**     | Restic with the repo key held off-core                                 |

See [SPEC.md](SPEC.md) for the full hardened `homeserver.yaml` reference.

## Silent onboarding

REDnet ships a custom Element Web build with a [CryptoSetupExtensions module](deploy/element-web/rednet-module/) that replaces Element's standard setup ceremony. On first login:

1. Cross-signing, secret storage, and key backup bootstrap automatically
2. A 7-word diceware passphrase surfaces once ("save this, it's the only way back in")
3. The user auto-joins the community space

Two visible steps from QR scan to the room list. On a returning device, the module prompts for the passphrase and recovers identity + key backup. Both paths confirmed end-to-end (Playwright, 2/2 PASS).

## Threat model

REDnet assumes the server **will** be seized. The design bounds what a seizure yields:

| Scenario               | Adversary learns                                      | Stays protected                                    |
| ---------------------- | ----------------------------------------------------- | -------------------------------------------------- |
| **Core seized**        | Social graph, message timestamps, device records      | Message **content**, history past retention window |
| **Front seized**       | Client IPs, WireGuard path to core                    | Content, core data at rest                         |
| **Device unlocked**    | Local messages within retention, pseudonym, room list | Expired content, rooms the device wasn't in        |
| **Device compromised** | **Everything, real-time**                             | Nothing                                            |

REDnet does not protect against device-level compromise (Pegasus-class spyware, forensic extraction of an unlocked device). No chat application does. It also cannot eliminate metadata exposure from a hosted server; it bounds that exposure through short retention, IP scrubbing, and closed federation. Metadata-minimal communication is what Tier 2 is for.

The project [evaluated and retired](DESIGN.md#2-design-history-why-hosted-matrix-not-a-leave-behind-mesh) decentralized mesh alternatives. The full 9-scenario compromise map is in [DESIGN.md §9](DESIGN.md).

## Project status

### Verified (in-house)

| Track                  | Status                                             | Evidence                             |
| ---------------------- | -------------------------------------------------- | ------------------------------------ |
| **CI**                 | Static lint, integration, Docker build (3 tiers)   | All GREEN                            |
| **Silent onboarding**  | Module builds, wires into Element                  | Browser E2E 2/2 PASS                 |
| **Operational drills** | Metadata scrub, backup/restore, restic             | All 3 PASS on live stack             |
| **Escrow crypto**      | Shamir + ECIES + scrypt + HKDF + AES-GCM           | 37/37 PASS                           |
| **Escrow lifecycle**   | Directory auth, event protocol, recovery handshake | 10/10 PASS                           |
| **Network isolation**  | Docker firewall bypass, WireGuard aperture         | In-sandbox + KVM PASS                |
| **Supply chain**       | All images digest-pinned                           | Boots + self-checks PASS             |
| **Security review**    | AI-assisted, 9-dimension, 71 agents                | 53 findings; all critical/high fixed |

### Remaining (external)

- **Independent security review** by a Matrix-E2EE + applied-crypto specialist ([PRODUCTION.md](PRODUCTION.md))
- **Two-host dry-run** on throwaway infrastructure
- **Element X mobile E2E** from a public app store against the live server
- **Load test** at ~250 concurrent users

### Not yet built

- **QR onboarding flow** — built (`generate-invite.sh` + `/join` landing page); needs live-stack validation
- **Governance tooling** — built (attributed invites, vouch provenance, compartments, canary, revocation); needs live-stack validation
- **Phase-2 recovery** — crypto + lifecycle built (47/47 tests); moderator approval tool + coordination bot remain ([RECOVERY.md](RECOVERY.md))
- **Group calls** — scaffolded (LiveKit SFU + JWT service + Caddy routing); needs production media node ([DESIGN.md §8](DESIGN.md))
- **Public preview** — scaffolded (matrix-viewer, OFF by default); conflicts with mandatory E2EE ([SPEC.md §11](SPEC.md))

## Documentation

| Document                                 | Purpose                                               |
| ---------------------------------------- | ----------------------------------------------------- |
| [DESIGN.md](DESIGN.md)                   | Threat model, tier doctrine, design decisions         |
| [ARCHITECTURE.md](ARCHITECTURE.md)       | Runtime wiring, E2EE mechanics, traced lifecycles     |
| [SPEC.md](SPEC.md)                       | Components, versions, hardened config reference       |
| [RECOVERY.md](RECOVERY.md)               | Phase-2 escrow: Shamir + ECIES construction           |
| [PRODUCTION.md](PRODUCTION.md)           | Gap list between sandbox-verified and real deployment |
| [SAFETY.md](SAFETY.md)                   | Plain-language guide for end users                    |
| [SECURITY-REVIEW.md](SECURITY-REVIEW.md) | Security review findings + remediation status         |
| [BRAND.md](BRAND.md)                     | Visual identity, color palette, voice                 |
| [deploy/](deploy/)                       | The runnable deployment stack                         |

Empirical validation spikes (retention purge, two-tier proxy, backup/restore, escrow construction) live in [spikes/](spikes/), each with a self-contained README.

## Security

See [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## License

[AGPL-3.0-only](LICENSE)
