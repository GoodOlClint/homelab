# Claude Code Guidelines — Homelab Ansible/Terraform Repo

## Repo Overview

This repo automates a Proxmox-based homelab with Terraform (VM provisioning, SDN, Vultr VPS, Cloudflare DNS) and Ansible (software configuration, Docker stacks, monitoring, secrets management). Key VMs: AdGuard (DNS filtering), BIND9 (authoritative DNS), Infisical (secrets vault), OpenObserve (monitoring stack), Proxmox Backup Server, UniFi, Plex, plex-services (arr stack), Docker (legacy services), Homepage, Lancache, NVIDIA licensing. A Vultr VPS acts as a WireGuard relay for external access.

**Architectural decisions** live in `docs/decisions/` (ADRs) — read them before proposing architecture changes. In flight: the MS-01 3-node cluster migration ([plan](docs/ms01-cluster-iac-plan.md), ADRs 0001–0009 + 0014) — 3-node PVE 9 + Ceph, Terraform-managed hosts, static-IP LXCs, greenfield rebuild. Ceph cluster network is switched 25G on the Pro-Aggregation's SFP28 ports, VLAN 33 (ADR 0014 — the FRR mesh is superseded).

**Alerting** runs in two lanes with one shared ntfy channel ([ADR 0011](docs/decisions/0011-two-alerting-lanes-uptime-kuma-for-reachability-alertmanager-for-metrics.md)): Uptime Kuma owns internal reachability (hand-managed UI config, reproducible via `scripts/seed_uptime_kuma.py`, inventory in [docs/uptime-kuma-monitors.md](docs/uptime-kuma-monitors.md)); Prometheus + Alertmanager own everything metric-shaped. UptimeRobot stays the external outside-in prober. The ntfy topic is the credential and lives at Infisical `/monitoring/alert_ntfy_topic`.

**DNS** is split-horizon behind AdGuard and must never see a public resolver ahead of it ([ADR 0012](docs/decisions/0012-internal-dns-must-not-be-poisoned-by-public-resolvers-adguard-first-base-durable-networkd-drop-ins.md)): `vlans.yaml` `dns_servers` is AdGuard-first (1.1.1.1 only as greenfield-bootstrap failover), and the `dns_config` role deploys durable systemd-networkd drop-ins (empty `DNS=` reset) — not resolvectl (reboot-transient) and not netplan overrides (netplan merges nameserver lists and cannot remove entries). Rollout vehicle: `ansible/playbooks/update-dns.yml`.

**IPv6** is per-VLAN on both address families — GUA `track6` with prefix ID = VLAN ID, ULA derived in Terraform for stable internal service addressing ([ADR 0010](docs/decisions/0010-per-vlan-ipv6-addressing-gua-tracks-the-vlan-id-ula-carries-stable-internal-services.md)). The pfSense half is hand-managed per ADR 0005 and documented in [docs/ipv6.md](docs/ipv6.md). Management, infrastructure and openclaw VLANs are deliberately IPv4-only — do not "fix" them. A static `ipv6_offset` must never imply `accept_ra: false`; RA is the only source of the default route.

