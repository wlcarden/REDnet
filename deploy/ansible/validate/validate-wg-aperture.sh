#!/usr/bin/env bash
# Tests the WG-APERTURE scoping (site.yml:49-53) for the same DNAT/chain trap as the WAN rule.
# Models the WG segment: core (10.13.13.1, its eth0 = the 'wg0' side) + front (10.13.13.2). The core
# DNAT-publishes two ports on its WG IP: 8008 (an allowed proxy port) and 5432 (postgres — must be denied
# to a seized front). We then ask: does an INPUT-chain deny (what `ufw ... direction: in` produces) actually
# keep the front off 5432? And does a DOCKER-USER rule keyed on the ORIGINAL dport (conntrack) do it right?
set -uo pipefail
SUDO=$([ "$(id -u)" = 0 ] && echo "" || echo sudo)
NET=redwg; CORE=10.13.13.1; FRONT_IP=10.13.13.2; PASS=1
note(){ printf '\n=== %s ===\n' "$*"; }
expect(){ if [ "$1" = "$2" ]; then echo "   $3 -> $1 (expect $2) OK"; else echo "   $3 -> $1 (expect $2) FAIL"; PASS=0; fi; }
cleanup(){ $SUDO docker rm -f wgcore front >/dev/null 2>&1; $SUDO docker network rm "$NET" >/dev/null 2>&1; $SUDO docker network prune -f >/dev/null 2>&1; }
trap cleanup EXIT; cleanup

note "0) WG segment: wgcore ($CORE, eth0 = the 'wg0' side in prod) + front ($FRONT_IP)"
# gateway parked at .254 so the prod-like .1 is free for the core (Docker reserves .1 as the bridge gw by default)
$SUDO docker network create --subnet 10.13.13.0/24 --gateway 10.13.13.254 "$NET" >/dev/null
$SUDO docker run -d --privileged --name wgcore --network "$NET" --ip "$CORE" -e DOCKER_TLS_CERTDIR= docker:dind >/dev/null
$SUDO docker run -d --name front --network "$NET" --ip "$FRONT_IP" alpine sleep infinity >/dev/null
$SUDO docker exec front sh -c 'apk add -q nmap >/dev/null 2>&1'
printf '   waiting for inner dockerd'; for _ in $(seq 1 30); do $SUDO docker exec wgcore docker info >/dev/null 2>&1 && break; printf '.'; sleep 1; done; echo
$SUDO docker exec wgcore docker info >/dev/null 2>&1 || { echo "dind down"; exit 1; }

note "1) core DNAT-publishes 8008 (allowed) + 5432 (postgres, must be denied) on its WG IP $CORE"
$SUDO docker pull -q busybox:latest >/dev/null
$SUDO docker save busybox:latest | $SUDO docker exec -i wgcore docker load >/dev/null
$SUDO docker exec wgcore docker run -d -p ${CORE}:8008:8008 --name s8008 busybox httpd -f -p 8008 >/dev/null
$SUDO docker exec wgcore docker run -d -p ${CORE}:5432:5432 --name s5432 busybox httpd -f -p 5432 >/dev/null
sleep 2
scan(){ $SUDO docker exec front nmap -p "$2" -Pn -n --host-timeout 8s "$1" 2>/dev/null | grep -qE "^$2/tcp +open" && echo OPEN || echo CLOSED; }

note "2) site.yml's aperture as written — ufw 'direction: in' = INPUT chain: allow 8008 from front, deny rest on the wg iface"
$SUDO docker exec wgcore iptables -I INPUT -i eth0 -p tcp -s "$FRONT_IP" --dport 8008 -j ACCEPT
$SUDO docker exec wgcore iptables -A INPUT -i eth0 -j DROP
echo "   from the front, over WG:"
expect "$(scan $CORE 8008)" OPEN  "  $CORE:8008 (proxy port, intended reachable)"
R=$(scan $CORE 5432)
if [ "$R" = OPEN ]; then echo "  $CORE:5432 (postgres) -> OPEN  <-- the INPUT-chain 'deny everything else' did NOT stop it (published port = FORWARD path)"; else echo "  $CORE:5432 -> $R"; fi

note "3) The ROBUST fix — DOCKER-USER (FORWARD), keyed on the ORIGINAL dport via conntrack (survives DNAT)"
$SUDO docker exec wgcore iptables -I DOCKER-USER -i eth0 -j DROP
$SUDO docker exec wgcore iptables -I DOCKER-USER -i eth0 -p tcp -m conntrack --ctorigdstport 8008 -j RETURN
echo "   from the front, over WG:"
expect "$(scan $CORE 8008)" OPEN   "  $CORE:8008 (still allowed)"
expect "$(scan $CORE 5432)" CLOSED "  $CORE:5432 (postgres now denied)"

note "VERDICT"
if [ "$PASS" = 1 ]; then
  echo "PASS(=hypothesis confirmed): the ufw INPUT-chain 'deny everything else on wg0' does NOT restrict"
  echo "  WG-published container ports; only the DOCKER-USER + conntrack(ctorigdstport) form actually scopes them."
else
  echo "NOTE: an expectation differed — read the per-line results above."
fi