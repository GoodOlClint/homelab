#!/bin/bash
set -eux

echo "==> Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

echo "==> Installing base packages"
apt-get install -y \
  qemu-guest-agent \
  python3 \
  python3-pip \
  curl \
  wget \
  vim \
  git \
  net-tools \
  dnsutils \
  inotify-tools \
  iproute2 \
  netplan.io \
  sudo

echo "==> Creating ansible user with sudo privileges"
useradd -m -s /bin/bash -G sudo ansible
echo 'ansible ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ansible
chmod 0440 /etc/sudoers.d/ansible

echo "==> Setting up ansible user SSH directory"
mkdir -p /home/ansible/.ssh
chmod 700 /home/ansible/.ssh
chown -R ansible:ansible /home/ansible/.ssh

echo "==> Base setup complete"
