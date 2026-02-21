#!/bin/bash
set -eux

echo "==> Configuring QEMU Guest Agent"

# Enable and start qemu-guest-agent
systemctl enable qemu-guest-agent
systemctl start qemu-guest-agent

# Verify it's running
systemctl status qemu-guest-agent --no-pager

echo "==> QEMU Guest Agent configured successfully"
