#!/bin/bash
set -eux

echo "==> Applying basic security hardening"

# Disable root SSH login (but allow key-based for ansible user)
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

# Install security tools
apt-get install -y \
  ufw \
  auditd

# Configure UFW (but leave disabled - Ansible will configure per-VM)
ufw --force reset

# Enable auditd
systemctl enable auditd

# Set restrictive permissions on sensitive files
chmod 600 /etc/shadow
chmod 600 /etc/ssh/sshd_config

# Configure basic sysctl hardening
cat >> /etc/sysctl.conf <<EOF

# Basic hardening settings
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
EOF

sysctl -p

echo "==> Hardening complete"
