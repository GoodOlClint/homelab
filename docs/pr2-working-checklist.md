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
- [x] Add documented required-secrets contract table (keys + roles consuming them)
- [x] Confirm no strict secret key is missing from example scaffold

### Required Secret Contract

| Secret key | Consuming paths |
|---|---|
| `secrets.openobserve_root_user_pass` | monitoring templates, openobserve dashboards tasks |
| `secrets.grafana_admin_password` | monitoring docker compose and status/debug output |
| `secrets.proxmox_token_value` | monitoring pve exporter template |
| `secrets.unifi_admin_password` | monitoring-users UniFi admin API tasks |
| `secrets.unifi_monitoring_password` | monitoring-users UniFi monitoring-user tasks |
| `secrets.unifi_password` | monitoring stack env for UniFi poller |
| `secrets.synology_admin_password` | monitoring-users Synology setup tasks |
| `secrets.pbs_admin_password` | proxmox backup defaults (`pbs_root_password`) |
| `secrets.pbs_backup_user_password` | proxmox backup user-create task |
| `secrets.pbs_backup_token` | pbs client env + backup repository password wiring |
| `secrets.pbs_api_token` | monitoring PBS exporter template |
| `secrets.pbs_monitoring_token` | legacy compatibility var mapping in tracked vars |
| `secrets.cloudflared_tunnel_token` | docker + plex services cloudflared templates/tasks |
| `secrets.postgres_password` | plex services postgres tasks/templates |
| `secrets.plex_smb_pass` | plex backup/restore templates |

## Phase C — Legacy Surface Reduction

- [x] Remove direct runtime reliance on secret literals in tracked `ansible/group_vars/all.yml`
- [x] Keep only non-secret defaults/placeholders where needed
- [x] Update docs to indicate old var names are deprecated

## Verification

- [x] `pre-commit` on changed PR2 files
- [x] `make security-check`
- [x] Infrastructure playbook smoke check (`--check --list-tasks`)
- [x] Services playbook smoke check (`--check --list-tasks`)

## Remaining to close PR2

All PR2 checklist items are complete.
