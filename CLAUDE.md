# Claude Code Guidelines — Homelab Ansible/Terraform Repo

## Repo Overview

This repo automates a Proxmox-based homelab with Terraform (VM provisioning, SDN, Vultr VPS, Cloudflare DNS) and Ansible (software configuration, Docker stacks, monitoring, secrets management). Key VMs: AdGuard (DNS filtering), BIND9 (authoritative DNS), Infisical (secrets vault), OpenObserve (monitoring stack), Proxmox Backup Server, UniFi, Plex, plex-services (arr stack), Docker (legacy services), Homepage, Lancache, NVIDIA licensing. A Vultr VPS acts as a WireGuard relay for external access.

**Key directories:**
- `terraform/` — Single consolidated Terraform project with `modules/proxmox-vm/` and `modules/network/`
- `ansible/roles/` — Single flat directory (~30 roles)
- `ansible/playbooks/` — All playbooks (site.yml imports infrastructure.yml + services.yml)
- `ansible/tasks/` — Shared task files (secrets loading, generation, pre_tasks)
- `ansible/group_vars/` — Global vars (`all.yml`), bootstrap secrets (`bootstrap.sops.yml`)
- `ansible/inventory/` — Terraform-generated `vms.yaml` + static `proxmox.yaml`, `pfsense.yaml`, `vps.yaml`
- `network-data/` — Canonical `vlans.yaml` (gitignored), `public_policy.yaml` (tracked)
- `scripts/` — Infisical migration/backup, security guardrails, validation

## Before You Start Any Task

1. **Read before writing.** Always read the files you intend to modify and their related files (defaults, templates, tasks) before making changes. Understand the existing patterns.
2. **Check the inventory.** VM names, IPs, and group membership are in `ansible/inventory/vms.yaml` (Terraform-generated). Do not hardcode IPs.
3. **Check `group_vars/all.yml`** for existing variables before adding new ones to role defaults — `all.yml` overrides role defaults and causes silent variable collisions.
4. **Check `host_vars/`** for per-VM configuration (e.g., `plex-services.yml` has extensive service definitions).
5. **Check MEMORY.md** for known issues, gotchas, and architectural decisions before proposing changes.

## Greenfield Philosophy

- **No migration tasks.** Do not write version-check conditionals, one-time migration logic, or upgrade paths. Every role should work correctly on a fresh VM and be idempotent on re-run.
- **No version pinning without reason.** Use `latest` tags for Docker images unless there's a specific compatibility constraint.
- **Idempotent everything.** Every task must be safe to run repeatedly. Use `creates:`, `when:`, registered variables, and `changed_when:` to prevent unnecessary changes.
- **REPLACE_ME sentinel.** Secrets that haven't been generated yet use the string `REPLACE_ME`. The `generate_secret.yml` task checks for this value to decide whether to generate.

## Secrets Handling

### Two-Tier Architecture
- **Tier 1 (Bootstrap):** `ansible/group_vars/bootstrap.sops.yml` — SOPS-encrypted. Contains only provider credentials (Proxmox, Vultr, Cloudflare), Infisical auth (client_id, client_secret, admin creds), and external secrets (user-provided API keys, passwords). Referenced as `bootstrap.key_name` or `bootstrap_config.key_name`.
- **Tier 2 (Runtime):** Infisical VM — stores ALL runtime secrets. Organized into folders:
  `/shared`, `/monitoring`, `/plex`, `/plex-services`, `/homepage`, `/docker`, `/minio`, `/vps`, `/pfsense`, `/pbs`, `/infrastructure`
  Root `/` is **empty** — all secrets live in named subfolders.
- **No SOPS fallback.** If Infisical is unreachable, the deploy fails with a clear error. `secrets.sops.yml` is a DR artifact only (produced by `make infisical-backup`), never used at runtime.

### The `secrets` Fact
All secrets are loaded into a single `secrets` fact that matches the `secrets.sops.yml` structure:
- Root and `/shared` Infisical paths → flat keys: `secrets.key_name`
- Nested paths → nested dicts: `secrets.monitoring.key_name`, `secrets.plex_services.key_name`
- Key names are lowercased with hyphens converted to underscores

### Secret Delivery to Containers
All runtime secrets flow through **Infisical Agent env_files**. The agent polls Infisical, renders Go templates to `.env` files on disk, and containers read them via `env_file:` directives.

