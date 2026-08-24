#!/usr/bin/env bash
#
# This is the P3 proof step. It changes the real public Git source, pushes
# main, and waits for Argo CD's automated policy to reconcile without a manual
# synchronization request or a deployment restart.

set -euo pipefail

GITOPS_REPO_DIR="${GITOPS_REPO_DIR:?Set GITOPS_REPO_DIR to a clean clone of the public GitHub source.}"
TARGET_REVISION="${TARGET_REVISION:-main}"
FROM_IMAGE="${FROM_IMAGE:-wil42/playground:v1}"
TO_IMAGE="${TO_IMAGE:-wil42/playground:v2}"
APP_NAME="${APP_NAME:-playground-app}"
APP_NAMESPACE="${APP_NAMESPACE:-dev}"
APP_DEPLOYMENT="${APP_DEPLOYMENT:-playground-deployment}"
APP_HTTP_PORT="${K3D_HTTP_PORT:-8888}"
MANIFEST="$GITOPS_REPO_DIR/dev/deployment.yaml"

if [ ! -d "$GITOPS_REPO_DIR/.git" ] || [ ! -f "$MANIFEST" ]; then
  echo "GITOPS_REPO_DIR must be a clone containing dev/deployment.yaml." >&2
  exit 1
fi

if ! git -C "$GITOPS_REPO_DIR" diff --quiet || ! git -C "$GITOPS_REPO_DIR" diff --cached --quiet; then
  echo "Refusing to change a dirty GitOps clone." >&2
  exit 1
fi

git -C "$GITOPS_REPO_DIR" fetch origin "$TARGET_REVISION"
git -C "$GITOPS_REPO_DIR" switch "$TARGET_REVISION"
git -C "$GITOPS_REPO_DIR" pull --ff-only origin "$TARGET_REVISION"

if ! grep -Fq "$FROM_IMAGE" "$MANIFEST"; then
  echo "Expected source image $FROM_IMAGE is not present in $MANIFEST." >&2
  exit 1
fi

sed -i "s|$FROM_IMAGE|$TO_IMAGE|g" "$MANIFEST"
git -C "$GITOPS_REPO_DIR" add dev/deployment.yaml
git -C "$GITOPS_REPO_DIR" commit -m "Verify Argo CD automatic v2 rollout"
git -C "$GITOPS_REPO_DIR" push origin "$TARGET_REVISION"

EXPECTED_REVISION="$(git -C "$GITOPS_REPO_DIR" rev-parse HEAD)"

for attempt in {1..120}; do
  sync_status="$(kubectl -n argocd get application "$APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health_status="$(kubectl -n argocd get application "$APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  observed_revision="$(kubectl -n argocd get application "$APP_NAME" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
  running_image="$(kubectl -n "$APP_NAMESPACE" get deployment "$APP_DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"

  if [ "$sync_status" = "Synced" ] && [ "$health_status" = "Healthy" ] && \
     [ "$observed_revision" = "$EXPECTED_REVISION" ] && [ "$running_image" = "$TO_IMAGE" ]; then
    curl --connect-timeout 3 -fsS -H "Host: playground.local" "http://127.0.0.1:$APP_HTTP_PORT/" >/dev/null
    echo "Automatic GitOps proof passed at commit $EXPECTED_REVISION with image $TO_IMAGE."
    exit 0
  fi

  sleep 5
done

kubectl -n argocd get application "$APP_NAME" -o yaml || true
kubectl -n "$APP_NAMESPACE" get deployment "$APP_DEPLOYMENT" -o wide || true
echo "Argo CD did not automatically reconcile the pushed v2 commit." >&2
exit 1
