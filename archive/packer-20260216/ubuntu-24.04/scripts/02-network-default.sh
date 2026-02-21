#!/bin/bash
set -e

echo "==> Configuring default network with DHCP"

# Create default netplan config that enables DHCP on all interfaces
cat > /etc/netplan/01-netcfg.yaml <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    # Match all ethernet interfaces
    all-eth:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
      optional: true
EOF

# Set proper permissions
chmod 600 /etc/netplan/01-netcfg.yaml

# Test the configuration (but don't apply yet, as we're in chroot/build)
netplan generate

echo "==> Default network configuration created"
