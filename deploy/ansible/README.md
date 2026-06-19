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

> **Status: SCAFFOLD.** These playbooks/templates encode the topology but are **not** verified on
> real hosts (no two-box test rig in-sandbox). Treat as a strong starting point: review every task,
> put WireGuard private keys in an Ansible Vault, and test on throwaway hosts first.

## Run

```bash
cp inventory.example.ini inventory.ini            # set real core/front hosts
cp group_vars/all.example.yml group_vars/all.yml  # set domain, WG subnet, pubkeys
# generate WG keypairs (wg genkey | wg pubkey); private keys -> `ansible-vault` not the yml
ansible-playbook -i inventory.ini site.yml
```

The `core` play hardens + brings up the data plane with `docker-compose.wg.yml` (publishes Synapse/
MAS/Element/Pushgateway **on the WG IP only**, never `0.0.0.0`, and runs no Caddy — the front is the
Caddy). The `front` play runs a Caddy container with `Caddyfile.front` (every upstream is the core's
WG IP) plus a per-minute liveness heartbeat.

## Front tripwire (seizure detection)

`front-heartbeat` pushes `rednet_front_alive_timestamp_seconds` to the core's Pushgateway every
minute over WireGuard. The **`FrontTripwire`** alert (in `../monitoring/alerts.yml`) fires when the
core stops seeing it for >3 minutes — because a seized or unplugged front drops the tunnel. On fire:
treat the front IP as burned, spin up a replacement, done.

## Burn & replace a front

```bash
# point inventory [front] at a fresh host, then:
ansible-playbook -i inventory.ini site.yml --limit front
```

New WG peer, new TLS, new public IP. The core never moved and never went down. Add a second front to
the inventory for hot redundancy.

## Known integration points to finalize (why this is a scaffold)

- **One compose, two roles.** The core reuses the dev `docker-compose.yml` + the WG override and an
  explicit service list (no caddy). Validate the override merges ports as intended on your Docker version.
- **Secrets distribution.** `setup.sh` generates secrets on the core (correct). Don't copy `rednet.env`
  secrets to the front — it needs none.
- **`server_name` is immutable.** Set `rednet_domain` once; it's baked into the core at first `setup.sh`.
- **TLS + .well-known.** The front terminates TLS and serves `/.well-known/matrix/client`. Confirm
  federation is closed (it is, server-side) so no `server` well-known is needed.
