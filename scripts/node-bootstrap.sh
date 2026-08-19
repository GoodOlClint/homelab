#!/usr/bin/env bash
# The single hand-off step (ADR-0002): after a fresh answer-file install, create
# the terraform@pve user + API token so Terraform can own the host plane with a
# dedicated least-privilege identity instead of root.
#
# Runs over SSH to the freshly-installed node's VLAN 30 mgmt IP (the stable link).
# Idempotent: skips the user/token if they already exist.
#
# Usage:  scripts/node-bootstrap.sh <node-mgmt-ip>
# Run it on the CLUSTER BOOTSTRAP node only and store that token in bootstrap.sops.yml
# as proxmox_terraform_token: users/tokens live in /etc/pve, so a token minted on a
# node that later JOINS the cluster is replaced by the cluster's at join time.
# terraform/hosts still authenticates as root@pam/password (Makefile); switching
# the provider to this token is follow-up work (ADR-0002 least-privilege intent).

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
  echo "=== NEW TOKEN (bootstrap node only: store as proxmox_terraform_token in bootstrap.sops.yml; a joining node's token is discarded at join) ==="
  pveum user token add terraform@pve provider --privsep 0
fi
REMOTE
