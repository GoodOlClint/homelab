#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$ROOT_DIR/network-data/local" "$ROOT_DIR/ansible/group_vars/local"

if [[ ! -f "$ROOT_DIR/network-data/local/private_bindings.yaml" ]]; then
  cp "$ROOT_DIR/network-data/private_bindings.example.yaml" "$ROOT_DIR/network-data/local/private_bindings.yaml"
  echo "Created network-data/local/private_bindings.yaml"
else
  echo "Exists: network-data/local/private_bindings.yaml"
fi

if [[ ! -f "$ROOT_DIR/ansible/group_vars/local/all.yml" ]]; then
  cp "$ROOT_DIR/ansible/group_vars/local/all.example.yml" "$ROOT_DIR/ansible/group_vars/local/all.yml"
  echo "Created ansible/group_vars/local/all.yml"
else
  echo "Exists: ansible/group_vars/local/all.yml"
fi

if [[ ! -f "$ROOT_DIR/ansible/group_vars/secrets.sops.yml" ]]; then
  cp "$ROOT_DIR/ansible/group_vars/secrets.sops.example.yml" "$ROOT_DIR/ansible/group_vars/secrets.sops.yml"
  echo "Created ansible/group_vars/secrets.sops.yml (encrypt this with sops before committing)"
else
  echo "Exists: ansible/group_vars/secrets.sops.yml"
fi

echo "Bootstrap complete. Review and fill local files before running Terraform/Ansible."
