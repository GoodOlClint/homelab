#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$ROOT_DIR/network-data/local" "$ROOT_DIR/ansible/group_vars/local"

# Network binding files
if [[ ! -f "$ROOT_DIR/network-data/vlans.yaml" ]]; then
  cp "$ROOT_DIR/network-data/vlans.example.yaml" "$ROOT_DIR/network-data/vlans.yaml"
  echo "Created network-data/vlans.yaml — fill in site-specific values"
else
  echo "Exists: network-data/vlans.yaml"
fi

if [[ ! -f "$ROOT_DIR/network-data/private_bindings.yaml" ]]; then
  cp "$ROOT_DIR/network-data/private_bindings.example.yaml" "$ROOT_DIR/network-data/private_bindings.yaml"
  echo "Created network-data/private_bindings.yaml"
else
  echo "Exists: network-data/private_bindings.yaml"
fi

# Ansible secrets
if [[ ! -f "$ROOT_DIR/ansible/group_vars/local/all.yml" ]]; then
  if [[ -f "$ROOT_DIR/ansible/group_vars/local/all.example.yml" ]]; then
    cp "$ROOT_DIR/ansible/group_vars/local/all.example.yml" "$ROOT_DIR/ansible/group_vars/local/all.yml"
    echo "Created ansible/group_vars/local/all.yml"
  fi
else
  echo "Exists: ansible/group_vars/local/all.yml"
fi

if [[ ! -f "$ROOT_DIR/ansible/group_vars/secrets.sops.yml" ]]; then
  cp "$ROOT_DIR/ansible/group_vars/secrets.sops.example.yml" "$ROOT_DIR/ansible/group_vars/secrets.sops.yml"
  echo "Created ansible/group_vars/secrets.sops.yml (encrypt this with sops before committing)"
else
  echo "Exists: ansible/group_vars/secrets.sops.yml"
fi

# Terraform variables (consolidated project)
if [[ ! -f "$ROOT_DIR/terraform/vars.auto.tfvars" ]]; then
  cp "$ROOT_DIR/terraform/vars.auto.tfvars.example" "$ROOT_DIR/terraform/vars.auto.tfvars"
  echo "Created terraform/vars.auto.tfvars"
else
  echo "Exists: terraform/vars.auto.tfvars"
fi

echo "Bootstrap complete. Review and fill local files before running Terraform/Ansible."
