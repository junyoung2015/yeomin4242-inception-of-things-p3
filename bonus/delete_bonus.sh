#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/.runtime"
K3D_CLUSTER="${K3D_CLUSTER:-iot-cluster}"
GITLAB_EXTERNAL_HOST="gitlab.gitlab.svc.cluster.local"
HOSTS_MARKER="# iot-bonus-gitlab"

if k3d cluster list --no-headers 2>/dev/null | awk '{ print $1 }' | grep -Fxq "$K3D_CLUSTER"; then
  k3d cluster delete "$K3D_CLUSTER"
  echo "Deleted k3d cluster $K3D_CLUSTER, including local GitLab PVC data."
else
  echo "k3d cluster $K3D_CLUSTER does not exist; no cluster resources were removed."
fi

if grep -Fq "$GITLAB_EXTERNAL_HOST $HOSTS_MARKER" /etc/hosts; then
  sudo sed -i "\|$GITLAB_EXTERNAL_HOST $HOSTS_MARKER|d" /etc/hosts
fi

if [ -d "$RUNTIME_DIR" ]; then
  rm -rf "$RUNTIME_DIR"
fi

echo "Removed bonus runtime credentials, temporary import files, and the tagged hosts entry."
echo "Stop any manually started kubectl port-forward process from its original terminal."
