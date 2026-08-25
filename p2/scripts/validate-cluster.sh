#!/usr/bin/env bash

set -euo pipefail

SERVER_IP="192.168.56.110"

assert_route() {
  local label="$1"
  local host_header="$2"
  local expected="$3"
  local response

  for attempt in {1..24}; do
    if [ -n "$host_header" ]; then
      response="$(curl --connect-timeout 3 -fsS -H "$host_header" "http://$SERVER_IP/" 2>/dev/null || true)"
    else
      response="$(curl --connect-timeout 3 -fsS "http://$SERVER_IP/" 2>/dev/null || true)"
    fi

    if printf '%s' "$response" | grep -Fq "$expected"; then
      echo "OK: $label"
      return 0
    fi
    sleep 5
  done

  echo "Routing check failed: $label" >&2
  printf '%s\n' "$response" >&2
  return 1
}

echo "=== P2: K3s multi-application Ingress validation ==="
vagrant status

echo "=== Checking yeominS and its required static address ==="
vagrant ssh yeominS -c 'test "$(hostname)" = yeominS'
vagrant ssh yeominS -c "ip -o -4 addr show | grep -F '$SERVER_IP/'"
vagrant ssh yeominS -c "systemctl is-active --quiet k3s"
vagrant ssh yeominS -c "KUBECONFIG=/home/vagrant/.kube/config kubectl wait --for=condition=Ready node/yeominS --timeout=180s"

echo "=== Checking deployments, replicas, services, endpoints, and Ingress ==="
vagrant ssh yeominS -c "KUBECONFIG=/home/vagrant/.kube/config kubectl get deployments app-1 app-2 app-3 -o wide"
vagrant ssh yeominS -c "KUBECONFIG=/home/vagrant/.kube/config kubectl rollout status deployment/app-1 --timeout=180s"
vagrant ssh yeominS -c "KUBECONFIG=/home/vagrant/.kube/config kubectl rollout status deployment/app-2 --timeout=180s"
vagrant ssh yeominS -c "KUBECONFIG=/home/vagrant/.kube/config kubectl rollout status deployment/app-3 --timeout=180s"
vagrant ssh yeominS -c "test \"\$(KUBECONFIG=/home/vagrant/.kube/config kubectl get deployment app-2 -o jsonpath='{.spec.replicas}')\" = 3"
vagrant ssh yeominS -c "test \"\$(KUBECONFIG=/home/vagrant/.kube/config kubectl get deployment app-2 -o jsonpath='{.status.readyReplicas}')\" = 3"
vagrant ssh yeominS -c "KUBECONFIG=/home/vagrant/.kube/config kubectl get svc app-1 app-2 app-3"
vagrant ssh yeominS -c "KUBECONFIG=/home/vagrant/.kube/config kubectl get endpoints app-1 app-2 app-3"
vagrant ssh yeominS -c "KUBECONFIG=/home/vagrant/.kube/config kubectl get ingress multi-app-ingress"
vagrant ssh yeominS -c "KUBECONFIG=/home/vagrant/.kube/config kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik"

echo "=== Checking routing from the L1 libvirt host ==="
assert_route "app1.com" "Host: app1.com" "This is app 1!"
assert_route "app2.com" "Host: app2.com" "This is app 2!"
assert_route "app3.com" "Host: app3.com" "This is app 3!"
assert_route "default route" "" "This is app 3!"

echo "P2 validation passed: three apps, app-2 replicas=3, and Traefik host/default routing are correct."
