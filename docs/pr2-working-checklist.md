# PR2 Working Checklist (Secret Namespace Cutover)

Goal: complete migration from legacy secret vars to explicit `secrets.*` usage.

## Phase A — Strict Namespace Enablement

- [x] Load `ansible/group_vars/secrets.sops.yml` explicitly in active playbooks
  - [x] `ansible/playbooks/infrastructure.yml`
  - [x] `ansible/playbooks/services.yml`
  - [x] `ansible/playbooks/docker.yml`
- [x] Remove fallback lookups (`secrets | default({}).get(...)`) from active roles/templates
- [x] Move key active consumers to strict `secrets.*` references:
  - [x] monitoring stack auth values (OpenObserve/Grafana/PVE/UniFi/PBS)
  - [x] monitoring-users credentials (UniFi/Synology)
  - [x] docker cloudflared token path
  - [x] plex services postgres and tunnel credentials
  - [x] pbs client password and proxmox backup root password

## Phase B — Placeholder and Contract Hygiene

- [x] Extend `ansible/group_vars/secrets.sops.example.yml` with required keys used by strict consumers
- [ ] Add documented required-secrets contract table (keys + roles consuming them)
- [ ] Confirm no strict secret key is missing from example scaffold

## Phase C — Legacy Surface Reduction

- [ ] Remove direct runtime reliance on secret literals in tracked `ansible/group_vars/all.yml`
- [ ] Keep only non-secret defaults/placeholders where needed
- [ ] Update docs to indicate old var names are deprecated

## Verification

- [x] `pre-commit` on changed PR2 files
- [x] `make security-check`
- [x] Infrastructure playbook smoke check (`--check --list-tasks`)
- [x] Services playbook smoke check (`--check --list-tasks`)

## Remaining to close PR2

1. Document required secret key contract.
2. Replace/remove remaining legacy secret literals in tracked vars.
3. Re-run guardrails and smoke checks.
4. Mark PR2 done in `docs/refactor-master-checklist.md`.