- Agent env_file path: `/etc/infisical/secrets/<name>.env`
- Go templates: `ansible/roles/infisical_client/templates/secrets/*.tpl.j2`
- Special case: Recyclarr uses `secrets.yml` (rendered by agent to `/opt/plex-services/recyclarr/secrets.yml`) with `!secret` YAML tags instead of env vars.
- Agent exec hooks: When a rendered file changes, the agent runs the configured `post_command` to restart the affected container (see `infisical_agent_templates` in playbook vars).
- **No baked secrets.** No `{{ secrets.xxx }}` appears in any docker-compose template.

### `generate_secret.yml` Calling Convention
Required variables:
```yaml
- ansible.builtin.include_tasks: "{{ playbook_dir }}/../tasks/generate_secret.yml"
  vars:
    secret_key: "my_password"                # lowercase key name (REQUIRED)
    secret_gen_cmd: "openssl rand -hex 32"   # shell command that prints value (REQUIRED)
    secret_comment: "Description for Infisical" # human-readable comment (REQUIRED)
    secret_infisical_path: "/monitoring"      # Infisical folder (REQUIRED — no default)
    secret_dict_path: "monitoring"            # nested dict key in secrets fact (REQUIRED)
    # Optional:
    secret_run_on: "{{ inventory_hostname }}" # host to run command on (default: "localhost")
```

### Rules
- **Never put secrets in `vars.auto.tfvars`** — enforced by pre-commit hook.
- **Never commit unencrypted secrets** — SOPS files only, gitleaks pre-commit hook scans for leaks.
- **Always use `{{ secrets.key_name }}`** — never reference bootstrap-tier secrets in templates (except the Infisical role itself which needs bootstrap creds before Infisical exists).
- **Resolve `secret_comment` to a fact** before passing to `infisical_write_secret.yml` to avoid recursive template loops. The `generate_secret.yml` task handles this automatically.
- **Use `printf '%s' value`** not `echo -n value` in generation commands — some shells output `-n` literally.
- **All secret key names must be lowercase with underscores** — no UPPERCASE keys in Infisical. Convention: `{component}_{secret_type}` (e.g., `pbs_admin_password`, `grafana_admin_password`).

## Infisical Folder Ownership

Each Infisical folder is owned by the role that generates/provisions its secrets. Consumers read from the source folder — no copies.

| Folder | Owner Role | Agent Readers | Auto-Generated | External (User-Provided) |
|--------|-----------|---------------|----------------|-------------------------|
| `/shared` | proxmox_backup | All VMs (via pbs_client) | pbs_fingerprint, pbs_backup_token | — |
| `/monitoring` | monitoring, monitoring_users, proxmox_backup | openobserve, homepage | grafana_admin_password, openobserve_root_user_pass, unifi_monitoring_password, pbs_api_token, proxmox_token_value | uptimerobot_heartbeat_url |
| `/plex` | plex, plex_certificate | plex, homepage | plex_token, plex_smb_pass, plex_cert_pfx_password | cloudflare_dns_api_token |
| `/plex-services` | plex_services | plex-services, homepage | postgres_password, *_db_password (×6), arr_admin_password, *_api_key (×8) | cloudflared_tunnel_token, usenet_*, nzb*_api_key, opensubtitlescom_* |
| `/docker` | docker, authentik | docker | valheim_server_password, authentik_secret_key, authentik_postgres_password | cloudflared_tunnel_token |
| `/vps` | vps_wireguard | — (no agent) | vps_wg_private_key | maxmind_license_key |
| `/pfsense` | — (manual ref) | — (no agent) | — | cloudflare_dns_api_token, bind_tsig_key_secret |
| `/pbs` | proxmox_backup | — (no agent) | pbs_admin_password, pbs_backup_user_password | — |
| `/infrastructure` | bind9 | — (no agent) | bind_tsig_key_secret | unifi_admin_password, synology_admin_password |
| `/homepage` | — (user-provided only) | homepage | — | adguard_*, unifi_*, authentik_token, portainer_api_key |
| `/minio` | minio | minio | minio_root_password | — |

**Key rules:**
- "Owner Role" is the Ansible role whose tasks write secrets to this folder via `generate_secret.yml` or `infisical_write_secret.yml`.
- "Agent Readers" are VMs whose Infisical Agent templates include `with secret` blocks reading from this folder.
- VMs without agents (vps, pfsense, pbs, infrastructure) consume secrets at Ansible deploy time via the `secrets` fact — not via agent.
- `/homepage` has no owner role that generates secrets — it contains only user-provided external credentials seeded from `bootstrap.sops.yml`.
- When adding a new secret, find the correct owner folder first. If no existing folder fits, consider whether the secret truly needs a new folder or should be added to an existing one.

