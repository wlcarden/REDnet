# REDnet — two-host production provisioning

Splits the verified single-host stack across two boxes joined by WireGuard:

```
        public internet                     WireGuard (only inbound the core allows)
  user ───TLS:443──▶  FRONT (caddy)  ═══════════════════════════▶  CORE
                      disposable,                                  Synapse · MAS · Postgres
                      burnable, no secrets                         Element · Draupnir · Prometheus
                                                                   (dark: no public inbound but WG)
```

The CORE holds every secret and all data and has **no public inbound except the WireGuard port**.
The FRONT is **cattle**: a stateless Caddy that terminates TLS and proxies to the core over the
tunnel. Seize the front and you get a reverse proxy with no keys, no database, no message history.

> **Status: VALIDATED on KVM VMs (2026-06-18).** The firewall, WireGuard aperture, and topology
> have been proven correct via `validate/validate.sh` (off-host port scan + WG scoping + systemd
> timers). Six latent bugs were found and fixed during validation. Remaining gap: the full
> app-level onboarding (bootstrap chain through a front with a real domain + ACME TLS) has not
> been tested end-to-end. Test on throwaway hosts with your real domain first.

## Pre-flight

```bash
# 1. Provision two Ubuntu hosts (VPS, bare metal, or VMs)
# 2. Generate WireGuard keypairs — one pair per host:
wg genkey | tee core.key | wg pubkey > core.pub
wg genkey | tee front.key | wg pubkey > front.pub

# 3. Fill in inventory and config:
cp inventory.example.ini inventory.ini            # set real core/front IPs + SSH user
cp group_vars/all.example.yml group_vars/all.yml  # set domain, WG subnet, pubkeys

# 4. Store private keys in Ansible Vault — NEVER in all.yml:
ansible-vault create group_vars/vault.yml
#   vault_wg_core_private_key: <contents of core.key>
#   vault_wg_front_private_key: <contents of front.key>
# Then reference them in all.yml:
#   wg_core_private_key: "{{ vault_wg_core_private_key }}"
#   wg_front_private_key: "{{ vault_wg_front_private_key }}"

# 5. Shred the cleartext key files:
shred -u core.key front.key
```

`rednet_domain` is **immutable** after first deploy — it becomes the Matrix `server_name`,
baked into every event and user ID. Pick it now.

## Provision

```bash
ansible-playbook -i inventory.ini site.yml --ask-vault-pass
```

The `core` play hardens + brings up the data plane with `docker-compose.wg.yml` (publishes Synapse/
MAS/Element/Pushgateway **on the WG IP only**, never `0.0.0.0`, and runs no Caddy — the front is the
Caddy). The `front` play runs a Caddy container with `Caddyfile.front` (every upstream is the core's
WG IP) plus a per-minute liveness heartbeat.

## Post-provision bootstrap

Ansible hardens both hosts and starts services. It does **not** create rooms, accounts, or governance
infrastructure. Run `deploy.sh` on the core to complete setup:

```bash
ssh core
cd /opt/rednet/deploy
./deploy.sh --operator <username>
```

`deploy.sh` detects the Ansible-provisioned stack (services already running, `REDNET_ROLE=core` in
`rednet.env`), verifies Synapse and MAS are responding, then runs the bootstrap chain:

1. Creates rooms (#welcome, #general, #announcements, #reference, etc.)
2. Sets up governance infrastructure (#vouch-log, #governance)
3. Configures Draupnir (moderation bot)
4. Starts gov-bot (governance bot)
5. Registers the operator account via MAS
6. Posts first-run messages (pinned setup instructions, checklists)
7. Writes credentials to `.first-run-credentials`

At the end, `deploy.sh` probes the front's public URL and reports whether the full path works.
If it reports the front is not reachable, check WireGuard and Caddy on the front host.

## Verify

From any machine that can reach both hosts (or from the validation harness):

```bash
# Quick smoke test: does the front reach Synapse through the tunnel?
curl -sk https://<your-domain>/_matrix/client/versions

# Full topology proof (requires the validate/ KVM or Vagrant harness):
cd deploy/ansible/validate
./validate.sh
```

## Ongoing operations

All automated via systemd timers installed by the Ansible core play:

| Timer           | Interval | Script              | Purpose                                      |
| --------------- | -------- | ------------------- | -------------------------------------------- |
| `rednet-update` | 15 min   | `update.sh --auto`  | Git pull + smart rebuild of changed services |
| `rednet-scrub`  | 1 hour   | `scrub-metadata.sh` | Metadata hygiene                             |
| `rednet-backup` | 1 hour   | `backup.sh`         | DB dump + signing key + MAS config + media   |

**Kill switch:** `touch /opt/rednet/deploy/.update-hold` pauses all updates. Remove to resume.

**Restore:** `./restore.sh backups/<timestamp>` cold-restores onto a fresh stack. Asserts the
restored config is hardened before allowing startup.

## Front tripwire (seizure detection)

`front-heartbeat` pushes `rednet_front_alive_timestamp_seconds` to the core's Pushgateway every
minute over WireGuard. The **`FrontTripwire`** alert (in `../monitoring/alerts.yml`) fires when the
core stops seeing it for >3 minutes — because a seized or unplugged front drops the tunnel. On fire:
treat the front IP as burned, spin up a replacement, done.

## Burn & replace a front

```bash
# point inventory [front] at a fresh host, then:
ansible-playbook -i inventory.ini site.yml --limit front --ask-vault-pass
```

New WG peer, new TLS, new public IP. The core never moved and never went down. Add a second front to
the inventory for hot redundancy.

## Remaining integration points

- **TLS + `.well-known`**: The front terminates TLS and serves `/.well-known/matrix/client`. ACME
  auto-TLS requires the domain's DNS to point at the front's public IP. Verify the cert issues
  cleanly on first deploy (`docker logs rednet-front`).
- **One compose, two roles**: The core reuses the dev `docker-compose.yml` + the WG override and an
  explicit service list (no caddy). Validate the override merges ports as intended on your Docker version.
- **`server_name` is immutable**: Set `rednet_domain` once; it's baked into the core at first `setup.sh`.
