#!/usr/bin/env bash

set -euo pipefail

SERVER_IP="${1:?server IP is required}"

private_interface_for_ip() {
  ip -o -4 addr show | awk -v wanted="$1" '$4 ~ ("^" wanted "/") { print $2; exit }'
}

PRIVATE_INTERFACE="$(private_interface_for_ip "$SERVER_IP")"

if [ -z "$PRIVATE_INTERFACE" ]; then
  echo "No network interface owns $SERVER_IP." >&2
  exit 1
fi

apt-get update -y
apt-get install -y curl

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="server --node-ip=$SERVER_IP --bind-address=$SERVER_IP --tls-san=$SERVER_IP --flannel-iface=$PRIVATE_INTERFACE" \
  sh -s -

until kubectl get nodes >/dev/null 2>&1; do
  echo "Waiting for K3s server API..."
  sleep 2
done

install -d -m 0700 -o vagrant -g vagrant /home/vagrant/.kube
install -m 0600 -o vagrant -g vagrant /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config

kubectl apply -f /vagrant/ymls/deployment.yml
kubectl apply -f /vagrant/ymls/service.yml
kubectl apply -f /vagrant/ymls/ingress.yml

for deployment in app-1 app-2 app-3; do
  kubectl rollout status "deployment/$deployment" --timeout=300s
done

if [ -f /vagrant/scripts/add_hosts.sh ]; then
  bash /vagrant/scripts/add_hosts.sh "$SERVER_IP"
fi

echo "P2 K3s server and Ingress are ready on $SERVER_IP via $PRIVATE_INTERFACE."