## Ansible Conventions

### Playbook Structure
- Playbooks import `full_pre_tasks.yml` which loads: local overrides → bootstrap SOPS → secrets (Infisical, hard fail if unreachable) → VLAN definitions → VLAN prefix computation → dns_zones.
- Playbooks are role-based — inline tasks only in `docker-config.yml` (lightweight compose-only deploys) and bootstrap.
- Each play targets specific hosts via `hosts:` and runs the appropriate roles.
- `site.yml` imports `infrastructure.yml` then `services.yml`.

### VLAN Prefix Facts
Pre_tasks compute these facts from `network-data/vlans.yaml`:
- `mgmt_vlan_prefix`, `services_vlan_prefix`, `storage_vlan_prefix`, `core_vlan_prefix`
- Cross-VLAN IP translation: `{{ ansible_host | replace(mgmt_vlan_prefix, services_vlan_prefix) }}`
- `internal_network_cidr`: the `/12` covering all VLANs
- **SSH uses vlan10 (management) IPs by default.** `ansible_host` resolves to the management VLAN IP. When running ad-hoc SSH commands, use the vlan10 IP (i.e., `ansible_host` or the address from `vms.yaml`).

### Role Structure
- `tasks/main.yml` — entry point, may include subtask files
- `defaults/main.yml` — default variables (use `| default('')` for secrets that may not be set)
- `templates/` — Jinja2 templates (`.j2` extension)
- `handlers/main.yml` — handlers (restart services, etc.)
- `meta/main.yml` — dependencies (rare)
- No `vars/main.yml` unless truly constant (prefer defaults for overridability)

### Template Conventions
- Docker-compose templates live at `roles/<role>/templates/docker-compose.yml.j2`
- Templates are deployed to `/opt/<service>/` on the target VM
- Use `mode: '0600'` for files containing secrets, `'0644'` for non-sensitive configs
- Use `replace()` for literal string substitutions — do NOT use `regex_replace` with backslash escaping across YAML/Jinja2 layers

### Task Conventions
- Use FQCNs: `ansible.builtin.template`, `community.docker.docker_compose_v2`, etc.
- Use `run_once: true` for tasks that should only execute on one host in a play
- Use `delegate_to: localhost` + `become: false` for local/API operations
- `is succeeded` returns TRUE for skipped tasks — always add `is not skipped` when gating on a registered variable from a conditionally-skipped task
- `docker_compose_v2`: `restarted` is a `state` value, not a separate parameter

### Tags Strategy
Both `infrastructure.yml` and `services.yml` have play-level tags for targeted deploys:

**infrastructure.yml tags:** `phase1`, `phase2`, `phase3`, `dns`, `adguard`, `infisical`, `openobserve`, `proxmox-backup`, `unifi`, `monitoring`, `monitoring-users`, `users`

**services.yml tags:** `nvidia-licensing`, `docker`, `plex`, `plex-services`, `minio`, `homepage`, `lancache`

**How tags work with pre_tasks:**
- All `pre_tasks` blocks have `tags: [always]`, so secrets/VLANs/facts always load regardless of `--tags` filter.
- The `infisical_client` role's "Enable and start infisical-agent" task is tagged `always` — even when filtering by tags within a play, the agent is guaranteed to be running.
- Tags filter at the **play** level: `--tags docker` runs only the docker play (and its pre_tasks).

**Usage via Makefile:** Pass `TAGS=` to any ansible target:
```bash
make ansible docker TAGS=docker          # only the docker play
make ansible-infra TAGS=phase1           # infrastructure phase 1 only
make ansible-services TAGS=plex,homepage  # plex + homepage plays
```

### Variable Sourcing Priority
1. `ansible/inventory/host_vars/<vm>.yml` — per-VM config (plex-services has extensive definitions)
2. `ansible/group_vars/all.yml` — global vars (overrides role defaults!)
3. `ansible/roles/<role>/defaults/main.yml` — role defaults
4. `ansible/group_vars/local/all.yml` — local overrides (gitignored)

## Docker Conventions

