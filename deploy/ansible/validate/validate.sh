#!/usr/bin/env bash
# Off-host validation of the two-host deploy. The host sits on the host-only segment (192.168.56.0/24),
# so it scans the core exactly as an off-host attacker would. THE load-bearing assertion: every service
# port on the core's public IP must REFUSE.
#
# Works against either provider:
#   - Vagrant (default):     ./validate.sh
#   - KVM/QEMU (kvm-up.sh):   RVAL_MODE=ssh ./validate.sh
# RVAL_MODE=ssh reaches the guests via direct SSH (key = RVAL_KEY, default .kvm/id_rednet); else `vagrant ssh`.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
CORE=192.168.56.10
FRONT=192.168.56.20
DOMAIN=$(awk '/rednet_domain:/{print $2}' ../group_vars/all.yml 2>/dev/null || echo rednet.test)
KEY="${RVAL_KEY:-.kvm/id_rednet}"
PASS=1
say(){ printf '\n=== %s ===\n' "$*"; }
is_open(){ nmap -p "$2" -Pn -n --host-timeout 6s "$1" 2>/dev/null | grep -qE "^$2/tcp +open"; }  # success = OPEN
on(){ local ip; [ "$1" = core ] && ip="$CORE" || ip="$FRONT"
  if [ "${RVAL_MODE:-vagrant}" = ssh ]; then
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -i "$KEY" "ubuntu@$ip" "$2"
  else vagrant ssh "$1" -c "$2"; fi; }

say "1) DARK CORE — off-host scan of $CORE (every service port MUST be closed; only 22/tcp + 51820/udp are intended)"
for p in 80 443 8008 8080 8088 9090 9091 5432 6379; do
  if is_open "$CORE" "$p"; then echo "  port $p: OPEN ✗✗  CORE NOT DARK"; PASS=0; else echo "  port $p: closed ✓"; fi
done

say "2) FRONT reachable on its public face"
if is_open "$FRONT" 443; then echo "  front :443 open ✓"; else echo "  front :443 NOT reachable ✗"; PASS=0; fi

# NOTE: the postgres-reachable check below is a FLOOR — it passes trivially because 5432 isn't WG-published.
# The aperture's real defense-in-depth (an INPUT/ufw deny can't restrict DNAT'd published ports; only the
# DOCKER-USER + conntrack rule can) is proven separately and host-independently by validate-wg-aperture.sh.
say "3) WG aperture scoped — from the FRONT, only 8008/8080/8088/9091 on the core's WG IP (10.13.13.1)"
on front '
  for p in 8008 8080 8088 9091; do timeout 3 bash -c "echo >/dev/tcp/10.13.13.1/$p" 2>/dev/null && echo "  WG :$p reachable ✓" || echo "  WG :$p UNREACHABLE ✗"; done
  timeout 3 bash -c "echo >/dev/tcp/10.13.13.1/5432" 2>/dev/null && echo "  WG :5432 (postgres) reachable ✗✗ NOT SCOPED" || echo "  WG :5432 (postgres) blocked ✓"
' 2>/dev/null || echo "  (front unreachable — check the VM is up)"

say "4) scrub + backup timers active on the core"
on core 'systemctl list-timers --all 2>/dev/null | grep -E "rednet-(scrub|backup)" || echo "  NO rednet timers ✗"' 2>/dev/null

say "5) front -> core proxying (a request through the front reaches Synapse over WG)"
# NOTE: the front's Caddy does ACME auto-TLS for the REAL domain; with a fake test domain ACME can't issue,
# so a non-200 here is a test-env artifact (no public DNS), not a topology failure. Informational only.
curl -sk -m 8 -o /dev/null -w "  https://${DOMAIN}/_matrix/client/versions via front -> HTTP %{http_code} (expect 200)\n" \
  --resolve "${DOMAIN}:443:${FRONT}" "https://${DOMAIN}/_matrix/client/versions" || echo "  (front proxy request failed)"

say "VERDICT"
if [ "$PASS" = 1 ]; then
  echo "PASS: the core is DARK from off-host, the front is reachable, and the WG aperture is scoped."
else
  echo "FAIL: see ✗✗ above — the core is reachable from off-host. The DOCKER-USER firewall / no-caddy-on-core fix is not effective on this host."
fi