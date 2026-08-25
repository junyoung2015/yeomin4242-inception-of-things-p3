#!/usr/bin/env bash

set -euo pipefail

SERVER_IP="192.168.56.110"
WORKER_IP="192.168.56.111"
# Kubernetes resource names are DNS labels, so K3s normalizes the mixed-case
# subject hostnames yeominS/yeominSW to these lower-case node names.
SERVER_NODE="yeomins"
WORKER_NODE="yeominsw"

echo "=== P1: K3s two-node validation ==="
vagrant status

echo "=== Checking required machine names and static addresses ==="
vagrant ssh yeominS -c 'test "$(hostname)" = yeominS'
vagrant ssh yeominSW -c 'test "$(hostname)" = yeominSW'
vagrant ssh yeominS -c "ip -o -4 addr show | grep -F '$SERVER_IP/'"
vagrant ssh yeominSW -c "ip -o -4 addr show | grep -F '$WORKER_IP/'"

echo "=== Checking K3s roles and node readiness ==="
vagrant ssh yeominS -c "systemctl is-active --quiet k3s"
vagrant ssh yeominSW -c "systemctl is-active --quiet k3s-agent"
vagrant ssh yeominS -c "KUBECONFIG=/home/vagrant/.kube/config kubectl wait --for=condition=Ready node/$SERVER_NODE node/$WORKER_NODE --timeout=180s"
vagrant ssh yeominS -c "KUBECONFIG=/home/vagrant/.kube/config kubectl get nodes -o wide"

echo "P1 validation passed: yeominS=$SERVER_IP and yeominSW=$WORKER_IP are Ready."
