# PR0 Security Baseline (Public Repo Safe)

This repository uses a two-layer network policy model:

1. **Public policy layer** (tracked): intent-only rules with zones/aliases.
2. **Private bindings layer** (local-only): VLAN IDs, interfaces, CIDRs, host/IP mappings.

## Files

### Tracked (safe to publish)
- `network-data/public_policy.yaml`
- `network-data/private_bindings.example.yaml`

### Local-only (not tracked)
- `network-data/local/private_bindings.yaml`
- `ansible/group_vars/local/all.yml`
- `ansible/group_vars/secrets.sops.yml`

## Workflow

1. Copy template:
   - `cp network-data/private_bindings.example.yaml network-data/local/private_bindings.yaml`
2. Fill local values (CIDRs, interface names, host mappings).
3. Keep real secrets out of tracked files.
4. Validate public policy:
   - `make validate-public-policy`

### Bootstrap local files quickly

- `make bootstrap-local`

## Guardrails (Prevent Accidental Secret Commits)

PR0 now includes two enforcement layers:

1. **Local pre-commit hook**
   - Runs `scripts/security_guardrails.sh --staged`
   - Enforces:
   - no edits to protected high-risk tracked files (`group_vars/all.yml`, tracked tfvars/tfstate, generated inventory)
     - no IP/CIDR literals in `network-data/public_policy.yaml`
     - secret scanning of staged changes with `gitleaks`

2. **GitHub Actions CI workflow**
   - File: `.github/workflows/security-guardrails.yml`
   - Runs on pull requests and pushes to `main`
   - Scans only the incoming commit range to avoid legacy-history noise

### Local Setup

Install required tools:

- `brew install pre-commit gitleaks`

Enable hooks once per clone:

- `make setup-hooks`

Manual check (before commit):

- `make security-check`

Manual range check (simulate CI range scan):

- `make security-check-range`

## Secrets Vault Approach (SOPS + age)

PR0 uses `sops` with `age` keys as the initial vault layer.

### Files

- SOPS rules: `.sops.yaml`
- Example secret structure: `ansible/group_vars/secrets.sops.example.yml`
- Local encrypted file (ignored): `ansible/group_vars/secrets.sops.yml`

### Setup

1. Install tools:
   - `brew install sops age`
2. Generate an age key:
   - `age-keygen -o ~/.config/sops/age/keys.txt`
3. Put your age public key into `.sops.yaml` (replace placeholder)
4. Bootstrap local files:
   - `make bootstrap-local`
5. Encrypt local secrets file:
   - `sops --encrypt --in-place ansible/group_vars/secrets.sops.yml`

### Optional future step

You can later move from SOPS-only to a dedicated Vault/OpenBao VM on Synology/Proxmox,
but SOPS provides immediate protection with minimal operational overhead for PR0.

## Why this split

- Makes policy shareable and reviewable publicly.
- Keeps topology and environment-specific details private.
- Reduces accidental leak risk when discussing segmentation patterns (e.g., AirPlay/mDNS across VLANs).
