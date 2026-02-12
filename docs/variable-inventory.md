# Variable Inventory for PR1 -> PR2 Migration

Purpose: identify sensitive variables currently in tracked files and map them to consumers and target secret namespace.

## Scope and Method

- Source files scanned:
  - `ansible/group_vars/all.yml`
  - `terraform/infrastructure/vars.auto.tfvars`
  - `terraform/services/vars.auto.tfvars`
- Consumer paths identified via repository-wide search in Ansible templates/tasks and Terraform providers/modules.

## Priority 0 — Immediate High-Risk Secrets (Migrate first)

| Current variable | Current tracked source | Primary consumers | Proposed target key |
|---|---|---|---|
| `openobserve_root_user_pass` | `ansible/group_vars/all.yml` | monitoring templates (`openobserve.env.j2`, `grafana-datasource.yml.j2`, `axosyslog.conf.j2`, `prometheus.yml.j2`) | `secrets.openobserve_root_user_pass` |
| `grafana_admin_password` | `ansible/group_vars/all.yml` | monitoring docker compose template | `secrets.grafana_admin_password` |
| `proxmox_token_value` | `ansible/group_vars/all.yml` | monitoring docker compose template (`PVE_TOKEN_VALUE`) | `secrets.proxmox_token_value` |
| `unifi_admin_password` | `ansible/group_vars/all.yml` | `roles-infrastructure/monitoring-users/tasks/unifi.yml` | `secrets.unifi_admin_password` |
| `unifi_password` | `ansible/group_vars/all.yml` | monitoring users/tasks + monitoring docker compose (`UP_UNIFI_DEFAULT_PASS`) | `secrets.unifi_password` |
| `synology_admin_password` | `ansible/group_vars/all.yml` | `roles-infrastructure/monitoring-users/tasks/synology.yml` | `secrets.synology_admin_password` |
| `cloudflared_tunnel_token` | `ansible/group_vars/all.yml` | docker role/tasks + docker env templates + plex services compose template | `secrets.cloudflared_tunnel_token` |
| `pbs_admin_password` | `ansible/group_vars/all.yml` | proxmox backup defaults/tasks | `secrets.pbs_admin_password` |
| `pbs_backup_token` | `ansible/group_vars/all.yml` | pbs client env template + backup repository vars | `secrets.pbs_backup_token` |
| `pbs_api_token` | `ansible/group_vars/all.yml` | monitoring docker compose template (`PBS_API_TOKEN`) | `secrets.pbs_api_token` |
| `postgres_password` | `ansible/group_vars/all.yml` | plex_services tasks/templates and compose | `secrets.postgres_password` |

## Priority 1 — Terraform Sensitive Inputs

| Current variable | Current tracked source | Primary consumers | Proposed secure source |
|---|---|---|---|
| `virtual_environment_password` | both tracked `vars.auto.tfvars` | `provider.tf` for Proxmox auth | local-only tfvars or `TF_VAR_virtual_environment_password` |
| `unifi_password` | both tracked `vars.auto.tfvars` | `provider.tf` for UniFi auth, dynamic network discovery | local-only tfvars or `TF_VAR_unifi_password` |
| `virtual_machine_password_hash` | both tracked `vars.auto.tfvars` | module/VM provisioning variables | local-only tfvars or `TF_VAR_virtual_machine_password_hash` |

## Priority 2 — Service Password Blocks in Ansible Vars

These are currently placeholders/defaults in tracked vars and should be normalized under `secrets.*` where actually required at runtime:

- `sonarr_postgres_password`
- `radarr_postgres_password`
- `prowlarr_postgres_password`
- `bazarr_postgres_password`
- `sabnzbd_postgres_password`
- `tautulli_postgres_password`
- `jellyseerr_postgres_password`
- `lidarr_postgres_password`

## Existing Secret Scaffold Alignment

Current scaffold file already contains several keys under `secrets`:

- `unifi_admin_user`
- `unifi_admin_password`
- `unifi_monitoring_user`
- `unifi_monitoring_password`
- `proxmox_api_user`
- `proxmox_api_token`
- `pbs_admin_password`
- `pbs_backup_token`
- `cloudflared_tunnel_token`

Action for PR2: extend this set to include remaining required keys (OpenObserve/Grafana/Postgres/PBS monitoring token fields) and align role lookups to `secrets.*`.

## Migration Rules for PR2

1. Preserve compatibility during transition:
   - `secrets.foo | default(foo)` until cutover is complete.
2. Keep tracked files with non-secret placeholders only.
3. Ensure no template/task fails when secrets file is absent in dev/test contexts.
4. After full cutover, remove legacy fallbacks in a cleanup PR.

## Current Migration Status (end of PR1)

- Completed in code (fallback implemented):
  - OpenObserve root password consumers
  - Grafana admin password consumers
  - Proxmox token value consumer (monitoring exporter)
  - UniFi admin/monitoring password consumers
  - Synology admin password consumer
  - Cloudflare tunnel token consumers
  - PBS backup/api token consumers in active templates/tasks
  - PostgreSQL service root password consumers
- Remaining for PR2 completion:
  - Consolidate legacy variable names and remove compatibility fallbacks after cutover
  - Update any non-active/legacy roles that still directly reference legacy secret vars

## Validation Plan for PR2

- Run check mode on changed playbooks/roles.
- Run `make security-check` and `make security-check-range` before each commit.
- Verify no new tracked secret literals are introduced.

## Notes

- Inventory is intentionally focused on runtime-sensitive values and active consumers.
- Non-sensitive topology values remain out-of-scope for this PR1 inventory and are covered by policy/bindings workstreams.
