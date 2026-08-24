#!/usr/bin/env bash

set -euo pipefail

SERVER_IP="${1:?server IP is required}"
WORKER_IP="${2:?worker IP is required}"
TOKEN_FILE="${3:?runtime token file is required}"

private_interface_for_ip() {
  ip -o -4 addr show | awk -v wanted="$1" '$4 ~ ("^" wanted "/") { print $2; exit }'
}

PRIVATE_INTERFACE="$(private_interface_for_ip "$WORKER_IP")"

if [ -z "$PRIVATE_INTERFACE" ]; then
  echo "No network interface owns $WORKER_IP." >&2
  exit 1
fi

if [ ! -s "$TOKEN_FILE" ]; then
  echo "Runtime K3s token file is missing: $TOKEN_FILE" >&2
  exit 1
fi

K3S_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"

if [ -z "$K3S_TOKEN" ]; then
  echo "Runtime K3s token is empty." >&2
  exit 1
fi

apt-get update -y
apt-get install -y curl

for attempt in {1..90}; do
  if (echo > "/dev/tcp/$SERVER_IP/6443") >/dev/null 2>&1; then
    break
  fi

  if [ "$attempt" = "90" ]; then
    echo "K3s server API did not open on $SERVER_IP:6443." >&2
    exit 1
  fi

  echo "Waiting for K3s server API ($attempt/90)..."
  sleep 2
done

curl -sfL https://get.k3s.io | \
  K3S_URL="https://$SERVER_IP:6443" \
  K3S_TOKEN="$K3S_TOKEN" \
  INSTALL_K3S_EXEC="agent --node-ip=$WORKER_IP --flannel-iface=$PRIVATE_INTERFACE" \
  sh -s -

for attempt in {1..90}; do
  if systemctl is-active --quiet k3s-agent; then
    echo "K3s worker is ready on $WORKER_IP via $PRIVATE_INTERFACE."
    exit 0
  fi

  sleep 2
done

systemctl status k3s-agent --no-pager || true
echo "K3s worker service did not become active." >&2
exit 1