- **Compose file location:** `/opt/<service>/docker-compose.yml` on the VM (e.g., `/opt/docker/`, `/opt/plex-services/`, `/opt/monitoring/`, `/opt/homepage/`). Each role defines a `*_base_dir` default variable for its path.
- **Restart policy:** `restart: unless-stopped` for all containers
- **Logging:** Docker daemon configured for syslog to OpenObserve (`configure_docker_logging.yml`)
- **NFS volumes:** Created as named Docker volumes with `driver_opts` for NFS. Plex-services auto-recreates volumes if mount options change.
- **NFS tuning:** `nfsvers=4.1,hard,intr,noatime,rsize=1048576,wsize=1048576,nconnect=4` (Synology negotiates down to 128KB rsize/wsize)
- **Restart on change:** Register template results, restart containers only `when: <registered_var> is changed`
- **env_file for Infisical agent secrets:** Path is `/etc/infisical/secrets/<name>.env`, rendered by the Infisical agent from Go templates in `infisical_client/templates/secrets/`

## Terraform Conventions

### Structure
- Single project at `terraform/` with `main.tf`, `vm-configs.tf`, `variables.tf`, `outputs.tf`, `provider.tf`
- `vm-configs.tf` defines all VMs in `local.infrastructure_vms` and `local.services_vms`
- `vars.auto.tfvars` for non-sensitive config only

### Secrets Flow
- Makefile reads `bootstrap.sops.yml` via `sops -d --extract` and exports as `TF_VAR_*` env vars
- Top-level `export` in Makefile — do NOT use `define`/`$(call)` with `$(eval export)`, it doesn't propagate
- `terraform refresh` updates state but NOT outputs — use `terraform apply -refresh-only -auto-approve`

### VM Configuration Patterns
- Each VM: `name`, `vm_id`, `vlans` (list), `ip_offset`, `cores`, `memory`, `disk_size`
- `protected = true` for critical VMs (currently: infisical). Override with `var.unprotect`
- `lifecycle.ignore_changes` on cloud-init file IDs to prevent VM recreation on template changes
- Management VLAN is always first interface; `vm_id` → static IP, no `vm_id` → DHCP
- MAC addresses: `52:54:00:{random}:{vlan_id/256}:{vlan_id%256}`
- Use `coalesce()` carefully — not short-circuit. Use `try()` for fallbacks referencing resources that may not exist during `-target` operations

### Inventory Generation
- `make inventory` runs `terraform output -raw ansible_inventory_yaml > ansible/inventory/vms.yaml`
- Always runs `clean-ssh` first to remove stale SSH keys

## Make Targets

| Target | What it does |
|--------|-------------|
| `make apply` | Full deploy: terraform → inventory → ansible-all |
| `make bootstrap` | First-time: terraform (adguard+infisical only) → inventory → ansible-bootstrap |
| `make plan [vm]` | Terraform plan (optionally scoped to one VM) |
| `make build <vm>` | Terraform + inventory + ansible for a single VM |
| `make rebuild <vm>` | Destroy VM → clean SSH → build |
| `make ansible <vm>` | Run site.yml limited to one host (supports `TAGS=`) |
| `make docker-config <vm>` | Deploy compose+config only, skip user/group/package/API setup |
| `make ansible-all` | Run full site.yml (supports `TAGS=`) |
| `make ansible-infra` | Run infrastructure.yml only (supports `TAGS=`) |
| `make ansible-services` | Run services.yml only (supports `TAGS=`) |
| `make update` | apt upgrade + docker pull on all hosts |
| `make vps-deploy` | 3-phase: terraform (SSH open) → ansible → terraform (SSH closed) |
| `make vps-rebuild` | Destroy + rebuild VPS |
| `make rebuild-infisical` | Destroy + rebuild Infisical VM (handles stale credentials) |
| `make infisical-seed` | Restore Infisical from backup (disaster recovery only) |
| `make infisical-backup` | Export Infisical → SOPS backup |
| `make refresh-identity` | Refresh Infisical machine identities (supports `LIMIT=`, `FORCE=true`) |
| `make clean` | Destroy all (protected VMs preserved). `FORCE=true` to destroy everything |
| `make setup-hooks` | Install pre-commit hooks |
| `make init` | Create venv, install deps, terraform init, galaxy install |

## Change Discipline

