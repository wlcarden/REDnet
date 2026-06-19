# Two-host validation harness

Stands up a real **CORE + FRONT** VM pair (separate kernels) so the Ansible can run for real and the
**"core is dark"** property — the foundation of the seized-core threat model — can be **proven with an
off-host port scan**. This is the validation the in-sandbox dev environment cannot do (no net privileges,
so no real `iptables`/WireGuard); it's `PRODUCTION.md #3` made runnable on your own machine.

## Why a real port scan is the only proof

`UFW deny` does **not** stop Docker-published ports (Docker's DNAT is evaluated before UFW) — the whole
CRITICAL finding. The fix lives in the `DOCKER-USER` iptables chain + not running Caddy on the core. The
only way to confirm it _works_ is to scan the core's public IP from off-host and watch every service port
refuse.

**You do not need VMs to prove the load-bearing part.** `./validate-docker-firewall.sh` (in this dir)
proves the DNAT-bypass mechanism _and_ the `DOCKER-USER` fix in-sandbox, using a privileged
docker-in-docker "core" + a separate scanner container and a real off-host `nmap` — runs anywhere with
Docker + root, in ~1 min. The **full** harness below additionally validates what containers fake poorly:
real systemd timers, `ufw`/`netplan`, the WireGuard aperture end-to-end, and app onboarding across two
real kernels.

> **Validated 2026-06-18 on real KVM VMs** via path (A) below: `validate.sh` → PASS (core dark off-host,
> WG aperture scoped, timers firing), and a stray `0.0.0.0:9999` publish on the core scanned `filtered`
> off-host with the `DOCKER-USER` drop counter incrementing — the firewall re-darkening a real public bind.
> Running it end-to-end also fixed **6 latent bugs** that made the SCAFFOLD playbook non-functional on a
> clean host (SECURITY-REVIEW.md pass 6).

## Two ways to run it

`192.168.56.0/24` (the host-only segment) **stands in for the public internet** — the host reaching the
core's `.10` is exactly an off-host attacker reaching the core's public IP. WireGuard `10.13.13.0/24` runs
on top, as in production. Either provider produces the same topology.

### A) KVM/QEMU — no Vagrant, no VirtualBox (the path this repo was validated on)

Requires `qemu-system-x86`, `cloud-image-utils`, `ansible`, `wireguard-tools`, `nmap`, and a host with
`/dev/kvm`. `kvm-up.sh` makes a throwaway bridge `redbr0` (192.168.56.1) + taps, boots two cloud-init
Ubuntu VMs (each with a NAT NIC for egress + a bridge NIC that netplan names `eth1` = the public segment,
so `wan_iface=eth1` is correct automatically), and waits for SSH.

```bash
cd deploy/ansible/validate
./gen-config.sh                                       # fresh WG keypairs -> ../group_vars/all.yml
./kvm-up.sh                                           # boot core (.10) + front (.20); writes .kvm/kvm-inventory.ini
ansible-playbook -i .kvm/kvm-inventory.ini ../site.yml
RVAL_MODE=ssh ./validate.sh                           # THE PROOF (off-host scan + WG + timers)
./kvm-down.sh                                         # stop VMs, remove bridge + taps (restore host networking)
```

### B) Vagrant + VirtualBox/libvirt

```bash
cd deploy/ansible/validate
./gen-config.sh                                  # also writes ../inventory.ini
vagrant up                                       # boots core (192.168.56.10) + front (192.168.56.20)
vagrant ssh-config                               # confirm SSH ports/keys; fix ../inventory.ini if they differ
ansible-playbook -i ../inventory.ini ../site.yml
./validate.sh                                    # default mode uses `vagrant ssh` for in-guest checks
```

## What `validate.sh` asserts

1. **Dark core** — off-host, the core's `80/443/8008/8080/8088/9090/9091/5432/6379` all **refuse** (only
   `22/tcp` SSH + `51820/udp` WG are intended). **This is the load-bearing assertion.**
2. **Front reachable** on `:443`.
3. **WG aperture scoped** — from the front, only `8008/8080/8088/9091` on the core's WG IP are reachable;
   `5432` (postgres) is **blocked**.
4. **scrub + backup timers** are active on the core (the metadata-hygiene + backup automation).
5. **Front → core proxying** works (a request to the front reaches Synapse over WG).

## Caveats

- This validates **topology + firewall + WG**. It does NOT exercise live E2EE protocol attacks (still needs
  a Matrix-E2EE specialist) or the full app onboarding (the Element fork must still be webpack-built and the
  self-check + `bootstrap-rooms.sh` run against the front post-provision — see the `site.yml` notes).
- Vagrant's `private_network` NIC name inside the VM is usually `eth1`; `gen-config.sh` sets `wan_iface: eth1`
  for the `DOCKER-USER` rule. Verify with `ip a` in the VM and adjust `../group_vars/all.yml` if it differs —
  a wrong `wan_iface` would silently not protect the right interface.
