# REDnet — security review (round 2, full swarm)

**Date:** 2026-06-17 · **Method:** 9-dimension AI swarm → adversarial adjudication (71 agents, ~5M tokens) →
[synthesis agent died on a 529 overload; findings below are the adjudicated set]. **Reviewer:** AI, not an
independent human expert.

## ⚠️ Read `SECURITY-REVIEW-round1.md`-style caveat first

There is **no budget for the independent external review** `PRODUCTION.md §1` names as the non-skippable gate.
This is an AI review — strong at concrete, checkable flaws (it found 53 real ones here, several verified
against Synapse 1.155.0 source), weak at novel-attack creativity and live-protocol behavior under attack.
It **cannot clear REDnet for at-risk deployment.** Round 1's reviewers were rate-limited; this round 2 ran the
full swarm against the registration-fix'd tree and is the authoritative finding set.

## Tally (adjudicated severity)

| critical | high | medium | low | info | total |
| -------- | ---- | ------ | --- | ---- | ----- |
| 1        | 8    | 16     | 21  | 7    | 53    |

**Dominant themes:** (1) the production **two-host topology is where the danger concentrates** — the single-host
scripts, run on a real core, undo the "dark core" property; (2) **mitigations documented as done are not
enforced as code** (the IP scrub, log rotation, and hardening-on-restore exist as prose/one-shots, not
scheduled/guaranteed); (3) **secrets + crown-jewel backups sit world-readable and un-shredded on the seizable
core**; (4) the **escrow/onboarding trusts server-controlled inputs** a malicious core can manipulate.

## Remediation status

**Pass 1 (2026-06-17) — the seized-core data-at-rest cluster, fixed + verified in-sandbox:**

- ✅ **HIGH** Synapse `devices` table now scrubbed (`scrub-metadata.sh`; verified: injected IPs → 0).
- ✅ **HIGH** Backup captures the hardened `homeserver.yaml`; cleartext crown-jewel bundle **shredded after restic upload** (verified) + loud warning if it stays on the core.
- ✅ **HIGH** `restore.sh` restores the hardened config + the MAS shared secret and **fail-closes** if the restored config isn't hardened (federation/MAS/retention asserted) — the honeypot can't come back open.
- ✅ **MEDIUM** scrub runs in a single transaction with `ON_ERROR_STOP` (a schema change aborts loudly, not silently).
- ✅ **MEDIUM** secret-file perms: `.env` 0600; `mas/config.yaml` chowned to the MAS uid + 0600 under root (Ansible), readable fallback in dev — the umask-vs-container-mount trap handled per-file.
- ✅ **LOW** `trusted_key_servers: []` (drops the outbound matrix.org dependency) + `rc_invites` added (SPEC §4).

**Pass 2 (2026-06-17) — the two-host topology cluster. Code/config in; the load-bearing DNAT-bypass
property is validated in-sandbox (pass 5) AND end-to-end on real KVM VMs (pass 6 — core proven dark
off-host); setup.sh changes verified backward-compatible (single-host PASS):**

