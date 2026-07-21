# REDnet v1 — Implementation Specification

**Status:** Implementation spec (2026-06-16). Companion to `DESIGN.md`. **Build status (2026-07-04):** most of this spec is **built and CI-verified in-sandbox** (see [README § Project status](README.md#project-status) + [deploy/](deploy/)); the §13 spikes marked ✅ are done, and real-infra + external-review items remain.
**Relationship:** `DESIGN.md` = the _why_ (threat model, tier doctrine, decisions-of-record). This `SPEC.md` = the _what to build_ (components, versions, config, runbooks). Where they conflict, DESIGN.md governs intent; this doc governs implementation.

**Pinned versions (verified 2026-06-16; pin exact builds at deploy):** Synapse **1.155.0** · MAS **1.19.0** · Draupnir **3.1.0** · Matrix spec **1.18** · Element Web **1.11.86** · Element X **26.06.x** · matrix-js-sdk **26.x**. Deployment base: a **fork of `matrix-docker-ansible-deploy` (MASH)**.

> Legend: `★` = a gotcha that silently breaks things if wrong. `SPIKE` = must verify on real infra before relying on it. `DEC` = per-deployment decision with a shipped default.

---

## 1. v1 scope

**In v1:** hardened Synapse + PostgreSQL + MAS on a no-public-IP **core**; a disposable clearnet **front** proxy over WireGuard; self-hosted **Element Web** (primary) + a thin **onboarding PWA**; **Element X** as the native mobile option; **Draupnir** moderation bot (also delivers retention presets); a public static **/reference page** for durable public-safe info; encrypted off-box **backups**; WireGuard-only **monitoring** and admin.

**Deferred / OFF in v1:** group **calls** (post-v1 isolated module — DESIGN §8); **matrix-viewer** public preview (conflicts with E2EE — see §11); **Policy Servers** (MSC4284, emerging); **v2 identity recovery** (hooks reserved — §6).

## 2. Components

| Component           | Software / version                           | Box              | Public?                      | Role                                                                        |
| ------------------- | -------------------------------------------- | ---------------- | ---------------------------- | --------------------------------------------------------------------------- |
| Homeserver          | Synapse 1.155.0 (**monolith, no workers**)   | core             | no                           | Matrix server; the metadata honeypot                                        |
| Database            | PostgreSQL (≥14), `LC_COLLATE=C`             | core             | no (localhost)               | All state + encrypted key-backup secrets                                    |
| Auth                | MAS 1.19.0                                   | core             | no                           | OIDC/auth for Element X; no-PII account creation via Admin API              |
| Reverse proxy / TLS | **Caddy** (auto-ACME)                        | front            | **443 only**                 | TLS term; routes to core over WireGuard; serves `.well-known` + Element Web |
| Web client          | Element Web 1.12.x (pre-baked)               | front (static)   | served                       | Browser door — the primary client                                           |
| Onboarding          | built — Element Web soft fork + `/join` page | front (static)   | served                       | Silent no-PII account + key bootstrap                                       |
| Mobile client       | Element X 26.06.x                            | n/a (app stores) | n/a                          | Native option (more onboarding steps — §6)                                  |
| Moderation          | Draupnir 3.1.0 (bot mode)                    | core             | no                           | Bans/redaction + retention presets, via chat commands                       |
| Monitoring          | Prometheus + Grafana                         | core/admin       | **no (WireGuard-only)**      | Disk/service/backup/tripwire alerts                                         |
| Admin               | synapse-admin (etkecc fork)                  | core             | **no (localhost/WireGuard)** | Break-glass console                                                         |
| Backups             | restic (append-only) → off-box repo          | core → remote    | n/a                          | Encrypted, repo key held off-core                                           |

## 3. Topology & networking

```
INTERNET ──HTTPS:443──▶ FRONT (disposable, public IP, NO data/secrets)
                         • Caddy auto-TLS
                         • serves /.well-known/matrix/client (static JSON)
                         • serves Element Web + onboarding PWA (static)
                         • reverse-proxy split (below)
                         • NO 8448, NO /.well-known/matrix/server
                          │
                          │  WireGuard  (PersistentKeepalive=25 front→core;
                          │              MSS clamp on FORWARD; MTU −60)
                          ▼
                        CORE (NO public IP)
                         • Synapse :8008  (x_forwarded: true, bind WG/loopback)
                         • MAS      :8080
                         • PostgreSQL (localhost only)
                         • Draupnir, synapse-admin, Prometheus/Grafana (all WG-only)
```

**Reverse-proxy split on the front** (order matters — MAS regex must precede the Synapse catch-all):

```
^/_matrix/client/.*/(login|logout|refresh)   → core:8080  (MAS)
^(/_matrix|/_synapse/client|/_synapse/mas)   → core:8008  (Synapse)
/.well-known/matrix/client                   → static (front); ACAO: *
everything else under your domain            → Element Web / onboarding PWA (static)
/_synapse/admin                              → ★ DENY at the front (never route admin)
```

Set `X-Forwarded-For` + `X-Forwarded-Proto: https`; raise `client_max_body_size` to match Synapse `max_upload_size`.

**Must-get-right (each silently breaks login/uploads):**

- ★ **MAS `http.public_base` and `http.issuer` MUST be the external `https://` URL.** MAS sets the cookie `Secure` flag from the _scheme of `public_base`_, not `X-Forwarded-Proto` (code-verified, undocumented). An `http://` value → non-Secure cookies dropped over HTTPS → login mysteriously fails.
- ★ **Synapse `public_baseurl` = external URL**, `x_forwarded: true`, listener bound to WG/loopback.
- ★ **WireGuard MSS clamp** (`iptables -t mangle -A FORWARD … TCPMSS --clamp-mss-to-pmtu`) + **`PersistentKeepalive = 25`** front→core. Without these, large media uploads hang (PMTU black-hole) and the no-public-IP core becomes unreachable.
- `http.trusted_proxies` in MAS must include the WireGuard egress IP (defaults are RFC1918 + `10.0.0.0/10`).
- No-federation simplification: `matrix_homeserver_federation_enabled: false`; no 8448; `serve_server_wellknown: false`. The front exposes exactly one logical service (client-server API).

## 4. Hardened Synapse config (homeserver.yaml — shipped defaults)

```yaml
# Identity / federation
server_name: "<DEC: deployment domain>" # ★ IMMUTABLE — never changes post-deploy
public_baseurl: "https://<domain>/"
serve_server_wellknown: false
federation_domain_whitelist: [] # closed island; also no federation listener

# Registration / auth → delegated to MAS (Synapse native registration is disabled under MAS)
enable_registration: false

# E2EE + metadata minimization
presence: { enabled: false }
url_preview_enabled: false # SSRF + IP/timing leak
# (read receipts / typing CANNOT be disabled server-side — accept; minimize via retention)

# Retention (server-wide default = stable; per-room = experimental, delivered by bot — §7)
retention:
  enabled: true
  default_policy: { max_lifetime: 7d } # DEC: 7d default
  allowed_lifetime_min: 1h
  allowed_lifetime_max: 30d # ★ HARD anti-forensic ceiling — Synapse clamps EVERY room to ≤30d; nothing on the server persists longer (a seized server reveals ≤30d)
  purge_jobs:
    - { longest_max_lifetime: 1d, interval: 30m } # tight, so 1h/24h presets purge promptly
    - { shortest_max_lifetime: 1d, interval: 12h }
media_retention:
  local_media_lifetime: 7d # media ≤ text
  remote_media_lifetime: 1d # (none, with federation off)

# Log / IP hygiene (no IP off-switch exists — only shorten the window)
user_ips_max_age: "1d"
redaction_retention_period: "1d"

# Rate limits — TIGHTEN for a closed invite-only server
rc_registration: { per_second: 0.05, burst_count: 3 }
rc_login:
  address: { per_second: 0.1, burst_count: 3 }
  failed_attempts: { per_second: 0.1, burst_count: 3 }
rc_invites:
  per_room: { per_second: 0.1, burst_count: 5 }

# Secrets that MUST survive a restore (see §9): macaroon_secret_key, form_secret, signing.key
```

Apply the official systemd `override-hardened.conf` (`NoNewPrivileges`, `ProtectSystem=strict`, `PrivateDevices`, seccomp `@system-service`) to Synapse, PostgreSQL, and MAS. PostgreSQL: created `LC_COLLATE='C' LC_CTYPE='C'` from `template0`; tune `shared_buffers`/`work_mem` (Synapse on default Postgres is a perf foot-gun even small).

> **Honest limit (not a bug — a Matrix property):** room **name/topic/membership/timestamps live in server-side _state events_, which are plaintext and are _never_ purged by retention.** E2EE protects message bodies only. This is the irreducible honeypot (DESIGN §9); it is exactly why sensitive comms live in Tier 2.

## 5. Onboarding — dual-track (no-PII, token-gated)

MAS structurally prevents handing a logged-in session from a web page into Element X (a security property — it stops a rogue page impersonating users). So onboarding splits by client. Both use MAS with `password_registration_enabled: true`, `password_registration_email_required: false`, `password_registration_token_required: true`, Admin API enabled (`urn:mas:admin` client-credentials for the onboarding backend).

**Track A — Web / PWA (primary, the seamless path). ~2 user actions, fully silent keys.**

1. Scan card QR → branded onboarding PWA (our code) on the front.
2. A **customized Element Web first-run** logs in the no-PII account (minted via MAS — Admin-API `POST /api/admin/v1/users` or `register-user`) and, **on Element Web's own session/device**, silently runs matrix-js-sdk `bootstrapCrossSigning` + `bootstrapSecretStorage` with an **app-supplied `createSecretStorageKey`** (key never shown — no UIA, MSC3967), auto-joins the welcome room, and prompts once for a **display name**. Done — the user is already in Element Web on a verified device.
   - ✅ **Verified (milestone D, `prototype/onboarding/handoff.mjs`):** because the bootstrapped device _is_ the Element Web session, Element Web shows **no recovery nag** (cross-signed device, keys cached). ★ **Do NOT** build this as a _separate_ PWA that hands a token to a _fresh_ Element Web login — that fresh login is an unverified new device that can't unlock the already-set-up secret storage, so Element Web re-prompts "verify this session / enter recovery key." **The crypto bootstrap must run in Element Web's own session/store.**

**Track B — Element X (native mobile option). ~5 user actions, incl. one unavoidable recovery-key screen.**

1. Scan QR → landing page with the single-use token (made trivially copyable; `?token=` URL pre-fill is **not** possible in MAS — verified).
2. Tap "Open in Element X" → deep link `https://mobile.element.io/element/?account_provider=<hs>&login_hint=mxid:@user:<hs>` (pre-fills homeserver + username only).
3. Element X "Create account" → MAS in-app web page; paste token; set password (no email).
4. **Recovery-key screen** — Element X shows it (product decision; cannot be suppressed in the binary). User saves/continues.
5. Pick display name → done; server-side auto-join handles rooms.

**Recovery = accept-loss (DESIGN §7).** No escrow. "Also log in on web" (a second session) is the free recovery. **v2 hooks reserved now:** the card carries a dormant per-account **claim secret** (low-sensitivity claim token, not a decryption key); server stores `hash(claim secret) → account`; governance log persists `token → organizer → account`. A future v2 flow = claim secret + M-of-N moderator sign-off → restore account/rooms (not history). Cheap now, impossible to retrofit onto distributed cards.

## 6. Retention delivery & the durable-reference surface

**No Element client exposes per-room retention** (element-web#18630 closed not-planned), and per-room `m.room.retention` is experimental. So **the Draupnir bot delivers presets** by writing the state event on command — folded into the moderation bot you're already shipping (§8), not a new component.

Presets (friendly label → `max_lifetime`): **Ephemeral 1h · Sensitive 24h · Standard 7d · Durable 30d.** Operator types e.g. `!rednet retention sensitive`; bot checks power level, writes `m.room.retention`, and **posts a plain-language confirmation in-room** — which doubles as the missing "messages auto-delete here" signal for members. ★ `allowed_lifetime_max: 30d` is a **hard ceiling** — Synapse clamps every room to ≤30d, so 30 days is the longest any preset can buy; nothing on the server persists longer, and that bound _is_ the anti-forensic guarantee, not a limit to work around.

**Durable-reference surface = a public static `/reference` page**, served by the front (Caddy `handle /reference*` → the bind-mounted `element-web/branding/reference.html`) and edited live by operators — **not a Matrix room**. It carries only **public-safe** durable info (hotline / legal-aid / mutual-aid links, know-your-rights basics); anything sensitive (exact meeting points, personal contacts, plans) stays in chat, where it's members-only and rolls off (≤30d) by design. Rejected alternatives (with reasons): a **dedicated Matrix room** — can't be both permanent and members-only under the 30d ceiling, and permanent sensitive content contradicts the anti-forensic model (this is why the earlier "📌 Reference room" was retired); **pinned messages** are pointers that die on the retention clock (dangling reference); **widgets** have no maintained self-hostable manager (Dimension archived) + consent-dialog friction; **CryptPad-as-widget leaks its decryption key into federated room state** — link out to self-hosted CryptPad in a separate browser tab only, never embed; **Etherpad** is plaintext-at-rest.

**The one permanent store is `vouch.jsonl`** — an on-disk file (the governance audit trail), immune to Matrix retention; `#vouch-log` is only a ≤30-day human-readable mirror of it.

Honest caveats to surface in the exposure banner: retention deletes from the _server_ on a timer; it does **not** wipe device-local copies (no client-side disappearing messages exist in Element), and does **not** purge state/membership/keys. The `/reference` page is **public** — treat it as world-readable and keep it public-safe only, never operational secrets.

`SPIKE` (gating): on the pinned Synapse build (≥1.110.0 for the per-room fix), **prove purge actually fires in an _encrypted_ room** — set 1h policy, post, wait past the interval, confirm rows leave `events`/`event_json`. Retention is experimental with a live 2026 bug tail (element-web#33199, 2026-04-19).

## 7. Moderation & anti-abuse

**Day one (zero infra):** native **power levels** — three `DEC`-named moderator roles at PL50 (ban/kick/redact), everyone else PL0; Element's built-in ban/kick/redact/report. Covers normal operation for 250 users.

**Baked into the GitOps deploy (setup is hard, operation is easy):** **Draupnir 3.1.0 in bot mode** (dedicated account, token, unencrypted management room at PL≥50, Node 24) — provisioned by the pipeline (consistent with no-standing-admin, DESIGN §11), so organizers never face the sysadmin-grade setup but **operate entirely by chat command**: `!draupnir ban`, `!draupnir redact`, and highest-leverage — `!draupnir watch #list:server` to subscribe to curated community ban lists (inherited threat intel). Draupnir's bot token is a tracked backed-up secret.

**Front door:** MAS/token-gated registration + native invite-blocking (MSC4380, v1.18) + Draupnir New-Joiner / Block-Invitations protections + **`synapse-http-antispam`** bridging to Draupnir (gates `user_may_invite`/`user_may_join_room`; **must run `fail_open`** so the homeserver survives Draupnir being down).

**Defer Policy Servers (MSC4284, stabilized Matrix 1.18):** the strongest structural anti-raid answer, but unproven for small non-expert teams — revisit post-v1.

## 8. Clients

- **Primary: self-hosted Element Web** — `config.json` with `default_server_config.m.homeserver.base_url` = public URL, **`disable_custom_urls: true`** (lock to the island), telemetry off, self-hosted fonts/assets, strict CSP, no third-party CDN. Served from the front. This is the most approachable door (no install) and the Track-A target.
- **Native: Element X** (iOS/Android, app stores) via the provisioning deep link. Accepts the extra onboarding steps + visible recovery key (§5 Track B).
- **Recovery nudge in onboarding:** "also stay logged in on the web" — a second verified session is the free, no-escrow recovery (DESIGN §7).

## 9. Backup & restore

**Back up FIVE things** (missing any one = unrecoverable, often silently):

1. **Synapse PostgreSQL DB** — all state + encrypted key-backup secrets.
2. **MAS PostgreSQL DB** (separate database) — users, sessions; without it nobody can authenticate.
3. **Synapse `signing.key`** (file).
4. **Media store** (`local_content/`, `local_thumbnails/`).
5. **Config + ALL secrets:** `homeserver.yaml` incl. `macaroon_secret_key` (lose it → mass re-login) + `form_secret`; MAS `config.yaml` incl. ★ **`secrets.encryption`** (a matched pair with the MAS DB — _"do not change… loss of all encrypted information in the database"_; backing up the MAS DB without it restores unreadable ciphertext) + `secrets.keys` + `matrix.secret`.

**Backup (automated, hourly–6-hourly, pushes off-box):**

```
pg_dump -Fc --exclude-table-data e2e_one_time_keys_json synapse > synapse.dump   # ★ exclusion = the TRUNCATE requirement, pre-handled
pg_dump -Fc mas > mas.dump
# + signing.key, homeserver.yaml(+secrets), MAS config.yaml(+secrets.encryption/keys/matrix.secret)
# + sync media store (AFTER dumps — additive/content-addressed, so safe)
restic backup …    # append-only repo; ★ repo key held OFF the core (in the M-of-N governance store)
# emit backup-success heartbeat → Prometheus (a silently-stopped backup is the worst latent failure)
```

`pg_dump` takes a consistent snapshot live (no downtime). restic chosen for first-class encrypted object-store backends + append-only (a rooted core can add snapshots but not delete old ones).

**Restore (cold, onto a fresh core with the IDENTICAL `server_name`):** provision via Ansible (pinned versions) → `restic restore` + `restic check` → **provision the box first so `/data` perms + `media_store` exist, then overlay the signing key + config _as the runtime user_** (★ extracting backups into an empty volume breaks ownership → Synapse can't create `media_store`; caught in Spike 04) → place secrets (incl. matched MAS `secrets.encryption`) → `createdb` both with `LC_COLLATE=C` → `pg_restore` both → (if a filesystem snapshot was used instead of the exclude-dump: `TRUNCATE e2e_one_time_keys_json;` **before** first start) → restore media → `mas-cli config check && config sync` → start Postgres→MAS→Synapse→front → **smoke test: log in, send + read an encrypted message from two devices** → rotate the front (assume old topology burned).

**No-federation shrinks restore risk:** the "outgoing federation broken after restore" class (#16025) is **N/A** with `federation_domain_whitelist: []`; the signing key only signs local events, so a lost key is recoverable with far less consequence. The one hard invariant remains **`server_name` immutability**. The realistic model is **cold restore, data-loss window = time since last backup** — trivial here (short retention; a transient town-square, not a system of record); RTO dominated by media transfer.

`SPIKE` (P0): **quarterly automated restore drill** to a throwaway VM with the encrypted-message smoke test. The MAS-key/two-DB coupling means a bad backup _looks_ fine until auth/E2EE silently fails — discover that on a drill, never during real recovery.

## 10. Operations & monitoring (the commonly-missed layer)

- **Monolith, no workers** — confirmed correct at 250 users; record as a decision so nobody adds them (workers = pure complexity + surface here).
- **Self-hosted Prometheus + Grafana, WireGuard-only** (no third-party telemetry). Minimum alerts: **disk-free on core** (the #1 self-inflicted outage → DB corruption), Postgres up, Synapse up, **backup-success heartbeat**, **front reachability** (the tripwire from DESIGN §5b only works if something watches it).
- **synapse-admin (etkecc fork) bound to localhost, reached only over WireGuard**; `/_synapse/admin` ★ never routed by the front (explicit deny). Routine change = GitOps/Ansible; synapse-admin is break-glass; moderation = Draupnir.
- **Caddy auto-TLS** on the front (expired cert on the only door = total outage; don't hand-manage certs on cattle). Note: ACME publishes the hostname to **Certificate Transparency logs** — a permanent, searchable existence leak alongside SNI/DNS (DESIGN threat row 4). A DNS-01 wildcard reduces per-subdomain CT noise; state it in the exposure model, don't pretend the hostname is private.
- **Log hygiene:** Synapse log level WARNING; **front-proxy access logs off or IP-stripped** (the front sees real client IPs first — easy to miss); no long systemd-journal retention on either box.

## 11. Whitelabel & GitOps deployment

Fork **`matrix-docker-ansible-deploy` (MASH)** — Ansible + Docker, first-class federation-off (`matrix_homeserver_federation_enabled: false`), native MAS role, retention, Traefik/BYO-proxy. A whitelabel hardened overlay = a vars-file + role-override layer on a **pinned, self-maintained snapshot** (mitigates the upstream single-maintainer bus factor). The **GitOps repo is the control plane** (DESIGN §11/§12): signed, M-of-N-merged commits; Ansible provisions the three boxes; no standing admin.

**Per-deployment config surface (`DEC`, shipped with defaults + guidance):** `server_name`/domain, branding, **jurisdiction** (foreign-owned, non-Eyes; defaults Iceland/Switzerland — DESIGN §6b), **retention default** (7d), **admission strictness** (default: attributable vouch for the general network, stricter per-vouch for sensitive compartments), **coercion machinery** (peer-lockout + M-of-N revocation + **duress panic-wipe** — Element panic button + gov-bot `!duress`, shipped; anomaly canaries = v2).

★ **License: MASH and ESS are AGPL-3.0.** Fine for an open, self-hosted tool distributed to at-risk groups (they get source anyway); it **forecloses a proprietary closed-source hosted-SaaS derivative**. Decide licensing posture before building a fork identity.

## 12. Deferred / explicitly OFF in v1

- **Group calls** — post-v1 isolated Tier-1 module on a separate public-IP media box (DESIGN §8). Scaffolded (`calls` compose profile, `bootstrap-calls.sh`); not deployed by default.
- **matrix-viewer public preview — OFF.** It requires `world_readable` rooms (cannot be E2EE) and is explicitly SEO-indexed — in direct conflict with mandatory-E2EE + minimize-exposure. Scaffolded (`viewer` compose profile, `bootstrap-viewer.sh`); off by default. If ever wanted, scope to a single intentional non-sensitive public lobby with a loud UI warning; never member rooms.
- **Policy Servers (MSC4284)** — emerging; revisit post-v1.
- **v2 identity recovery** — crypto + lifecycle built (47/47 tests, `escrow-lifecycle.ts` + `directory.ts`); moderator approval tool + coordination bot not built. See RECOVERY.md §12.

## 13. Remaining spikes (verify on real infra before / during build)

1. ✅ **PASS** (2026-06-16, Synapse **1.155.0** — the pinned build) — **Encrypted-room retention purge** verified: `m.room.encrypted` events purged 6→1; state events + last message persist by design; per-room `m.room.retention` (the preset path) works. Harness + result: `spikes/01-retention-purge/`. **Re-run on any Synapse version bump.**
2. ✅ **PASS — full Track A chain proven** (2026-06-16, Synapse 1.155.0 + MAS 1.18 + matrix-js-sdk 41.8). **(A)** silent E2EE bootstrap — E2EE account (cross-signing + key backup) with an app-held recovery key never shown, zero UIA prompts [`prototype/onboarding/`]. **(B)** MAS↔Synapse delegation (`matrix_authentication_service` shared-secret block) + **no-PII account creation** (register-user, no email) + MAS-issued token **accepted by Synapse** (whoami=@alice) → silent bootstrap [`prototype/onboarding-mas/`]. **(D)** hand-off characterized [`prototype/onboarding/handoff.mjs`]: the bootstrap must run **inside Element Web's own session** (→ no re-nag); a separate-PWA→fresh-login re-nags (corrected §5). **Remaining:** auto-join (trivial), PWA packaging + security review.
3. ✅ **PASS (topology + media)** (2026-06-16) — core (Synapse+Postgres) runs with **no published ports**; 10MB media round-trips byte-identical through the Caddy front. MAS `public_base`/cookie gotcha is **code-verified** (rule: MAS `http.public_base` MUST be `https://`). _Deployment-time:_ WireGuard MSS/PMTU upload-hang (needs real WG) + full MAS-delegated login through the front. Harness: `spikes/03-two-tier/`.
4. ✅ **PASS** (2026-06-16, Synapse 1.155.0) — **backup → destroy → cold restore** verified: account logs in, 4 encrypted messages recovered, signing key preserved, `keys/upload` 200; the **exclude-dump satisfies the `e2e_one_time_keys_json` TRUNCATE** (stale OTK 1→0). Surfaced the `/data` ownership gotcha (now in §9). Harness: `spikes/04-backup-restore/`. (MAS two-DB + `secrets.encryption` restore still a deployment-drill item.)
5. `SPIKE` **Element X provisioning deep-link + MAS token onboarding** end-to-end on real iOS + Android.
6. `SPIKE` **250-user load test** on the §sizing (DESIGN §6c) under the chosen retention; confirm DB growth.

## 14. Open per-deployment decisions (defaults shipped; tunable by deployer)

### Decisions — RESOLVED (2026-06-16)

- ✅ **Push:** stock Element X via Element's matrix.org gateway, with **`push.include_content: false`** (strip content → only activity-timing can leak, never content/sender/room). UnifiedPush/own-Sygnal = later upgrade. iOS unavoidably uses APNs.
- ✅ **Web client = soft fork** of Element Web (config + `CryptoSetupExtensions` module + `postLoginSetup()` patch) for the silent ~2-tap onboarding; commit to Tchap-style rebases + AGPL §13. _Note: the seamless onboarding is **web-only**; mobile uses Element X's native flow. Fork still earns keep via branding + enforcing typing/receipt suppression._
- ✅ **Mobile = stock Element X from the public App Store / Play Store** (no sideload, no MDM), pointed at the server by a **deep link** in the onboarding card; generic "Element" branding (deniable, $0). Branded-in-stores (DIY: own Apple/Google dev accounts + you're the publisher; or Element Pro enterprise) = deliberate later upgrade. Mobile onboarding = Element X native (~5 taps incl. a recovery screen; harmless under accept-loss).
- ✅ **Mobile metadata posture:** stock Element X does **not** suppress typing indicators or read receipts by default (the web fork does). Users must toggle these off manually in the mobile app. Document in `SAFETY.md`. A branded Element X build (Element Pro or own fork) could enforce suppression; accept for v1.
- ✅ **Encrypted search = desktop-only.** E2EE messages are searchable only on Element Desktop / Element Web (where the device holds decrypted copies). Element X mobile cannot search encrypted history. Route archivists to **Element Desktop**; the `/reference` page + pinned messages hold must-find info. Document in `SAFETY.md`.
- ✅ **Mobile search gap:** accept for v1 (subsumed by above).

### Shipping defaults (per-deployment config; override in the fork's vars)

`DEC` retention **7d** · jurisdiction **config** (Iceland/Switzerland default) · admission **attributable-vouch** · coercion machinery **duress + M-of-N revocation** · calls **deferred** · threads **flat/web-only on mobile** · front-box count per-deployment.

---

_This spec turns the vetted DESIGN.md into a buildable system. The architecture and component choices are settled; the §13 spikes are the only real-world unknowns, and they are verification tasks, not open questions._

_See `ARCHITECTURE.md` for the complete how-it-works reference: runtime wiring, Matrix E2EE mechanics, end-to-end lifecycles, the full feature inventory (web vs mobile), and the gap/decision register._
