#!/usr/bin/env bash
#
# Run once from the first non-root OS Login session after startup.sh has
# completed. It installs the per-user Vagrant plugin and grants the minimum
# Unix group access required for Docker and libvirt.

set -euo pipefail

TARGET_USER="${SUDO_USER:-$USER}"

if [ "$TARGET_USER" = "root" ]; then
  echo "Run this script as the OS Login user, not as root." >&2
  exit 1
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
  echo "Cannot determine the home directory for $TARGET_USER." >&2
  exit 1
fi

for required_group in docker libvirt kvm; do
  if getent group "$required_group" >/dev/null; then
    sudo usermod -aG "$required_group" "$TARGET_USER"
  fi
done

if ! sudo -H -u "$TARGET_USER" env HOME="$TARGET_HOME" \
  vagrant plugin list | awk '{print $1}' | grep -Fxq "vagrant-libvirt"; then
  sudo -H -u "$TARGET_USER" env HOME="$TARGET_HOME" \
    vagrant plugin install vagrant-libvirt
fi

cat <<EOF
Host-user preparation finished for $TARGET_USER.

Log out of this SSH session and reconnect through IAP before running Docker,
virsh, or Vagrant. The new docker/libvirt/kvm group memberships apply only to
new login sessions.
EOF
