#!/usr/bin/env bash
#
# Validate the GCE L1 host after startup.sh and prepare-host-user.sh.
# This intentionally fails early when nested KVM, Vagrant 2.4.9, the libvirt
# plugin, or the user's Docker/libvirt permissions are missing.

set -euo pipefail

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

for command_name in \
  docker \
  virsh \
  virt-host-validate \
  vagrant \
  kubectl \
  k3d \
  argocd \
  git \
  rsync \
  jq; do
  require_command "$command_name"
done

if [ "$(uname -m)" != "x86_64" ]; then
  echo "This workflow requires an x86_64 L1 host; found $(uname -m)." >&2
  exit 1
fi

if [ ! -e /dev/kvm ]; then
  echo "/dev/kvm is missing: nested virtualization is not enabled on the L1 VM." >&2
  exit 1
fi

if ! vagrant --version | grep -Fq "2.4.9"; then
  echo "Expected Vagrant 2.4.9." >&2
  exit 1
fi

if ! vagrant plugin list | awk '{print $1}' | grep -Fxq "vagrant-libvirt"; then
  echo "Missing Vagrant plugin: vagrant-libvirt." >&2
  exit 1
fi

virt-host-validate qemu
virsh -c qemu:///system list --all >/dev/null
docker info >/dev/null

echo "L1 validation passed: x86_64, /dev/kvm, libvirt, Vagrant 2.4.9, Docker, k3d, kubectl, and Argo CD CLI are ready."
