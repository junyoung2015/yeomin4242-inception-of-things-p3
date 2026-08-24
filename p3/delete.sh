#!/usr/bin/env bash

set -euo pipefail

K3D_CLUSTER="${K3D_CLUSTER:-iot-cluster}"

if k3d cluster list --no-headers 2>/dev/null | awk '{ print $1 }' | grep -Fxq "$K3D_CLUSTER"; then
  k3d cluster delete "$K3D_CLUSTER"
  echo "Deleted k3d cluster $K3D_CLUSTER."
else
  echo "k3d cluster $K3D_CLUSTER does not exist; nothing to delete."
fi

echo "Any user-started kubectl port-forward process can be stopped from its original terminal."