**VPS relay tunnel** peers over the reserved IPv4 (rebuild-stable) and its MTU is measured, not computed ([ADR 0013](docs/decisions/0013-vps-tunnel-peers-over-reserved-ipv4-mtu-is-measured-per-address-family.md)): `wg_mtu` is 1400 with the IPv4 endpoint (60-byte encapsulation; path measured clean to a 1500-byte outer). If the endpoint ever returns to IPv6 the number is 1360, not 1400 — v6 encapsulation costs 80 bytes and the v6 path silently drops WG UDP above a 1456-byte outer. pfSense `tun_wg1` must match in BOTH the tunnel config and the interface override, and the peer public key must match the Infisical `/vps` pair (see [docs/pfsense-wireguard-vps-peer.md](docs/pfsense-wireguard-vps-peer.md)).

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
  `/shared`, `/monitoring`, `/plex`, `/plex-services`, `/homepage`, `/docker`, `/minio`, `/vps`, `/pfsense`, `/pbs`, `/infrastructure`, `/github-runner`
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
| `/monitoring` | monitoring, monitoring_users, proxmox_backup | openobserve, homepage | grafana_admin_password, openobserve_root_user_pass, unifi_monitoring_password, pbs_api_token, proxmox_token_value | uptimerobot_heartbeat_url, alert_ntfy_topic |
| `/plex` | plex, plex_certificate | plex, homepage | plex_token, plex_smb_pass, plex_cert_pfx_password | cloudflare_dns_api_token |
| `/plex-services` | plex_services | plex-services, homepage | postgres_password, *_db_password (×6), arr_admin_password, *_api_key (×8) | cloudflared_tunnel_token, usenet_*, nzb*_api_key, opensubtitlescom_* |
| `/docker` | docker, authentik | docker | valheim_server_password, valheim_supervisor_password, authentik_secret_key, authentik_postgres_password | cloudflared_tunnel_token, valheim_discord_webhook |
| `/vps` | vps_wireguard | — (no agent) | vps_wg_private_key | maxmind_license_key |
| `/pfsense` | — (manual ref) | — (no agent) | — | cloudflare_dns_api_token, bind_tsig_key_secret |
| `/pbs` | proxmox_backup | — (no agent) | pbs_admin_password, pbs_backup_user_password | — |
| `/infrastructure` | bind9 | — (no agent) | bind_tsig_key_secret | unifi_admin_password, synology_admin_password |
| `/homepage` | — (user-provided only) | homepage | — | adguard_*, unifi_*, authentik_token, portainer_api_key |
| `/minio` | minio | minio | minio_root_password | — |
| `/github-runner` | github_runner | — (no agent) | — | github_app_id, github_app_private_key, github_app_installation_id |
| `/squid` | squid | — (no agent) | squid_ca_private_key, squid_ca_cert_pem | — |

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

