#!/usr/bin/env bash
# In-sandbox proof of the load-bearing CRITICAL and its fix — NO VMs required, just Docker + root.
# Companion to validate.sh (the full two-VM harness): this isolates the ONE network property the whole
# seized-core model rests on and proves it with real iptables + a real off-host scan.
#
# Proves three things:
#   2) a host firewall (UFW / iptables INPUT) deny does NOT block a Docker-published port;
#   4) a port-matched DOCKER-USER rule (--dport <published>) is a TRAP — PREROUTING DNAT rewrites the
#      dest port (published->container) before the FORWARD chain, so the match never fires; and
#   5) site.yml's INTERFACE-scoped rule (-i <wan> -j DROP) actually closes it.
#
# 'core-host' is a privileged docker-in-docker box = a faithful microcosm of the bare-metal core
# (its eth0 = the WAN, its inner dockerd owns the DOCKER/DOCKER-USER chains, it DNAT-publishes a port
# exactly as the real core would). 'scanner' is a second host on the same L2 segment = the off-host attacker.
#
# Run anywhere with Docker + root:  ./validate-docker-firewall.sh
set -uo pipefail
SUDO=$([ "$(id -u)" = 0 ] && echo "" || echo sudo)
NET=redwan
CORE_IP=172.31.0.10
PORT=8008
PASS=1
note(){ printf '\n=== %s ===\n' "$*"; }
expect(){ if [ "$1" = "$2" ]; then echo "   $3 -> $1  (expect $2) OK"; else echo "   $3 -> $1  (expect $2) FAIL"; PASS=0; fi; }
cleanup(){ $SUDO docker rm -f core-host scanner >/dev/null 2>&1; $SUDO docker network rm "$NET" >/dev/null 2>&1; }
trap cleanup EXIT
cleanup

note "0) build the segment: core-host (dind) + scanner on $NET ($CORE_IP = the core's public IP)"
$SUDO docker network create --subnet 172.31.0.0/24 "$NET" >/dev/null
$SUDO docker run -d --privileged --name core-host --network "$NET" --ip "$CORE_IP" -e DOCKER_TLS_CERTDIR= docker:dind >/dev/null
$SUDO docker run -d --name scanner --network "$NET" alpine sleep infinity >/dev/null
$SUDO docker exec scanner sh -c 'apk add -q nmap >/dev/null 2>&1'
printf '   waiting for inner dockerd'
for _ in $(seq 1 30); do $SUDO docker exec core-host docker info >/dev/null 2>&1 && break; printf '.'; sleep 1; done; echo
$SUDO docker exec core-host docker info >/dev/null 2>&1 || { echo "inner dockerd never came up"; exit 1; }

note "1) publish a service inside core-host (inner docker DNAT-publishes :$PORT on 0.0.0.0 -> svc:80)"
$SUDO docker pull -q busybox:latest >/dev/null
$SUDO docker save busybox:latest | $SUDO docker exec -i core-host docker load >/dev/null
$SUDO docker exec core-host docker run -d -p ${PORT}:80 --name svc busybox httpd -f -p 80 >/dev/null
sleep 2
scan(){ $SUDO docker exec scanner nmap -p "$PORT" -Pn -n --host-timeout 8s "$CORE_IP" 2>/dev/null \
        | grep -qE "^${PORT}/tcp +open" && echo OPEN || echo CLOSED; }

note "2) BASELINE — service published, no firewall"
expect "$(scan)" OPEN "off-host scan $CORE_IP:$PORT"

note "3) 'ufw deny $PORT' (iptables INPUT DROP) — the naive expectation"
$SUDO docker exec core-host iptables -I INPUT -p tcp --dport "$PORT" -j DROP
expect "$(scan)" OPEN "off-host scan $CORE_IP:$PORT  [INPUT/UFW deny does NOT cover published ports]"

note "4) WRONG DOCKER-USER form — port-matched (--dport $PORT). PREROUTING already rewrote $PORT->80, so it can't match"
$SUDO docker exec core-host iptables -I DOCKER-USER -i eth0 -p tcp --dport "$PORT" -j DROP
expect "$(scan)" OPEN "off-host scan $CORE_IP:$PORT  [the published-port match is a trap]"
echo "   DOCKER-USER counters (the --dport rule's pkt count stays 0 — it never matches):"
$SUDO docker exec core-host iptables -L DOCKER-USER -n -v --line-numbers | sed 's/^/     /'
$SUDO docker exec core-host iptables -D DOCKER-USER -i eth0 -p tcp --dport "$PORT" -j DROP

note "5) site.yml's ACTUAL rule — interface-scoped (-i eth0 -j DROP)"
$SUDO docker exec core-host iptables -I DOCKER-USER -i eth0 -j DROP
expect "$(scan)" CLOSED "off-host scan $CORE_IP:$PORT  [interface match drops post-DNAT forwarded packets]"
echo "   DOCKER-USER counters (this rule accrues exactly the scan's SYNs):"
$SUDO docker exec core-host iptables -L DOCKER-USER -n -v --line-numbers | sed 's/^/     /'

note "VERDICT"
if [ "$PASS" = 1 ]; then
  echo "PASS: UFW/INPUT deny leaves the published port OPEN (the CRITICAL); the port-matched DOCKER-USER"
  echo "      rule is a trap (still OPEN); site.yml's interface-scoped '-i <wan> -j DROP' CLOSES it."
else
  echo "FAIL: an expectation above did not hold — see FAIL."
fi
[ "$PASS" = 1 ]