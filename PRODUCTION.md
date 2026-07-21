# REDnet production-readiness plan

The Tier-1 server + Phase-1 recovery are **functionally complete and verified in-sandbox**. This is the
gap list between that and something you would run for at-risk users. Ordered by what protects
those users most, not by ease.

Legend: 🔬 verifiable in-sandbox · 🎯 needs a real target (hosts / devices / a built client / people).

---

## 1. Independent security review 🎯 (the gate, do not skip)

REDnet creates accounts and bootstraps E2EE keys for people whose threat model includes state forensics.
The onboarding/recovery code is **bespoke and security-critical**, and self-review is not sufficient for
code at this stakes level.

- **Scope (scoped, not full-product):** the escrow construction is the review target. Specifically:
  - The Shamir + ECIES + HKDF + AES-256-GCM pipeline (the escrow spikes `spikes/05-recovery-escrow/`
    … `spikes/09-escrow-auth/`, ported to `deploy/element-web/rednet-module/`)
  - The `mode` flag logic (passphrase-default vs. moderators-only opt-in)
  - The threat analysis in `RECOVERY.md` §4 (seizure properties by mode)
  - The test vectors (47/47 behavioral tests) as the specification
  - `setup.sh` hardening and two-tier isolation are in-scope but secondary
- **Form:** an external reviewer with applied-crypto expertise (not necessarily Matrix-specific; the
  crypto primitives are standard). Provide: the spikes with test harnesses, `RECOVERY.md`, `DESIGN.md`,
  the threat model, and the TS source. Budget for a focused 1–2 week engagement, not a full-product audit.
- **Labeling:** until the external review lands, all escrow-related documentation and UI must carry an
  **"experimental — not yet externally reviewed"** label. Phase 0 (device-only) and Phase 1 (passphrase,
  no escrow store) do not require this label.
- **Acceptance:** findings triaged; criticals fixed and re-reviewed; the passphrase-default blast-radius
  property and the seizure properties explicitly signed off against the threat model.

## 2. Pin every image to a digest 🔬 ✅ DONE (2026-06-16)

- **Done:** all 8 registry images in `deploy/docker-compose.yml` + the Element Dockerfile bases (node, caddy)
  - setup.sh's `MASIMG` are pinned to multi-arch `@sha256:` digests (MAS 1.19.0, Synapse 1.155.0, Caddy
    v2.11.4, Draupnir v3.1.0, postgres 16-alpine, prometheus/grafana/pushgateway, node 22-bookworm). The
    pinned stack was smoke-tested: boots + self-checks pass.
- **Remaining (operational, at deploy):** re-verify each digest against the project's published release for
  that version before trusting it (the compose header notes this); a documented bump = re-pin + re-review.
- _Note: the `spikes/` test harnesses stay on floating tags on purpose; they're ephemeral dev scaffolds,
  not the shipped artifact._

## 3. Real two-host deploy dry-run 🎯

The `ansible/` scaffold is YAML-valid but never run against real hosts.

- **Action:** provision a throwaway CORE + FRONT, run `ansible/site.yml`, bring up WireGuard.
- **Acceptance:** front proxies to the core over WG; **the core has no public inbound except the WG port**
  (verify with an external port scan); `FrontTripwire` fires within ~3 min when the front is killed;
  burn-and-replace a front works; `server_name` immutability respected.

## 4. Build + validate the Element fork 🎯

The `element-web/` build context ships a CryptoSetupExtensions module + a 51-line `integration.patch`
anchored to v1.11.86 (applies clean; sentinel `REDNET_SILENT_ONBOARDING=on` confirms). Browser E2E
proven (2/2 PASS, 2026-06-19). Silent onboarding + passphrase recovery work end-to-end.

- **Action:** `docker compose --profile web build` (or `ci-check.sh --build`); if upgrading
  `ELEMENT_VERSION`, re-anchor `integration.patch` against the new tag and re-run the E2E test.
- **Acceptance:** fresh-account login shows **our** "Save your recovery passphrase" dialog (not Element's
  setup UI) and cross-signing is green; a fresh device recovers identity + history from the passphrase;
  locked to our homeserver; mobile path is **stock Element X from a public app store** (no sideload/MDM).

## 5. Secrets & key custody in production 🎯/🔬

`setup.sh` generates secrets into gitignored files. Fine for dev, not a production strategy.

- **Action:** decide custody for the MAS encryption key, the Synapse signing key, the DB password, and the
  **restic repo password** (must live OFF the core, or a core seizure rewrites backup history).
