#!/bin/bash
set -eux

echo "==> Removing cloud-init completely"

# Stop cloud-init services
systemctl stop cloud-init.service || true
systemctl stop cloud-init-local.service || true
systemctl stop cloud-config.service || true
systemctl stop cloud-final.service || true

# Disable cloud-init services
systemctl disable cloud-init.service || true
systemctl disable cloud-init-local.service || true
systemctl disable cloud-config.service || true
systemctl disable cloud-final.service || true

# Remove cloud-init package
apt-get purge -y cloud-init

# Remove cloud-init directories and files
rm -rf /etc/cloud
rm -rf /var/lib/cloud
rm -f /var/log/cloud-init*

echo "==> Cloud-init removed successfully"
