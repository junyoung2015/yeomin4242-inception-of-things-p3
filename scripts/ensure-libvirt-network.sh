#!/usr/bin/env bash
#
# Create the L2-only network used by P1 and P2 on the GCE KVM/libvirt host.
# Vagrant's management NAT interface remains separate; this network has no
# DHCP and carries only the subject-required static addresses.

set -euo pipefail

NETWORK_NAME="iot-vagrant-private"
NETWORK_XML="$(mktemp)"

cleanup() {
  rm -f "$NETWORK_XML"
}
trap cleanup EXIT

if sudo virsh net-info "$NETWORK_NAME" >/dev/null 2>&1; then
  if ! sudo virsh net-dumpxml "$NETWORK_NAME" | grep -Fq '192.168.56.1'; then
    echo "Existing $NETWORK_NAME does not use 192.168.56.1; refusing to redefine it." >&2
    exit 1
  fi

  sudo virsh net-start "$NETWORK_NAME" >/dev/null 2>&1 || true
  sudo virsh net-autostart "$NETWORK_NAME" >/dev/null
  echo "$NETWORK_NAME already exists and is active."
  exit 0
fi

cat > "$NETWORK_XML" <<'EOF'
<network>
  <name>iot-vagrant-private</name>
  <forward mode='none'/>
  <bridge name='virbr-iot' stp='on' delay='0'/>
  <ip address='192.168.56.1' netmask='255.255.255.0'/>
</network>
EOF

sudo virsh net-define "$NETWORK_XML"
sudo virsh net-start "$NETWORK_NAME"
sudo virsh net-autostart "$NETWORK_NAME"

echo "Created $NETWORK_NAME: 192.168.56.0/24, gateway 192.168.56.1, DHCP disabled."
