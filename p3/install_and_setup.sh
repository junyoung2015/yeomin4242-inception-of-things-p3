#!/usr/bin/env bash
#
# Run on the GCE L1 host after iot-terraform/scripts/validate-setup.sh.
# The Git source is intentionally explicit: this script never falls back to
# the local origin remote or to the teammate's read-only repository.

set -euo pipefail

REPO_URL="${REPO_URL:?Set REPO_URL to the public GitHub repository URL.}"
TARGET_REVISION="${TARGET_REVISION:?Set TARGET_REVISION, normally main.}"
K3D_CLUSTER="${K3D_CLUSTER:-iot-cluster}"
K3D_BIND_ADDRESS="${K3D_BIND_ADDRESS:-127.0.0.1}"
K3D_HTTP_PORT="${K3D_HTTP_PORT:-8888}"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)"
REMOTE_COMMIT=""

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

for required_command in docker kubectl k3d git diff rsync curl; do
  require_command "$required_command"
done

if [ "$K3D_BIND_ADDRESS" != "127.0.0.1" ]; then
  echo "K3D_BIND_ADDRESS must remain 127.0.0.1 for this test deployment." >&2
  exit 1
fi

if ! [[ "$K3D_HTTP_PORT" =~ ^[0-9]+$ ]]; then
  echo "K3D_HTTP_PORT must be numeric." >&2
  exit 1
fi

docker info >/dev/null

verify_remote_dev_tree() {
  local temporary_clone

  REMOTE_COMMIT="$(git ls-remote "$REPO_URL" "refs/heads/$TARGET_REVISION" | awk 'NR == 1 { print $1 }')"

  if [ -z "$REMOTE_COMMIT" ]; then
    echo "Cannot find branch $TARGET_REVISION in $REPO_URL." >&2
    exit 1
  fi

  temporary_clone="$(mktemp -d)"
  if ! git clone --depth 1 --branch "$TARGET_REVISION" "$REPO_URL" "$temporary_clone/remote" >/dev/null 2>&1; then
    rm -rf "$temporary_clone"
    echo "Cannot clone $REPO_URL at $TARGET_REVISION." >&2
    exit 1
  fi

  if ! diff -qr --exclude '.DS_Store' "$REPO_ROOT/dev" "$temporary_clone/remote/dev" >/dev/null; then
    rm -rf "$temporary_clone"
    echo "Local dev/ differs from the requested remote Git source." >&2
    echo "Push the sanitized project first. Argo CD must sync the actual remote dev/ tree." >&2
    exit 1
  fi

  rm -rf "$temporary_clone"
}

cluster_exists() {
  k3d cluster list --no-headers 2>/dev/null | awk '{ print $1 }' | grep -Fxq "$K3D_CLUSTER"
}

wait_for_application() {
  local app_name="$1"
  local expected_revision="$2"
  local sync_status health_status observed_revision

  for attempt in {1..120}; do
    sync_status="$(kubectl -n argocd get application "$app_name" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health_status="$(kubectl -n argocd get application "$app_name" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    observed_revision="$(kubectl -n argocd get application "$app_name" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"

    if [ "$sync_status" = "Synced" ] && [ "$health_status" = "Healthy" ] && [ "$observed_revision" = "$expected_revision" ]; then
      return 0
    fi

    sleep 5
  done

  kubectl -n argocd get application "$app_name" -o yaml || true
  echo "Application $app_name did not reach Synced/Healthy at revision $expected_revision." >&2
  return 1
}

verify_remote_dev_tree

if ! cluster_exists; then
  k3d cluster create "$K3D_CLUSTER" \
    --agents 2 \
    --port "$K3D_BIND_ADDRESS:$K3D_HTTP_PORT:80@loadbalancer"
fi

kubectl config use-context "k3d-$K3D_CLUSTER" >/dev/null
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -

kubectl apply --server-side --force-conflicts \
  -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=180s
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s

APP_MANIFEST="$(mktemp)"
cleanup_manifest() {
  rm -f "$APP_MANIFEST"
}
trap cleanup_manifest EXIT

sed \
  -e "s#^[[:space:]]*repoURL:.*#    repoURL: \"$REPO_URL\"#" \
  -e "s#^[[:space:]]*targetRevision:.*#    targetRevision: \"$TARGET_REVISION\"#" \
  "$SCRIPT_DIR/application.yaml" > "$APP_MANIFEST"

kubectl apply -f "$APP_MANIFEST"
wait_for_application "playground-app" "$REMOTE_COMMIT"
kubectl -n dev rollout status deployment/playground-deployment --timeout=300s

echo "P3 initial GitOps deployment is ready."
echo "Application source: $REPO_URL @ $TARGET_REVISION ($REMOTE_COMMIT)"
echo "Local-only app endpoint: curl -H 'Host: playground.local' http://127.0.0.1:$K3D_HTTP_PORT/"
echo "For the Argo CD UI, start a temporary local-only tunnel when needed:"
echo "  kubectl -n argocd port-forward svc/argocd-server 8081:443"
echo "No Argo CD password or manual sync command is emitted by this script."
