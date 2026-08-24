#!/usr/bin/env bash

set -euo pipefail

SERVER_IP="192.168.56.110"
WORKER_IP="192.168.56.111"

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
vagrant ssh yeominS -c "kubectl wait --for=condition=Ready node/yeominS node/yeominSW --timeout=180s"
vagrant ssh yeominS -c "kubectl get nodes -o wide"

echo "P1 validation passed: yeominS=$SERVER_IP and yeominSW=$WORKER_IP are Ready."
