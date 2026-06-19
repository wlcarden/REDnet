#!/usr/bin/env bash
# Tear down everything kvm-up.sh created: kill the VMs, remove the taps + bridge, restore host networking.
# Keeps .kvm/ (cloud image + overlays) so a re-run is fast; `rm -rf .kvm` to reclaim disk.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
WORK="$PWD/.kvm"
for n in core front; do
  if [ -f "$WORK/$n.pid" ]; then
    # pidfiles are root-owned (qemu ran under sudo): `sudo pkill -F` reads + signals via the file.
    # Do NOT use a broad `pkill -f qemu...` pattern — it also matches THIS teardown command (a self-kill).
    sudo pkill -F "$WORK/$n.pid" 2>/dev/null && echo "killed $n" || true
    sudo rm -f "$WORK/$n.pid"
  fi
done
for t in tap-core tap-front; do sudo ip link del "$t" 2>/dev/null && echo "removed $t" || true; done
sudo ip link del redbr0 2>/dev/null && echo "removed redbr0" || true
echo "host network restored (VMs stopped, bridge + taps gone)."