1. **Read the role and its templates** before modifying anything
2. **Check `docker-config.yml`** — if the service has a docker-config section, verify your changes work without the full role (docker-config skips package/user/group setup). Secrets no longer need flattening but templates must still render correctly in this lightweight context.
3. **Check the `generate_secret.yml` pattern** when adding new secrets — follow the existing convention exactly
4. **Test idempotency** — running the same playbook twice should produce zero changes on the second run
5. **Never modify Terraform-generated files** — `ansible/inventory/vms.yaml` is generated by `make inventory`
6. **Pre-commit hooks run automatically** — trailing-whitespace and end-of-file-fixer modify staged files; re-stage after hook failures

## Documentation Discipline

### README
- Update `README.md` any time you change: make targets, prerequisites, first-time setup
  steps, supported VMs, or the overall architecture
- Do NOT update README for internal refactors that don't affect how a user operates the repo
- If you're unsure whether a change warrants a README update, err on the side of updating it

### CLAUDE.md
- Update `CLAUDE.md` any time you establish a new convention, discover a new gotcha, or
  resolve one of the Known Inconsistencies
- When a Known Inconsistency is resolved, move it to a `## Resolved` subsection with a
  note on what changed — don't silently delete it
- Add to What Never To Do any time you encounter a mistake that wasted meaningful time

## Git Discipline

### When to commit
- After each logical unit of work is complete and verified — not mid-task
- After any change that touches more than one file
- Before running destructive operations (`make rebuild`, `make clean`, terraform destroy)
- After updating CLAUDE.md or README.md
- Never commit in the middle of a multi-phase task — complete the phase first

### Commit message format
- Use imperative present tense: "Add homepage Infisical agent templates" not "Added..."
- First line: 50 chars max, no period
- If the change warrants explanation, add a blank line then a body
- Reference the affected role/component: "ansible/roles/homepage: add agent env_file support"

### What never to commit
- Any file matching `*.sops.yml` that hasn't been encrypted with `sops --encrypt` first
- `vlans.yaml`, `private_bindings.yaml`, `infisical-backup.yml` (gitignored — if git
  somehow picks them up, stop immediately)
- Generated files: `ansible/inventory/vms.yaml`
- Anything with a raw secret value — pre-commit hooks should catch this but don't rely on them

### Before committing
- Run `make setup-hooks` if hooks aren't installed
- Pre-commit hooks will auto-fix whitespace/EOF — re-stage modified files after hook runs
- If gitleaks fires, do NOT use `--no-verify` to bypass — fix the leak first


## What Never To Do

- **Never hardcode IPs in templates** — derive from `ansible_host`, VLAN prefix replacement, or `hostvars`
- **Never put secrets in `vars.auto.tfvars`** — pre-commit hook blocks this
- **Never set `vlan_id` on SDN VNETs** — only for physical bridges (`vmbr*`)
- **Never use `regex_replace` for literal string substitution** — use `replace()` instead
- **Never use `echo -n`** in secret generation commands — use `printf '%s'`
- **Never use `is succeeded` alone** to gate on a registered variable — add `is not skipped`
- **Never use `--start-at-task` with `services.yml --limit plex-services`** — breaks role dependencies
- **Never use `git add -i` or `git rebase -i`** — interactive mode not supported
- **Never commit `vlans.yaml`, `private_bindings.yaml`, or `infisical-backup.yml`** — these are gitignored
- **Never add migration/upgrade logic** — roles must work on fresh VMs
- **Never skip pre-commit hooks** with `--no-verify`
- **Never reference `bootstrap.*` secrets in templates** outside the bootstrap/infisical roles
- **Never use `define`/`$(eval export)` in the Makefile for secret propagation** — use top-level `export`
- **Never bake secrets into docker-compose templates** via `{{ secrets.xxx }}` — use Infisical agent `env_file` exclusively
- **Never write to Infisical root `/`** — all secrets live in named subfolders. Root must remain empty.
- **Never reference `secrets.sops.yml` in operational context** — it is a DR artifact only, produced by `make infisical-backup`
- **Never write copies of secrets to consumer folders** — consumers read from the source folder via multi-folder agent templates. Secrets belong to the VM/role that generates them.

## Known Inconsistencies (Standardization Candidates)

1. ~~Compose file base paths~~ — moved to Resolved #6.

2. ~~NFS mount options~~ — moved to Resolved #7.

3. ~~`timezone` duplication~~ — moved to Resolved #5.

4. ~~AdGuard DNS rewrites hardcode VM names~~ — moved to Resolved #8.

5. ~~PBS storage backend~~ — moved to Resolved #9.