**services.yml tags:** `nvidia-licensing`, `docker`, `plex`, `plex-services`, `minio`, `homepage`, `github-runner`, `squid`, `mcp`, `lancache`

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
- Single fleet project at `terraform/` with `main.tf`, `vm-configs.tf`, `variables.tf`, `outputs.tf`, `provider.tf`
- **`terraform/hosts/`** is a SEPARATE root (own local state) for the host/cluster plane — host networking (bpg `network_linux_bond/bridge/vlan`), and later cluster options / Ceph pool / SDN / ACME (ADR-0002, WP1). Two-stage apply ordering: `hosts/` (rare) before `terraform/` (routine). Answer-file install → `make node-iso` (bake) → `make node-bootstrap` (token) → `make hosts-apply ENDPOINT=…` → `make proxmox-hosts` (WP2 Ansible cluster plane: mgmt re-home, corosync rings, Ceph with the ADR-0009 public/cluster split, keepalived VIP — needs `inventory/proxmox.yaml` + the WP2 fields in `host-bindings.yaml`). It manages the X710/82599ES bond→`vmbr0`→VLAN 20/40 and never touches the VLAN 30 install link, the ConnectX 25G port (switched Ceph VLAN 33 — [ADR 0014](docs/decisions/0014-ceph-cluster-network-rides-switched-25g-sfp28-ports-not-a-switchless-mesh.md)), or ring1. Baked `answer-*.toml` + `nodes.auto.tfvars` + `network-data/local/host-bindings.yaml` are gitignored (carry MAC/IP/root-hash); templates + `*.example` are tracked. See `terraform/hosts/README.md`.
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
| `make vps-deploy` | 3-phase: terraform (SSH open) → ansible → terraform (SSH closed). Initial provisioning only — phase 2 needs root SSH, which hardening removes |
| `make vps-ansible` | Day-2 VPS deploy over the tunnel (survives the wg restart via async handler) |
| `make vps-close-ssh` | Close the Vultr provisioning SSH rule after a failed vps-deploy |
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
- **Never reconfigure host networking over the interface carrying the PVE API session** — `terraform/hosts/` applies run over the stable VLAN 30 mgmt link and never touch it; a re-apply must never drop the link Terraform is talking over (ADR-0002)
- **Never DHCP an LXC** — static IPs only, so plan-time inventory is deterministic (ADR-0003)
- **Never put secrets in `vars.auto.tfvars`** — pre-commit hook blocks this
- **Never set `vlan_id` on SDN VNETs** — only for physical bridges (`vmbr*`)
- **Never use `regex_replace` for literal string substitution** — use `replace()` instead
- **Never write a source-based `routing-policy` rule with the interface prefix** — it must be `/32`. A `from: <ip>/24` rule matches every host in the subnet, not just this one, so any *forwarded* packet (a reply to a Docker container) from a neighbour on that VLAN is looked up in the per-VLAN table, which has no bridge route, and is sent back out the gateway. Symptom: containers reach the internet fine but hang on every connection to a host on that interface's own subnet
- **The AdGuard config template is `when: not _adguard_config.stat.exists` — "initial only"** — AdGuardHome rewrites its own YAML at runtime, so editing `adguardhome.yaml.j2` affects fresh VMs only. Changing a setting on a running host means editing the live config (stop service → edit → start) or using the AdGuard API; a redeploy silently no-ops. When editing the live config, DNS rewrites live under `filtering.rewrites` (schema ≥ 23) — keys AdGuardHome doesn't recognize (e.g. a hand-added `dns.rewrites`) are silently discarded on the next config write, so verify the edit survived a service restart. The AdGuard web-UI admin password exists only as a bcrypt hash in that config — it was never seeded into Infisical `/homepage`, so the API route needs the operator to supply it
- **Never write a bare `$` in a docker-compose `environment:` value that must expand inside the container** — compose interpolates `${...}` at parse time on the Ansible host and silently substitutes empty. Escape as `$$` (see the Valheim `ON_VALHEIM_LOG_FILTER_CONTAINS_*` hook in `docker/templates/docker-compose.yml.j2`)
- **Never point a container running as a non-root user at a bare `/etc/infisical/secrets/<file>` via a `*_file` directive without declaring `mode:` on the agent template** — the Infisical agent writes `0600 root` and has no permission option, so `prom/*` images (which run as `nobody`) get `permission denied`. Prometheus reports this at WARN and retries forever, so `remote_write` died silently for months. Declare `mode: '0644'` in `infisical_agent_templates` and re-apply it in the template's `post_command`, since a rotation rewrites the file
- **Never put a literal comment line in an Infisical agent template that renders a *bare value*** — the comment becomes part of the value. Use `{{- /* ... */ -}}` Go-template comments with whitespace trimming (see `openobserve-password.tpl.j2` and `alert-ntfy-url.tpl.j2`)
- **Never leave syslog-ng's default `max-connections(10)` on a fleet-wide syslog source** — each Docker daemon holds one TCP connection per logging container, so the fleet blows past 10 and every new sender is rejected with ingestion silently stalling
- **Never probe the UniFi controller with credentials from a monitor** — its `/status` gate now passes on port 11443, so authenticating risks locking the admin account. TCP port check only, and do not run the `monitoring_users` role
- **Never use `iif`/`oif` in nftables rules for interfaces created after boot (wg0)** — they resolve interface indexes at ruleset load, so the whole ruleset fails to load when the interface doesn't exist yet, leaving the box unfiltered. Use `iifname`/`oifname`. Cost a full VPS lockout on 2026-07-27
- **Never synchronously restart WireGuard over the tunnel it carries** — the service task dies between `down` and `up` when its own SSH session severs, and the box is unreachable (VPS sshd binds tunnel IPs only). The `vps_wireguard` restart handler is `async: 60 / poll: 0` fire-and-forget; keep it that way. Recovery required a full `make vps-rebuild`
- **Never trust computed tunnel MTU arithmetic — measure with DF-set probes** (procedure in docs/pfsense-wireguard-vps-peer.md). The IPv6 relay path drops WG UDP outers ≥ 1458 even though raw ICMPv6 passes at 1462; the IPv4 path carries full 1500 outers. An IPv6 tunnel endpoint costs 80 bytes of encapsulation, not IPv4's 60 (ADR 0013)
- **Never peer WireGuard against the VPS instance IPv6, and never set narrow AllowedIPs** — the SLAAC address dies on every rebuild (new MAC), and AllowedIPs narrower than the internal supernets makes cryptokey routing silently drop LAN-sourced SSH/pings while breaking VPS-originated telegraf/rsyslog (ADR 0013)
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
