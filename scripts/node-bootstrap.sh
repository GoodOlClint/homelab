#!/usr/bin/env bash
# The single hand-off step (ADR-0002): after a fresh answer-file install, create
# the terraform@pve user + API token so Terraform can own the host plane with a
# dedicated least-privilege identity instead of root.
#
# Runs over SSH to the freshly-installed node's VLAN 30 mgmt IP (the stable link).
# Idempotent: skips the user/token if they already exist.
#
# Usage:  scripts/node-bootstrap.sh <node-mgmt-ip>
# Store the printed token secret in bootstrap.sops.yml as proxmox_terraform_token,
# then set TF_VAR_virtual_environment_api_token to use it (see terraform/hosts/README.md).

set -euo pipefail
IP="${1:?usage: node-bootstrap.sh <node-mgmt-ip>}"
SSH="ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new root@${IP}"

$SSH bash -s <<'REMOTE'
set -e
USER="terraform@pve"
if ! pveum user list | grep -q "terraform@pve"; then
  pveum user add terraform@pve --comment "Terraform host-plane identity (terraform/hosts)"
fi
pveum aclmod / --user terraform@pve --role Administrator
if pveum user token list terraform@pve 2>/dev/null | grep -q " provider "; then
  echo "TOKEN_EXISTS: terraform@pve!provider already present — regenerate manually if the secret was lost."
else
  echo "=== NEW TOKEN (store the value in bootstrap.sops.yml as proxmox_terraform_token) ==="
  pveum user token add terraform@pve provider --privsep 0
fi
REMOTE
