#!/bin/bash
set -eux

echo "==> Cleaning up"

# Remove packer user (temporary build user)
userdel -r packer || true

# Clean apt cache
apt-get clean
apt-get autoremove -y

# Remove unnecessary packages (if installed)
apt-get purge -y snapd || true
apt-get purge -y lxd || true

# Clear log files
find /var/log -type f -exec truncate -s 0 {} \;

# Clear command history
history -c
cat /dev/null > ~/.bash_history

# Remove SSH host keys (will be regenerated on first boot)
rm -f /etc/ssh/ssh_host_*

# Clear machine-id (will be regenerated on first boot)
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

# Remove temporary files
rm -rf /tmp/*
rm -rf /var/tmp/*

# Zero out free space to improve compression
# dd if=/dev/zero of=/EMPTY bs=1M || true
# rm -f /EMPTY

echo "==> Cleanup complete"
echo "==> Template is ready for use"