- ✅ **CRITICAL** core-not-dark: `setup.sh` honors `REDNET_ROLE=core` → renders+hardens but starts **no caddy / no public host port**; Ansible adds a **`DOCKER-USER` iptables DROP** for public-NIC→container forwarding (the robust fix — UFW alone can't stop Docker's DNAT), so the core stays dark even with a stray bind. **The DNAT-bypass mechanism AND this fix are now validated in-sandbox** (pass 5, `validate/validate-docker-firewall.sh`): a privileged docker-in-docker microcosm + an off-host nmap scan confirm UFW/INPUT deny leaves a published port OPEN, and the interface-scoped `-i <wan> -j DROP` CLOSES it (iptables counters prove which rule fired). The test also caught a trap: a port-matched rule (`--dport 8008`) silently does NOT work because PREROUTING DNAT rewrites the dest port before FORWARD — `site.yml` correctly uses the interface form.
- ✅ **HIGH** WG-port scoping: Ansible scopes wg0-inbound to only `8008/8080/8088/9091` from the front, denies the rest (a seized front no longer has L3 reach to every core port).
- ✅ **HIGH** scrub + backup **now scheduled**: Ansible installs hourly systemd timers for `scrub-metadata.sh` + `backup.sh` on the core (was prose-only).
- ✅ **MEDIUM** Docker daemon **log rotation** templated on both hosts (bounds Caddy/front client-IP error logs).
- ✅ **MEDIUM** `http://localhost` OIDC issuer: new `REDNET_PUBLIC_BASE` (https://domain in prod) drives MAS issuer/public_base + Synapse public_baseurl + the well-known; warns if not https in core mode.
- ⏳ **HIGH** standing synapse-admin token (Draupnir + `rednet-system`): scope-down (drop the admin grant + `enableMakeRoomAdminCommand:false`, use room PL) needs its own verify cycle → **pass 3**; meanwhile the honest residual is that the running bots hold admin on the seized core (DESIGN's "no standing admin" holds only for the GitOps plane).

**Pass 3 (2026-06-17) — recovery-crypto + supply-chain. Module/doc fixes in; the admin scope-down verified:**

- ✅ **HIGH** standing synapse-admin token removed: `rednet-system` + `rednet-mod` no longer created `--admin`, tokens no longer `--yes-i-want-to-grant-synapse-admin-privileges`, `enableMakeRoomAdminCommand: false`. **Verified: rooms + auto-join + Draupnir all still PASS without admin** — the core holds no live god-credential.
- ✅ **MEDIUM** `§4` threat table **split by mode** + the honest headline (default moderators-only: M-quorum ± seized core → reads **every** member; clean property only for passphrase mode).
- ✅ **MEDIUM** malicious-core onboarding branch: `silentBootstrap` now **refuses to re-provision** if secret storage exists server-side OR a local onboard-marker is set (a malicious core can't silently reset a returning member's identity); records the marker after onboarding.
- ✅ **MEDIUM** diceware floor: default **7 words**, requires the **EFF-large (7776)** list (rejects 2048), **rejection-sampling** (no modulo bias), ~104-bit alphanumeric fallback.
- ✅ **MEDIUM** ECIES on-curve point validation + AAD-oracle regeneration recorded as required `§12` hardening (+ a negative test vector).
- ✅ **MEDIUM** degraded-build now **machine-detectable**: the Dockerfile greps the built bundle for a soft-fork sentinel, writes `rednet-build.txt` (on/off), warns loudly, fails if `REDNET_REQUIRE_SILENT_ONBOARDING=1`.

**Pass 4 (2026-06-17) — the front-proxy boundary + quick wins. Caddyfile changes verified single-host:**

- ✅ **front reverse-proxy hardened** (several findings): client-supplied `X-Forwarded-For`/`X-Real-IP`/`Forwarded` **sanitized** (no IP spoofing to the core); federation/server-key/metrics/admin **blocked at the edge**; matchers made **case-insensitive** (verified: `/_SYNAPSE/ADMIN` → 403). Applied to dev + prod templates.
- ✅ MAS `trusted_proxies` tightened from the over-broad default to the docker network (`172.16.0.0/12`).
- ✅ Draupnir **management room locked** (`invite`/`state` require PL≥50) — a member can't pull an outsider into the plaintext command channel.
- ✅ Ansible **WG key material gitignored**; rsync to the core **excludes all dev secrets** (+ templates a production `rednet.env` from vars, closing the missing-env orchestration gap).
- ✅ Element Web **commit-SHA pin** supported (`ELEMENT_COMMIT`), warns when building from the movable tag.

**Pass 5 (2026-06-17) — in-sandbox validation of the load-bearing CRITICAL (correcting an earlier "needs VMs" overclaim):**

- ✅ **CRITICAL fix VALIDATED in-sandbox**, not just asserted. New `validate/validate-docker-firewall.sh` stands up a privileged docker-in-docker "core" + a separate scanner on a shared segment and runs a real off-host `nmap`: (a) UFW/INPUT deny leaves the Docker-published port **OPEN** (the vulnerability reproduced); (b) `site.yml`'s interface-scoped `DOCKER-USER -i <wan> -j DROP` flips it to **CLOSED**; iptables packet counters prove which rule fired (0 pkts on the trap rule, 2 on the real one).
- ✅ **New finding from running it:** a port-matched `DOCKER-USER` rule (`--dport <published>`) is a **silent no-op** — PREROUTING DNAT rewrites the dest port before the FORWARD chain, so it never matches and the core would _look_ firewalled while wide open. Confirmed `site.yml` uses the correct interface form; documented the trap in the script so it can't regress.
- ✅ **NEW finding (HIGH, same root cause) — WG aperture was scoped in the wrong chain.** Running `validate/validate-wg-aperture.sh` proved that `site.yml`'s "deny everything else on wg0" (a `ufw … direction: in` = **INPUT-chain** rule) does **not** restrict WG-published container ports: with the deny in place, a published `:5432` stayed **reachable from the front** (DNAT → FORWARD bypasses INPUT). Today this is latent (only the 4 intended proxy ports are WG-published, so no live hole), but the rule presented as the HIGH "seized front can't reach the data plane" mitigation did nothing for the ports it named. **Fixed:** added a `DOCKER-USER` wg0 aperture (allow only the 4 proxy ports, matched on the **original** pre-DNAT dport via `conntrack --ctorigdstport` from `wg_front_ip`; drop the rest), so a future stray `wg_core_ip:5432:5432` fails closed. The ufw rules are kept + relabelled as host-bound defense-in-depth. Validated: allowed port OPEN, denied port CLOSED.
- ✅ **Incidental: `site.yml` would not have parsed.** A task name contained `: ` (`… core (R2: exclude …)`) — unquoted, YAML reads it as a mapping. The SCAFFOLD playbook had never been parsed; quoted it (and swept for others — none). Without this the whole two-host provision fails on load.
- ⚠️ **Correction:** prior passes said this property could only be proven on real VMs. That was wrong — the box has `sudo` root + privileged-container caps (`CapEff: 000001ffffffffff`), enough for real `iptables`/`netns`/`veth`/dind. What genuinely still needs the VM harness: systemd-timer + `ufw`/`netplan` provisioning fidelity, the end-to-end WG tunnel + onboarding, and init/boot-order behavior — not the DNAT-bypass or aperture-scoping mechanics, which are now proven in-sandbox.

**Pass 6 (2026-06-18) — END-TO-END validation on real KVM VMs. The two-host deploy went from "never executed" to provisioning cleanly + the core proven dark on real hardware.**

- ✅ **The whole two-host topology was provisioned on two real Ubuntu 22.04 KVM VMs** (core + front on a host-only bridge the host also sits on), via a new VirtualBox-free harness (`validate/kvm-up.sh`, `kvm-down.sh`; `validate.sh` made dual-mode with `RVAL_MODE=ssh`). `validate.sh` → **PASS**: core **DARK** off-host (all 9 service ports closed; services bind only the WG IP or localhost), front reachable, WG aperture scoped (postgres blocked), scrub+backup timers firing.
- ✅ **CRITICAL re-darkening proven on real hardware (the capstone).** Published a _stray_ `0.0.0.0:9999` on the core (the exact original CRITICAL: a stray public bind). Off-host it scans **`filtered`**, and the `DOCKER-USER -i eth1` DROP counter ticked **0 → 2 packets** — the firewall actively dropped real off-host SYNs crossing a real kernel's netfilter. Not a container simulation: the deployed system on the actual Ansible path (ufw/netplan/systemd/WireGuard all real).
- ⚠️ **Running it surfaced SIX execution-blocking latent bugs — the SCAFFOLD playbook had never been run end-to-end and was non-functional on a clean host. All fixed:**
  1. `site.yml` task name with `: ` → YAML would not parse (pass-5, re-confirmed).
  2. `docker-compose-plugin` isn't in Ubuntu repos → use `docker-compose-v2` (`site.yml`).
  3. `community.docker.docker_container` (front Caddy) needs `python3-docker` on the target → added.
  4. `setup.sh` hard-depended on `uv` (dev-only) to render MAS config → fall back to system `python3` + `python3-yaml` (declared in `site.yml`).
  5. Element `Dockerfile` had inline `# comments` on two `FROM` lines → Dockerfiles parse `#` as args ("FROM requires one or three arguments") → moved annotations to their own lines.
  6. Front play templated into `/opt/rednet-front/` without creating it → `template` won't make parents → added a `file: state=directory` task.
- ⏳ **Deferred (not a security gap):** the Element Web **webpack app-build** (heavy, separate deploy-time step by design) was excluded from this run; the core **infra** (synapse/MAS/postgres/monitoring) was brought up to exercise the WG publish + firewall. So WG `:8088` (element) reads UNREACHABLE in `validate.sh` #3, and the front→core proxy (#5) returns HTTP 000 because Caddy can't ACME-issue for the fake test domain `rednet.test`. Both are test-env artifacts, not topology failures. A real deploy with a real domain + the element build closes them.

### Documented residuals / accepted or deferred (no code fix this round)

These are real but are accepted trade-offs, need a design decision, or need real-host work — flagged so a
deployer treats them as open, not closed:

- **FrontTripwire is forgeable** by an adversary who seizes the front (it's a one-way heartbeat). True fix = the core actively challenge-response polls the front; an enhancement, not yet built. Heartbeat-absence remains a _necessary_ signal.
- **restic repo password "held off the core" is not enforced** — it's an operational discipline (set it off-box); document in the runbook.
- **Web-vs-mobile metadata asymmetry**: only the Element Web fork suppresses typing/receipts; stock Element X can't be forced (ARCHITECTURE §6). Steer high-risk users to the web client — a policy, not a patch.
- ~~**Does the core need to see client IPs at all?**~~ ✅ **RESOLVED — placeholder adopted.** The front now forwards a constant `192.0.2.1` instead of the real client IP; the core records the placeholder (verified: `user_ips`/`devices` = `192.0.2.1`). Per-IP login throttling loosened on the core (now the front's job); per-account brute-force defense kept tight. The scrub/retention work is now defense-in-depth. **The core is no longer an IP honeypot.**
- ~~**Two-host orchestration is under-baked**~~ → **largely resolved (pass 6).** The deploy now provisions end-to-end on real KVM VMs (6 execution-blocking bugs fixed) and the core is proven dark off-host. What still wants a real-domain deploy (not the sandbox): the Element webpack **app-build** + the post-front **self-check/`bootstrap-rooms.sh`/`bootstrap-draupnir.sh`** onboarding, and ACME TLS (needs a public domain). The network/firewall/WG/timer topology is validated.
- Minor/doc: digest pins not signature-verified (re-verify at deploy, PRODUCTION #2); hardening one-shot lacks drift detection (the self-check partially covers); Synapse `/_synapse/admin` not disabled at Synapse itself (blocked at the front + the DOCKER-USER firewall); ephemeral system-account passwords passed as argv.

## CRITICAL

#### CORE is NOT dark: setup.sh starts Caddy bound to 0.0.0.0:8080 on the core, and Docker port-publishing bypasses the UFW default-deny

_dimension:_ `topology-wireguard` · _confidence:_ high

- **Evidence:** deploy/ansible/site.yml:36 runs `./setup.sh` on the CORE host (chdir /opt/rednet). setup.sh:111
  runs `docker compose up -d synapse caddy` WITHOUT the WG override file. The base service
  deploy/docker-compose.yml:63-64 publishes caddy as `"${REDNET_HTTP_PORT:-8080}:8080"` — i.e.
  0.0.0.0:8080. The WG override (docker-compose.wg.yml.j2) is only passed to the SECOND, separate
  compose invocation at site.yml:39-42 (which omits caddy from its service list), so it never re-
  scopes the already-running caddy container. The core UFW (site.yml:19-23) allows only 22/tcp +
  wg_listen_port/udp and default-denies inbound — but `grep` confirms NO `/etc/docker/daemon.json
iptables=false`, NO `DOCKER-USER` chain rule, and NO ufw-docker anywhere in deploy/. Docker
  inserts its DNAT/forward rules into the `DOCKER` chain, which iptables evaluates BEFORE UFW's
  `ufw-user-input` chain.
- **Impact:** Defeats the central security property of the whole design ('a fully seized core must yield as
  little as possible' / 'no public inbound except the WireGuard port'). A second, plaintext-HTTP
  Caddy reachable at the core's PUBLIC IP:8080 reverse-proxies straight to Synapse C-S (8008) and
  MAS (8080) over the docker network. The dark core is directly reachable and fingerprintable from
  the open internet (Shodan-discoverable Matrix/MAS endpoints tied to the core's real IP), bypassing
  the disposable front entirely. An adversary who learns the core IP (e.g. from a seized front's
  wg0.conf Endpoint, or scanning) can hit the homeserver login/registration and `/_matrix/*` without
  ever touching the front, and the metadata-minimization and 'burn the front' story collapse.
- **Fix:** Do not run setup.sh's single-host `up` path on the core. Either (a) split setup.sh into a
  'render/harden only' mode (no `docker compose up caddy`) invoked by Ansible, then bring the data
  plane up exclusively via the explicit override command at site.yml:39-42; or (b) make the core's
  compose invocation ALWAYS include `-f docker-compose.wg.yml` and add a `caddy: { deploy: { replicas:
0 } }`/profile exclusion so caddy never starts on the core. Independently, add a `DOCKER-USER`
  iptables rule (or `ufw-docker`) on the core that drops all inbound to published container ports
  except from the WG subnet, so a stray 0.0.0.0 bind can never be reached publicly. Add a post-deploy
  assertion: from off-host, `nc -vz core_public_ip 8080/8008/8080` must fail.

## HIGH

#### The MAS IP scrub is never scheduled — registration IP store is unbounded, contradicting LOG-HYGIENE's 'closed' claim

_dimension:_ `metadata-hygiene` · _confidence:_ high

- **Evidence:** deploy/scrub-metadata.sh exists but NO cron/systemd timer invokes it anywhere in the repo. Grep
  across deploy/ansible/, _.md, _.sh, \*.j2 for scrub-metadata finds only the script itself + prose
  'schedule hourly' (deploy/LOG-HYGIENE.md:43, PRODUCTION.md:91). deploy/ansible/site.yml installs
  services and even creates a systemd timer for the front heartbeat (site.yml:86-98) but creates
  NO timer/cron for scrub-metadata.sh or backup.sh. LOG-HYGIENE.md:11/32/35 and the whole 'No
  UNBOUNDED structured IP store remains' verdict are conditioned on '...once scrub-metadata.sh is
  scheduled' — that scheduling does not exist.
- **Impact:** On a seized core, MAS retains IP/UA across all 7 scrubbed tables WITHOUT BOUND — most damningly
  user_registrations.ip_address, the exact IP every account was created from (scrub-
  metadata.sh:5-6). That is a permanent who-registered-from-where deanonymizer linking each MXID to
  a real client IP at account birth. This is the single finding LOG-HYGIENE.md states 'broke the
  model, and it's closed' (line 35-36) — it is NOT closed; the mitigation is a manual command no
  automation runs. For ICE/state-actor seizure this is the worst-case metadata leak the audit
  purports to eliminate.
- **Fix:** Ship the schedule as code, not prose: add a systemd timer + service (mirroring site.yml:86-98 front-
  heartbeat pattern) running `/opt/rednet/scrub-metadata.sh` on the CORE, e.g. OnUnitActiveSec=1h, plus
  an equivalent timer for backup.sh. Add a Prometheus alert (like BackupHeartbeatStale) on a scrub
  heartbeat so a stopped scrub is detected. Until automated, LOG-HYGIENE.md must downgrade status #1
  from '✅ built + verified' to 'mitigation NOT enforced — unbounded'.

#### Audit misses the Synapse `devices` table — per-device ip/user_agent/last_seen NOT bounded by user_ips_max_age

_dimension:_ `metadata-hygiene` · _confidence:_ high

- **Evidence:** LOG-HYGIENE.md only inventories Synapse `user_ips` (#3), bounded by user_ips_max_age:1d
  (setup.sh:85). The `devices` table — listed as core Synapse state in ARCHITECTURE.md:64 —
  independently stores ip, user_agent, and last_seen_ts per device, and is NOT pruned by
  user_ips_max_age (that setting only governs user_ips/user_daily_visits). No config in setup.sh
  or scrub-metadata.sh touches `devices`. Synapse also retains user_daily_visits aggregates;
  neither is in the audit.
- **Impact:** A seized core's `devices` table yields, for every device of every user, the IP and User-Agent
  recorded at device creation/last refresh — a long-lived MXID↔IP link that survives the 1-day
  user_ips window. For at-risk users this re-introduces exactly the who-logged-in-from-where surface
  the audit claims to bound to 1 day. The audit's residual quantification (LOG-HYGIENE.md:28-36) is
  therefore wrong: it omits a populated IP store.
- **Fix:** Either (a) extend scrub-metadata.sh to NULL synapse.devices.ip and synapse.devices.user_agent (verify
  against the Synapse 1.155.0 schema; these are non-key columns, safe to NULL), or (b) document
  explicitly that device-creation IPs persist for the device lifetime and adjust the threat-model
  claim. Re-run the metadata-column sweep SECURITY-REVIEW.md:22 lists as 'not yet done' across the full
  synapse schema, not just user_ips.

#### Postgres WAL + plaintext MAS backups snapshot pre-scrub IPs, bypassing the scrub entirely

_dimension:_ `metadata-hygiene` · _confidence:_ high

- **Evidence:** backup.sh:16 runs `pg_dump -Fc ... mas > $OUT/mas.dump` into backups/ on the CORE disk
  (OUT=backups/<ts>, backup.sh:8). .gitignore confirms 'Backups — contain the MAS encryption key +
  full DB dumps' live on-core. Any backup taken between scrub runs captures a full plaintext
  snapshot of last_active_ip/ip_address/user_agent across all MAS tables. Separately, Postgres WAL
  retains the old (pre-NULL) tuples until checkpoint/vacuum; scrub-metadata.sh issues bare UPDATEs
  (lines 17-23) with no FULL vacuum, so superseded row versions persist in the heap/WAL.
- **Impact:** The scrub gives a false sense of erasure: a seized core that holds backups/ (default location) or
  un-checkpointed WAL recovers the very IPs the scrub NULLed. With hourly scrub but, say, 6-hourly
  backup, every backup is a 6-hour-granularity IP archive of who-registered/connected — directly
  defeating the 'IP retention ≤ one interval' claim (LOG-HYGIENE.md:32).
- **Fix:** State plainly in LOG-HYGIENE.md that the scrub does not erase backups or WAL history. Hold backups
  OFF the core (restic to append-only object storage with the repo key off-box, as backup.sh:30-39
  contemplates) and delete the local backups/ dir after upload. Consider VACUUM after scrub if heap-
  residue matters, and note WAL/PITR retains pre-scrub tuples for the WAL window. Do not dump MAS IP
  columns into backups at all — exclude or pre-scrub before pg_dump.

#### Backup bundle (MAS encryption key + both DB dumps + signing key) is left on the core disk in cleartext, world-readable, and never shredded after restic upload

_dimension:_ `secrets-custody` · _confidence:_ high

- **Evidence:** deploy/backup.sh:8-22 writes synapse.dump, mas.dump, signing.key, mas-config.yaml, media.tar
  into `backups/$(date ...)`. The restic block (lines 33-39) reads `-v $PWD/backups:/backups:ro`
  but there is NO `rm`/`shred`/`trap` cleanup afterward — `grep -nE 'rm |shred|cleanup|trap|chmod'
backup.sh` returns nothing. Files inherit umask 0002 → 664. backups/ is gitignored
  (.gitignore:14-15) but that does not affect on-disk perms or persistence.
- **Impact:** RECOVERY.md §1 states the MAS key + key-backup material is 'the one secret that turns encrypted
  history on a seized server into plaintext.' Every backup run leaves a complete, decryptable copy
  of that crown jewel sitting unencrypted on the core's filesystem indefinitely, world-readable. A
  core seizure or disk image captures not just the live DB but an accumulating pile of full
  plaintext snapshots — directly defeating the 'fully seized core must yield nothing usable' prime
  directive (RECOVERY.md §1, threat model).
- **Fix:** Write the bundle to a mode-0700 dir with `umask 077`; after a successful restic upload, `shred -u`
  (or at minimum `rm -f`) the plaintext bundle via a `trap ... EXIT`. If restic is not configured,
  refuse to leave the bundle (warn loudly) or stage it on tmpfs. Never let cleartext crown-jewel
  snapshots accumulate on the seizable core.

#### A seized front has layer-3 reach to EVERY port on the core's WireGuard IP; no core-side firewall scopes WG-inbound to the 4 intended services

_dimension:_ `topology-wireguard` · _confidence:_ high

- **Evidence:** deploy/ansible/templates/wg-front.conf.j2:9 sets `AllowedIPs = {{ wg_core_ip }}/32` — the front
  routes to the entire core WG IP. The core UFW rules (site.yml:19-23) govern only the PUBLIC
  interface (22 + wg_listen_port) and default-deny inbound, but there is no rule restricting
  traffic that arrives ON the wg0 interface; WireGuard-decapsulated packets to wg_core_ip are
  delivered to any listening socket. There is no `iptables -A INPUT -i wg0 -p tcp -m multiport
--dports 8008,8080,8088,9091 -j ACCEPT` + drop-rest. Today only those 4 ports are host-published
  on the WG IP (override is correctly scoped), but the topology relies entirely on 'nothing else
  happens to bind the WG IP' with zero defense-in-depth.
- **Impact:** The blast radius of a front seizure is 'all of the core WG IP', not 'the 4 proxy ports'. The
  moment any future service, debug listener, or a mis-scoped `0.0.0.0` bind lands on the core, the
  seized front reaches it over the tunnel with no second barrier. Given the threat model treats the
  front as fully compromisable, the WG tunnel should be the narrowest possible aperture, not an open
  L3 path to the core.
- **Fix:** Add a core-side firewall on the wg0 interface that allows inbound only to 8008/8080/8088/9091 from
  wg_front_ip and drops everything else (ufw `allow in on wg0 to any port <p>` for each, then `deny in
on wg0`). This is the single highest-leverage hardening for the 'front is seizable' assumption and
  makes the override's port scoping enforced rather than assumed.

#### Degraded-build fallback changes the recovery mechanism (Security Key, not passphrase) and breaks the documented N=1 / no-old-device recovery promise — not merely 'stock onboarding'

_dimension:_ `supply-chain-fork` · _confidence:_ medium

- **Evidence:** When integration.patch does not apply, MatrixChat.onLoggedIn never runs
  silentBootstrap/recoverWithPassphrase (integration.patch:40-60), so generateRecoveryPassphrase
  is never called and no passphrase is shown. The client falls back to Element's stock flow under
  config.json:17-22 (`io.element.e2ee.secure_backup_required: true`, `secure_backup_setup_methods:
["key"]`). That stock flow provisions a 48-char base58 _Security Key_, and crucially
  getRednetSecretStorageKey is also unwired (integration.patch:20-32), so on a FRESH DEVICE
  Element pops its own 'enter your Security Key / verify with another device' dialog — exactly the
  path README.md:16-18 says failed in prototype milestone D (a fresh Element login re-nags).
- **Impact:** The fork's headline guarantee — 'a fresh device recovers identity + history from a passphrase
  alone, no old device, works at N=1' (rednet-onboarding.ts:5-9, README.md:43-54) — silently
  degrades to stock Element, which for recovery on a new device effectively requires either the
  base58 Security Key the user was never coached to save OR a second logged-in device to verify
  against. A lone founder or a user whose only device was seized/lost is locked out of their cross-
  signing identity and message history. The Dockerfile/README frame this fallback as cosmetic ('just
  with Element's stock onboarding', Dockerfile:21-22; README.md:38-41); it is a recovery-capability
  regression, which is more dangerous for this threat model than a branding regression.
- **Fix:** Treat a patch miss as a recovery-capability failure, not a cosmetic one. Tie this to the
  detectability fix above (fail or loudly flag the build). Update the Dockerfile:21-22 and
  README.md:38-41 wording to state plainly that the degraded build changes the recovery mechanism and
  can leave new-device/N=1 users unable to recover, so it must never ship to end users without the
  PRODUCTION.md #4 fresh-account AND fresh-device validation both passing. Consider making
  `secure_backup_setup_methods` and the onboarding wiring fail closed together so a half-configured
  client can't reach end users.

#### Disaster-recovery restore silently strips Synapse hardening — the honeypot comes back UNhardened

_dimension:_ `systemic` · _confidence:_ high

- **Evidence:** deploy/restore.sh:31 runs `docker compose run --rm -T synapse generate`, which overwrites
  /data/homeserver.yaml with Synapse's DEFAULT config; it then restores only the signing key (line 33) and merely PRINTS an instruction (lines 35-36: 're-run ./setup.sh to render the hardened
  config ... or restore a saved homeserver.yaml'). The automated steps never re-apply hardening.
  Compounding it, deploy/backup.sh:14-22 captures the two DB dumps + signing key + mas/config.yaml + media but does NOT capture the hardened homeserver.yaml at all (the loop at backup.sh:27 only
  requires synapse.dump, mas.dump, signing.key, mas-config.yaml). So there is no 'saved
  homeserver.yaml' to restore unless the operator made one out-of-band. ARCHITECTURE.md:104
  nonetheless presents backup/restore as Spike-04-'✅' complete and lists the captured set without
  flagging the missing Synapse config.
- **Impact:** DESIGN.md treats core loss as a first-class, expected event ('core dies → cold restore from
  backup', ARCHITECTURE.md:163; PRODUCTION.md gates on a restore drill). If an operator follows
  restore.sh as written and starts the stack before manually re-running setup.sh, the recovered
  homeserver boots with Synapse defaults: a federation listener present (closed-federation invariant
  broken), presence enabled, NO retention purge jobs (the single biggest honeypot lever, DESIGN §10,
  silently off so message bodies stop expiring), default registration behavior, and — most severely
  — WITHOUT the matrix_authentication_service delegation block and with password_config re-enabled.
  That can mean an open / mis-authenticated homeserver and an un-expiring metadata store, produced
  exactly when operators are stressed and racing to restore service. The hardening that the entire
  Tier-1 claim rests on is lost on recovery, undetectably (the stack 'works').
- **Fix:** Make hardening survive restore by construction: (1) add /data/homeserver.yaml (and the log_config) to
  backup.sh's capture set and have restore.sh place it back instead of running `synapse generate`; OR
  (2) have restore.sh invoke setup.sh's hardening render automatically (non-interactively) before any
  `docker compose up`, and fail-closed if the post-restore config lacks federation_domain_whitelist:[]
  / retention / matrix_authentication_service. Add a post-start self-check (reuse setup.sh's HARD=
  probe at lines 133-134) that REFUSES to mark restore successful unless the hardening assertions pass.
  Update ARCHITECTURE.md:104 to stop implying the captured set is restore-complete.

#### Standing synapse-admin token lives on the running core (Draupnir + system bot) — contradicts the load-bearing 'no live god-credential to coerce' seizure claim and is even written into backups

_dimension:_ `systemic` · _confidence:_ high

- **Evidence:** DESIGN.md:195 claims 'No standing admin access = no live god-credential to coerce', and
  SPEC.md:159 explicitly calls Draupnir's provisioning 'consistent with no-standing-admin (DESIGN
  §11)'. But deploy/bootstrap-draupnir.sh:19 mints the bot a compatibility token with `--yes-i-
want-to-grant-synapse-admin-privileges`, and deploy/draupnir/production.yaml.example:22 confirms
  'bot token holds synapse-admin' (enableMakeRoomAdminCommand:true). The token is written at rest
  into draupnir/config/production.yaml (bootstrap-draupnir.sh:37-39) on the always-running core.
  deploy/bootstrap-rooms.sh:18 likewise creates rednet-system `--admin` and mints an admin token.
  SPEC.md:159 further states 'Draupnir's bot token is a tracked backed-up secret' — i.e. the admin
  credential is also copied off the box in backups. MAS compat tokens are long-lived (no expiry
  unless revoked).
- **Impact:** A seized RUNNING core (THE central threat-model scenario, DESIGN §9 row 1) yields a live synapse-
  admin credential sitting in a file on disk — precisely the 'live god-credential' the design says
  does not exist. synapse-admin cannot decrypt E2EE content, but it can enumerate the full metadata
  graph, redact/rewrite room state, and use POST /\_synapse/admin/v1/users/<user>/login to mint an
  access token for ANY user and stand up a new device. That directly powers DESIGN §9's own load-
  bearing concern ('a compromised core could inject a malicious device to read future E2EE
  messages') and the malicious-core attack the security review lists as untested. The 'no standing
  admin' coercion-resistance story covers only the GitOps DEPLOY plane; the running moderation bot
  reintroduces standing admin on the seized box, and backups propagate it off-core. This gap is
  never reconciled in DESIGN/SPEC/ARCHITECTURE.
- **Fix:** Stop conflating 'no standing deploy admin' with 'no standing admin on the core'. Concretely: (a)
  scope the Draupnir/system tokens to the minimum Synapse capabilities they actually need (moderation
  acts on room state/event-ids per the template's own note — evaluate dropping full synapse-admin and
  enableMakeRoomAdminCommand, or gate make-room-admin behind a break-glass mint rather than a
  persistent grant); (b) if a privileged bot token must persist, document it honestly in DESIGN §9 row
  1 as a seized-running-core residual and put it on a short-lived, auto-rotating issuance so a seized
  box yields at most a soon-dead token; (c) exclude the live admin token from backups (store only what
  restore needs to RE-MINT it), and add token revocation to the seizure runbook.

## MEDIUM

#### RECOVERY.md §4 threat table claims "M moderators + seized core → No", but the DEFAULT moderators-only mode makes it YES for every member

_`recovery-crypto`_ — Split the §4 table by mode. Add an explicit moderators-only column where "M moderators + seized core → YES (all members)" and "M moderators alone → YES (all members)", matching §10's Residual. State plainly at the top of §4 that the clean "core yields nothing" property requires the opt-in passphrase, and that the defau

#### Returning-user vs new-account branch keys off server-controlled `userHasCrossSigningKeys()`; a malicious core can force silent identity destruction / passphrase re-issue

_`recovery-crypto`_ — Do not gate new-vs-returning on a server-controlled predicate alone. Persist a local first-run marker and/or detect existing 4S/secret-storage account_data before ever calling bootstrapSecretStorage with setupNewSecretStorage:true. If cross-signing keys are unexpectedly absent for a device that previously onboarded, ha

#### Diceware default (6 words) yields 66–77.5 bits depending on wordlist; below documented "diceware-grade" claim and the only thing standing between a seized passphrase-mode blob and brute force

_`recovery-crypto`_ — Raise the diceware default to ≥7 words and require the EFF-large (7776) wordlist (reject 2048-word lists, or raise the floor so 2048×words ≥ ~100 bits). Fix the fallback comment (79.3, not 80) or extend to 17 chars for a true 80+. Pin minimum-entropy as a checked invariant in generateRecoveryPassphrase rather than trus

#### Escrow record + moderator directory are unauthenticated (AAD=None everywhere); malicious core can policy-downgrade or substitute moderator pubkeys

_`recovery-crypto`_ — Implement the RECOVERY.md §12 hardening before any port: bind {mode, policy{M,N}, directory-version, member-id} into the record AEAD's associated data; sign the moderator directory with an offline organizer key and verify out-of-band; add the malicious-core rejection test the §12 list and SECURITY-REVIEW #2 both call f

#### ECIES unseal/ re-seal does ECDH from a static secure-element key against an unvalidated peer point — invalid-curve exposure if the TS/native port skips on-curve validation

_`recovery-crypto`_ — Add an explicit on-curve (and non-identity) validation requirement for blob[:65] to RECOVERY.md §12 / the test-vector README, and add a negative test vector (an off-curve 65-byte point that unseal MUST reject). In the port, use only point-import APIs that validate membership (WebCrypto importKey with named curve + a ve

#### Draupnir bot holds a full Synapse-admin token persisted in plaintext on the seizable core

_`onboarding-mas`_ — Drop `--yes-i-want-to-grant-synapse-admin-privileges` for the Draupnir token and set `enableMakeRoomAdminCommand: false`; grant the bot only PL-based moderation rights in the rooms it protects. If make-room-admin is genuinely required, scope it narrowly and rotate the token on a short interval. At minimum, never store

#### Docker daemon log rotation (the only bound on Caddy-front client-IP error logs) is never applied — front retains real client IPs unbounded

_`metadata-hygiene`_ — Add an Ansible task on BOTH core and front plays to template /etc/docker/daemon.json with the json-file max-size/max-file opts and `systemctl restart docker` (or set logging: max-size/max-file per service in docker-compose.yml so it's enforced regardless of daemon config). For the front specifically, prefer logging to

#### scrub-metadata.sh runs with ON_ERROR_STOP=off and no transaction — partial/silent failure leaves IPs un-scrubbed

_`metadata-hygiene`_ — Wrap the scrub in a single transaction with ON_ERROR_STOP=on so a renamed column aborts loudly rather than silently skipping. Expand the post-scrub verification to cover all 7 tables (and any newly-added). Pin the assumption that this script tracks the MAS schema version, and add it to the 're-run on version bump' disc

#### All crown-jewel secrets are written world-readable (mode 664) — no chmod/umask anywhere in setup.sh/backup.sh/restore.sh

_`secrets-custody`_ — Set a restrictive umask at the top of setup.sh (`umask 077`) and explicitly `chmod 600` every generated secret file: `.env`, `mas/config.yaml`, `initdb/init.sql` (carries no secret but harmless), and the in-container `/data/mas_shared_secret`. In backup.sh/restore.sh apply the same to the bundle. Verify with a post-wri

#### FrontTripwire seizure detector is forgeable and suppressible by the adversary who seizes the front

_`topology-wireguard`_ — Treat heartbeat-absence as necessary-but-not-sufficient. Make liveness un-forgeable from the front's own captured state: (a) have the CORE actively poll the front (challenge-response with a rotating nonce the front cannot precompute) rather than trusting a front-originated push; and/or (b) bind detection to attestation

#### Draupnir's 'keyless' framing is misleading: the bot holds a full synapse-admin access token on the core and runs an unencrypted control channel

_`topology-wireguard`_ — (1) Scope down: Draupnir does not need full synapse-admin for ban/redact/server-ACL/policy-list operations — those use normal room power levels. Only `enableMakeRoomAdminCommand` needs admin; if that command isn't operationally required, mint a NON-admin compat token and set `enableMakeRoomAdminCommand:false`, dropping

#### Unencrypted moderation control room has default power levels: any member can invite an outsider into the plaintext command channel

_`topology-wireguard`_ — Lock the room down at creation: set `power_level_content_override` so `invite` requires PL ≥ 50 (or 100), restrict `m.room.power_levels`/state to the operator set, and prefer `join_rule: invite` with `history_visibility: joined`. Re-key/rotate the bot token and rebuild the room if an operator is known-compromised. Pair

#### Silent integration.patch failure is not machine-detectable: the build ALWAYS succeeds (exit 0) even when silent onboarding is dropped, with only an echo as the signal

_`supply-chain-fork`_ — Make the failure loud and detectable without forcing it to be fatal-by-default. Minimum: after `yarn build`, add a verification RUN step that greps the built bundle for a sentinel string the soft-fork injects (e.g. `grep -rq 'rednet-onboarding' webapp/ || (echo 'REDnet FATAL: silent onboarding NOT in bundle' && exit 1)

#### Element Web is built from a movable git tag with no commit-SHA or signature pin, and yarn --frozen-lockfile trusts the upstream-cloned lockfile and full npm dependency tree wholesale

_`supply-chain-fork`_ — Pin Element to an immutable `git checkout <full-commit-sha>` (or `git clone --branch <tag>` then assert `git rev-parse HEAD` equals an expected SHA recorded in the repo) and, if feasible, `git verify-tag` against element-hq's signing key. Vendor or commit the resolved yarn.lock into deploy/element-web/ so the dependenc

#### Documented two-host production deploy renders MAS issuer/public_base + Synapse public_baseurl as http://localhost — violates the project's own ★ hard requirement and bakes a clearnet HTTP OIDC issuer

_`systemic`_ — Add an explicit external-base parameter to rednet.env (e.g. REDNET_PUBLIC_BASE=https://<domain>) and use it (not http://localhost) for MAS issuer/public_base and Synapse public_baseurl when deploying behind the front; keep http://localhost only for the single-host dev path. Have setup.sh fail-closed if public_base is h

#### Phase-2 crypto test-vector oracle encodes the UNauthenticated escrow construction the security review says MUST be replaced — a faithful TS port reproduces the vulnerable form

_`systemic`_ — Before Phase-2 work begins, regenerate the oracle to the hardened construction: make ecies_seal / record-seal bind the policy+directory-version+member-id as AEAD AAD, export a vector for that AAD, and update the construction strings in spikes/test-vectors/export.py and primitives.json. Add the malicious-core rejection

## LOW

- **(recovery-crypto)** No strength floor / generation-mandate for member-chosen passphrases in passphrase mode
- **(recovery-crypto)** Test vectors do not pin any Shamir behavior, the record-level framing, or the GF(2^128)-vs-GF(2^8) interop boundary — the highest-risk porting surface is unverified by the oracle
- **(recovery-crypto)** "S/E wiped from the onboarding device after escrow" and "K never exists server-side" are asserted but unspecified/unproven; no zeroization in the verified code path
- **(onboarding-mas)** System account `rednet-system` is created Synapse-admin-capable and is never locked, unlike the throwaway check accounts
- **(onboarding-mas)** Ephemeral passwords passed as `docker compose exec` process arguments are visible in the container process table
- **(hardening-isolation)** `trusted_key_servers: matrix.org` is never stripped; the hardened config retains an outbound dependency on matrix.org
- **(hardening-isolation)** `rc_invites` rate-limit specified in SPEC §4 is missing from the rendered config
- **(hardening-isolation)** Hardening is written into the runtime volume by a one-shot imperative script, with no enforcement on restart or drift detection
- **(hardening-isolation)** Synapse `/_synapse/admin` is blocked only at the Caddy front, not disabled or bound-restricted at Synapse itself
- **(front-proxy)** Front blanket-forwards all of /\_matrix/_ and /\_synapse/_ to the core; federation, server-key, and metrics surfaces reach the core relying solely on Synapse's listener config to close them
- **(front-proxy)** Client-supplied X-Real-IP and RFC7239 Forwarded headers are passed through unmodified to upstreams (Caddy only sanitizes X-Forwarded-\*)
- **(front-proxy)** MAS-delegated auth endpoints (password change, deactivate, register) route to Synapse, not MAS — the proxy does not enforce the auth boundary it exists to enforce
- **(secrets-custody)** restic repo password 'held OFF the core' is documented as the security property but is in no way enforced — a seized core silently yields the only thing protecting the off-site backups
- **(secrets-custody)** The Postgres password is embedded in cleartext inside the world-readable rendered MAS config (database.uri), widening its exposure beyond .env
- **(secrets-custody)** ansible/group_vars/all.yml (the live WireGuard key material file) is not covered by any .gitignore
- **(secrets-custody)** Self-check registers a throwaway user with the password passed as an explicit mas-cli argv (--password $(genpw)), exposing it on the in-container process list
- **(topology-wireguard)** Ansible rsync of the deploy/ tree to the core does not exclude local secret/config files, contradicting the 'secrets generated on the core' model
- **(topology-wireguard)** Documented 'operators reach Grafana/Prometheus over the tunnel' is not wired — monitoring binds 127.0.0.1 only on the core and the WG override does not republish it
- **(supply-chain-fork)** Digest pins are captured-from-pull, not verified against signed upstream releases — a poisoned/spoofed pull at capture time becomes the permanent trusted lock
- **(systemic)** Metadata-suppression asymmetry: the strategic mobile client (Element X) silently gets weaker who/when hygiene than the docs' headline implies
- **(systemic)** ~~Claims-vs-reality drift in deploy docs: auto-join 'confirmed' while the script itself hedges~~ ✅ **FIXED (2026-06-19):** deploy/README.md now accurately documents auto-join behavior (interactive yes, CLI no) and the two mitigation paths (joinStarterRooms + invite-to-community.sh); backup set presented as restore-complete

## INFO / observations

- **(onboarding-mas)** No-PII account claim holds for the account record, but account-creation IP is captured at registration (already partially documented)
- **(onboarding-mas)** MSC3967 silent cross-signing and MAS-delegated no-PII bootstrap are empirically verified, not assumed
- **(hardening-isolation)** Front host-port publish binds all interfaces (0.0.0.0:8080) with no loopback restriction for the single-host/dev path
- **(front-proxy)** path_regexp matchers are case-sensitive while Caddy's path matcher is case-insensitive, creating an inconsistency where capitalized auth paths bypass the MAS router and fall through to Synapse
- **(front-proxy)** MAS trusted_proxies includes a malformed/over-broad CIDR (10.0.0.0/10) widening the set of peers allowed to assert client IPs
- **(topology-wireguard)** Pushgateway is double-published (loopback + WG IP) due to compose port-list merge; minor attack-surface note
- ~~**(supply-chain-fork)** EFF_WORDLIST referenced in the integration patch is undefined and unsupplied, silently degrading generated recovery passphrases to the alphanumeric fallback~~ ✅ **FIXED (2026-06-19):** EFF large wordlist (7776 words) bundled in `rednet-module/src/eff-wordlist.ts`, passed to `RednetCryptoSetup` constructor; `generateRecoveryPassphrase` uses 7-word diceware (~90 bits)