6. **Two Ansible-rendered .env files still bake secrets directly.** `docker/templates/docker-env.j2` references `{{ secrets.docker.cloudflared_tunnel_token }}` and `monitoring/templates/openobserve.env.j2` references `{{ openobserve_root_user_pass }}` (set via variable alias from `secrets.monitoring.*`). These are deliberate fallbacks, not oversights — the Infisical agent renders a second env_file that overrides these values at runtime. The "no baked secrets" rule in Secrets Handling applies to docker-compose templates only; these are separate .env config files.

### Resolved

1. **Secret delivery is now unified.** All containers use Infisical agent `env_file` paths — no more `{{ secrets.xxx }}` baked into docker-compose templates. (Resolved by secrets refactor Phases 4-6.)

2. **`docker-config.yml` no longer flattens nested secrets.** Compose templates use `env_file:` instead of `{{ secrets.xxx }}`, so the `combine()` flatten pre_tasks have been removed. A monitoring variable alias block remains in docker-config.yml (setting bare variables like `openobserve_root_user_pass` from `secrets.monitoring.*`) because `openobserve.env.j2` references those bare names — see Known Inconsistency #6. (Resolved by secrets refactor Phase 5; dead flatten blocks removed in architecture cleanup Phase A.)

3. **Homepage role scope reduced.** API key extraction and Infisical secret seeding moved to plex-services role. Homepage now focuses on template deployment, Caddy, and Portainer. (Resolved by secrets refactor Phase 2.)

4. **Monitoring role secret delivery unified.** Both OpenObserve and Grafana/exporters now use per-container Infisical agent env_files exclusively. (Resolved by secrets refactor Phases 5-6.)

5. **`timezone` centralized in `group_vars/all.yml`.** Removed duplicate definitions from `docker`, `plex_services`, `homepage`, `monitoring` role defaults and `host_vars/plex-services.yml`. All roles reference the single `{{ timezone }}` variable. (Resolved in architecture cleanup Phase B.)

6. **Compose file base paths unified.** All services now use `/opt/<service>/docker-compose.yml` — the docker legacy VM moved from flat `/opt/docker-compose.yml` to `/opt/docker/docker-compose.yml`. Each role defines a `*_base_dir` default variable. A shared `tasks/deploy_compose.yml` task provides a reusable deploy+restart pattern. Requires `make rebuild docker` for existing docker VMs. (Resolved in architecture cleanup Phase E+F.)

7. **NFS mount options unified.** All roles now use the centralized `{{ nfs_mount_options }}` variable from `group_vars/all.yml`. Docker VM volumes replaced hardcoded `nfsvers=4,...,timeo=600` with `{{ nfs_mount_options }}` (gains NFSv4.1, noatime, nconnect=4). Plex and PBS system-level mounts replaced `opts: "defaults"` with `{{ nfs_mount_options }}`. The plex_services volume auto-recreate logic remains unique to that role. The `*_nfs_src: "host:/path"` variable pattern and `.split(':')` calls were audited but intentionally left as-is — the source variables are centralized in `all.yml`, the split pattern works consistently (docker pre-splits in task vars, plex-services splits inline in template), and replacing it with separate `nfs_server` + `*_nfs_path` variables would double the NFS variable count for no functional gain. (Resolved in architecture cleanup Phase I.)

8. **AdGuard DNS rewrites parameterized.** Hardcoded VM names replaced with three configurable variables in `adguard/defaults/main.yml`: `adguard_rewrite_vms` (list of inventory hostnames), `adguard_service_aliases` (domain→target mappings), `adguard_cross_vlan_rewrites` (hostname+zone+prefix translation). Adding a new VM only requires appending to the list — no template changes. Also fixed latent bug where `hostvars['proxmox_backup']` (underscores) silently skipped the PBS rewrite because the inventory hostname is `proxmox-backup` (hyphens). (Resolved in architecture cleanup Phase J.)

9. **PBS storage backend cleaned up.** Both iSCSI and NFS backends were already functional via `pbs_storage_backend` conditional — the issue was cosmetic. Removed misleading "legacy" label from NFS config comment, replaced hardcoded `/mnt/backups` paths with `{{ pbs_nfs_mount_path }}`, changed mount source from `{{ proxmox_backup_nfs_src }}` to `{{ pbs_nfs_source }}` (the role's own default), and made datastore comment backend-agnostic. (Resolved in architecture cleanup Phase K.)
