#!/usr/bin/env bash

set -euo pipefail

APP_NAME="${APP_NAME:-playground-app}"
APP_NAMESPACE="${APP_NAMESPACE:-dev}"
APP_DEPLOYMENT="${APP_DEPLOYMENT:-playground-deployment}"
APP_HTTP_PORT="${K3D_HTTP_PORT:-8888}"
EXPECTED_REVISION="${EXPECTED_REVISION:-}"
EXPECTED_IMAGE="${EXPECTED_IMAGE:-}"

sync_status="$(kubectl -n argocd get application "$APP_NAME" -o jsonpath='{.status.sync.status}')"
health_status="$(kubectl -n argocd get application "$APP_NAME" -o jsonpath='{.status.health.status}')"
observed_revision="$(kubectl -n argocd get application "$APP_NAME" -o jsonpath='{.status.sync.revision}')"

if [ "$sync_status" != "Synced" ] || [ "$health_status" != "Healthy" ]; then
  kubectl -n argocd get application "$APP_NAME" -o yaml
  echo "$APP_NAME is not Synced and Healthy." >&2
  exit 1
fi

if [ -n "$EXPECTED_REVISION" ] && [ "$observed_revision" != "$EXPECTED_REVISION" ]; then
  echo "Expected revision $EXPECTED_REVISION, observed $observed_revision." >&2
  exit 1
fi

kubectl -n "$APP_NAMESPACE" rollout status "deployment/$APP_DEPLOYMENT" --timeout=300s

running_image="$(kubectl -n "$APP_NAMESPACE" get deployment "$APP_DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].image}')"
if [ -n "$EXPECTED_IMAGE" ] && [ "$running_image" != "$EXPECTED_IMAGE" ]; then
  echo "Expected image $EXPECTED_IMAGE, observed $running_image." >&2
  exit 1
fi

for attempt in {1..24}; do
  if curl --connect-timeout 3 -fsS -H "Host: playground.local" "http://127.0.0.1:$APP_HTTP_PORT/" >/dev/null; then
    echo "$APP_NAME is Synced/Healthy at $observed_revision with image $running_image and HTTP 200."
    exit 0
  fi
  sleep 5
done

echo "The app did not return HTTP 200 through the local-only k3d load balancer." >&2
exit 1