- **Acceptance:** no secret recoverable from a seized core alone for the off-core ones; a documented
  rotation procedure; the backup repo is append-only.

## 6. Backup + restore drill 🎯

Spike 04 proved restore works; production needs it to be _scheduled and rehearsed_.

- **Action:** schedule `backup.sh` with `RESTIC_REPOSITORY`/`RESTIC_PASSWORD`; run a **real restore drill**
  onto a clean box; confirm the heartbeat + `BackupHeartbeat*` alerts.
- **Acceptance:** a documented, time-boxed restore that a second operator can execute from the runbook.

## 7. Alert delivery 🔬 ✅ DONE (2026-06-16)

- **Done:** Alertmanager added to the `monitoring` profile (digest-pinned, 127.0.0.1:9093), Prometheus
  wired to it (`monitoring/prometheus.yml` `alerting:` block), routing in `monitoring/alertmanager.yml`.
  Verified end-to-end: Prometheus shows AM active; an injected alert is received, grouped, routed to the
  `rednet-oncall` receiver, and AM **attempts** webhook delivery (the placeholder sink fails as expected).
- **Remaining (deploy-config):** set the real receiver URL in `monitoring/alertmanager.yml` to an
  **out-of-band** channel: Slack/PagerDuty/email/SMS or Matrix on a DIFFERENT homeserver, **never this
  deployment** (a down/seized REDnet can't page you through itself). Document the on-call path.

## 8. Log & metadata hygiene audit 🔬 ✅ DONE (2026-06-16) → `deploy/LOG-HYGIENE.md`

Audited Synapse/MAS/Caddy on a running stack with real login traffic. Key finding: **MAS retained
IPs/UAs unbounded** (incl. the registration IP), the one surface that broke the threat-model claim.

- **Fixed + verified:** `scrub-metadata.sh` NULLs MAS's IP/UA columns (verified erasing injected IPs);
  Synapse per-request access logging (`client_ip {@mxid} path`) suppressed via the `synapse.access`
  logger (verified gone). Synapse `user_ips` already bounded by `user_ips_max_age:1d`.
- **Remaining (deploy-config):** Docker daemon log rotation (`daemon.json`, snippet in LOG-HYGIENE.md) to
  bound Caddy/front error-log IPs; schedule `scrub-metadata.sh` hourly alongside `backup.sh`.
- **Outcome:** who-talked-when is now bounded to deliberate windows (1 d Synapse IPs, scrub-interval MAS
  IPs, rotation-window logs). No unbounded structured IP store remains. The inventory is the artifact the
  #1 security review checks against the threat model.

---

## Suggested sequence

1. ~~**#2 pin digests**~~ ✅ done. Supply chain locked.
2. ~~**#7 alert delivery pipeline**~~ ✅ done. Only the real receiver URL remains (deploy-config).
3. ~~**#8 log/metadata hygiene audit**~~ ✅ done. MAS IP scrub + Synapse access-log suppression built+verified.
4. **#1 security review** (🎯, long lead time). Commission before any Phase-2 code ships; runs in parallel.
5. **#4 Element build** + **#3 two-host dry-run** + **#6 restore drill** (🎯): the real-target validations.
6. **#5 secrets/custody** (🎯): finalize alongside the two-host work.

**All in-sandbox option-2 work is complete.** Every remaining step (🎯) is gated on a real deploy target
(hosts / devices / people): the #1 security review (the gate before Phase-2 code ships), the Element build,
the two-host dry-run, the restore drill, and secrets/custody. There is no further in-sandbox hardening to do.

---

## Continuity and handoff

REDnet currently has a bus factor of one. Before deploying for real users, address:

- **Documented runbook:** backup/restore, operator bootstrap, secret rotation, Synapse upgrade, Element
  fork rebase. Each procedure should be executable by a second person who reads the docs cold.
- **Second operator:** at minimum, a second person with admin credentials, access to the backup repo
  password, and familiarity with the bootstrap chain. `bootstrap-operator.sh` supports this.
- **Upstream-track plan:** Synapse, MAS, and Element all release frequently. Document the rebase/re-pin
  procedure for the Element fork (`integration.patch` re-anchor) and the digest-pinned images.
- **Community handoff scenario:** if the sole maintainer becomes unavailable, what happens? At minimum:
  the server keeps running (Docker restart policies), backups keep running (cron), but no new members can
  be onboarded and no security patches land. Document this honestly for operators.
