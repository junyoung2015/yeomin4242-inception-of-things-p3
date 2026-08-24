#!/usr/bin/env bash
#
# GCE startup script for the temporary Ubuntu 26.04 x86 L1 host.
# It installs host-level prerequisites only. The OS Login user must run
# scripts/prepare-host-user.sh after the first IAP SSH login so that Vagrant's
# per-user vagrant-libvirt plugin and Unix group memberships are configured.

set -euo pipefail

LOG_FILE="/var/log/iot-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

export DEBIAN_FRONTEND=noninteractive
VAGRANT_VERSION="2.4.9"
VAGRANT_DEB="/tmp/vagrant_${VAGRANT_VERSION}_amd64.deb"

echo "[iot-bootstrap] started at $(date --iso-8601=seconds)"

apt-get update
apt-get install -y \
  ca-certificates \
  curl \
  git \
  gnupg \
  jq \
  make \
  openssl \
  pkg-config \
  qemu-kvm \
  libvirt-clients \
  libvirt-daemon-system \
  libvirt-dev \
  bridge-utils \
  dnsmasq-base \
  rsync \
  ruby-dev \
  gcc \
  docker.io

systemctl enable --now docker
systemctl enable --now libvirtd || true
systemctl enable --now virtqemud || true

# Do not disable KVM here. Nested virtualization is deliberately requested
# on the GCE L1 instance and must remain available to libvirt/QEMU.
modprobe kvm_intel || true
test -e /dev/kvm

if ! command -v vagrant >/dev/null 2>&1 || ! vagrant --version | grep -Fq "$VAGRANT_VERSION"; then
  curl -fsSL \
    "https://releases.hashicorp.com/vagrant/${VAGRANT_VERSION}/vagrant_${VAGRANT_VERSION}-1_amd64.deb" \
    -o "$VAGRANT_DEB"
  apt-get install -y "$VAGRANT_DEB"
  rm -f "$VAGRANT_DEB"
fi

install_kubectl() {
  local kubectl_version kubectl_checksum
  kubectl_version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  kubectl_checksum="$(curl -fsSL "https://dl.k8s.io/release/${kubectl_version}/bin/linux/amd64/kubectl.sha256")"
  curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${kubectl_version}/bin/linux/amd64/kubectl"
  echo "${kubectl_checksum}  /tmp/kubectl" | sha256sum --check
  install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl
}

if ! command -v kubectl >/dev/null 2>&1; then
  install_kubectl
fi

install_k3d() {
  local k3d_version
  k3d_version="$(curl -fsSL https://api.github.com/repos/k3d-io/k3d/releases/latest | jq -r '.tag_name')"
  test -n "$k3d_version"
  test "$k3d_version" != "null"
  curl -fsSL \
    -o /tmp/k3d \
    "https://github.com/k3d-io/k3d/releases/download/${k3d_version}/k3d-linux-amd64"
  install -m 0755 /tmp/k3d /usr/local/bin/k3d
  rm -f /tmp/k3d
}

if ! command -v k3d >/dev/null 2>&1; then
  install_k3d
fi

install_argocd() {
  local argocd_version
  argocd_version="$(curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases/latest | jq -r '.tag_name')"
  test -n "$argocd_version"
  test "$argocd_version" != "null"
  curl -fsSL \
    -o /tmp/argocd \
    "https://github.com/argoproj/argo-cd/releases/download/${argocd_version}/argocd-linux-amd64"
  install -m 0755 /tmp/argocd /usr/local/bin/argocd
  rm -f /tmp/argocd
}

if ! command -v argocd >/dev/null 2>&1; then
  install_argocd
fi

echo "[iot-bootstrap] complete at $(date --iso-8601=seconds)"
