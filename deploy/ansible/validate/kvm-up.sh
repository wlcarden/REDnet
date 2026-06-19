#!/usr/bin/env bash
# Bring up the two validation VMs on QEMU/KVM directly — no Vagrant, no VirtualBox.
# This is the KVM-host path for the two-host harness: two real Ubuntu kernels (systemd, netplan,
# WireGuard module) on a host-only bridge the host also sits on, so `validate.sh` can scan the core
# off-host. Each VM has TWO NICs, mirroring the Vagrant layout:
#   eth0 = QEMU user-mode NAT  (egress, so site.yml can apt-install docker/wireguard)
#   eth1 = tap on redbr0       (the "public internet" segment, 192.168.56.0/24; wan_iface=eth1)
# Prereqs (installed by the session): qemu-system-x86, qemu-utils, cloud-image-utils, ansible, wg, nmap.
# Run from deploy/ansible/validate/.  Companion teardown: kvm-down.sh
set -euo pipefail
cd "$(dirname "$0")" || exit 1
WORK="$PWD/.kvm"; mkdir -p "$WORK"
BR=redbr0
IMG="$WORK/jammy.img"

# name  mem   ip               nat-mac            wan-mac            tap
VMS=(
  "core  8192  192.168.56.10  52:54:00:aa:c0:00  52:54:00:aa:c0:01  tap-core"
  "front 1536  192.168.56.20  52:54:00:aa:f0:00  52:54:00:aa:f0:01  tap-front"
)

# 1) base cloud image (cached in .kvm for fast re-runs)
[ -f "$IMG" ] || { echo "downloading Ubuntu 22.04 cloud image…"; \
  curl -fL --retry 3 -o "$IMG" https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img; }
# 2) throwaway SSH key for the Ansible control connection
[ -f "$WORK/id_rednet" ] || ssh-keygen -t ed25519 -N '' -f "$WORK/id_rednet" -q
PUB="$(cat "$WORK/id_rednet.pub")"
# 3) host-only bridge (192.168.56.1) + one tap per VM = the "public internet" segment. kvm-down.sh removes them.
if ! ip link show "$BR" >/dev/null 2>&1; then
  sudo ip link add "$BR" type bridge
  sudo ip addr add 192.168.56.1/24 dev "$BR"
  sudo ip link set "$BR" up
fi
for t in tap-core tap-front; do
  ip link show "$t" >/dev/null 2>&1 || { sudo ip tuntap add dev "$t" mode tap; sudo ip link set "$t" master "$BR"; sudo ip link set "$t" up; }
done

for row in "${VMS[@]}"; do
  read -r NAME MEM IP NATMAC WANMAC TAP <<<"$row"
  echo "=== prepare $NAME ($IP, ${MEM}MB) ==="

  # cloud-init: user-data (login + rsync for ansible.posix.synchronize), meta-data, netplan (match by MAC)
  cat > "$WORK/$NAME-user-data" <<EOF
#cloud-config
hostname: $NAME
preserve_hostname: false
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: ["$PUB"]
ssh_pwauth: false
package_update: true
packages: [rsync]
EOF
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$NAME" "$NAME" > "$WORK/$NAME-meta-data"
  cat > "$WORK/$NAME-net.yaml" <<EOF
version: 2
ethernets:
  nat:
    match: {macaddress: "$NATMAC"}
    set-name: eth0
    dhcp4: true
  wan:
    match: {macaddress: "$WANMAC"}
    set-name: eth1
    dhcp4: false
    addresses: [$IP/24]
EOF
  cloud-localds --network-config="$WORK/$NAME-net.yaml" "$WORK/$NAME-seed.iso" \
    "$WORK/$NAME-user-data" "$WORK/$NAME-meta-data"

  # fresh overlay on the shared base image
  rm -f "$WORK/$NAME.qcow2"
  qemu-img create -f qcow2 -F qcow2 -b "$IMG" "$WORK/$NAME.qcow2" 20G >/dev/null

  echo "=== boot $NAME ==="
  sudo qemu-system-x86_64 -enable-kvm -m "$MEM" -smp 2 \
    -drive file="$WORK/$NAME.qcow2",if=virtio \
    -drive file="$WORK/$NAME-seed.iso",if=virtio,format=raw,readonly=on \
    -netdev user,id=nat -device virtio-net-pci,netdev=nat,mac="$NATMAC" \
    -netdev tap,id=wan,ifname="$TAP",script=no,downscript=no -device virtio-net-pci,netdev=wan,mac="$WANMAC" \
    -display none -daemonize -pidfile "$WORK/$NAME.pid" -serial file:"$WORK/$NAME-serial.log"
done

echo "=== wait for SSH + cloud-init on both VMs ==="
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=4 -i $WORK/id_rednet"
for ip in 192.168.56.10 192.168.56.20; do
  printf '  %s ssh' "$ip"
  for _ in $(seq 1 90); do $SSH ubuntu@"$ip" true 2>/dev/null && break; printf '.'; sleep 4; done
  $SSH ubuntu@"$ip" true 2>/dev/null || { echo " UNREACHABLE"; exit 1; }
  printf ' up; cloud-init'; $SSH ubuntu@"$ip" 'sudo cloud-init status --wait >/dev/null 2>&1 || true'; echo ' done'
done

# ansible inventory pointing straight at the bridge IPs (no Vagrant SSH indirection)
cat > "$WORK/kvm-inventory.ini" <<EOF
[core]
core1 ansible_host=192.168.56.10
[front]
front1 ansible_host=192.168.56.20
[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=$WORK/id_rednet
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
ansible_python_interpreter=/usr/bin/python3
EOF
echo "=== VMs up. inventory: $WORK/kvm-inventory.ini ==="