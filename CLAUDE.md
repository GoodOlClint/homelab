# Claude Code Guidelines — Homelab Ansible/Terraform Repo

## Repo Overview

This repo automates a Proxmox-based homelab with Terraform (VM provisioning, SDN, Vultr VPS, Cloudflare DNS) and Ansible (software configuration, Docker stacks, monitoring, secrets management). Key VMs: AdGuard (DNS filtering), BIND9 (authoritative DNS), Infisical (secrets vault), OpenObserve (monitoring stack), Proxmox Backup Server, UniFi, Plex, plex-services (arr stack), Docker (legacy services), Homepage, NVIDIA licensing. A Vultr VPS acts as a WireGuard relay for external access.

**Architectural decisions** live in `docs/decisions/` (ADRs) — read them before proposing architecture changes. In flight: the MS-01 3-node cluster migration ([plan](docs/ms01-cluster-iac-plan.md), ADRs 0001–0009 + 0014) — 3-node PVE 9 + Ceph, Terraform-managed hosts, static-IP LXCs, greenfield rebuild. Cluster create/join is API-module orchestrated, strictly serial with membership gates ([ADR 0023](docs/decisions/0023-proxmox-cluster-create-and-join-use-the-community-proxmox-api-module-not-pvecm-over-ssh.md)); cutover runs a restore-bridge — old fleet restored from PBS onto the 2-node cluster so pve is wiped/rejoined early, greenfield replacement follows at leisure ([ADR 0024](docs/decisions/0024-cutover-rides-a-restore-bridge-restore-the-old-fleet-onto-the-2-node-pve-9-cluster-rebuild-pve-early.md); mixed 8/9 clustering rejected as unsupported). Post-bridge, guests are **greenfield-replaced one at a time** beside the restored copies — fleet state pruned of every `proxmox_*` resource, new VMID = old+100, restored copy stopped never destroyed, targeted `make build` only ([ADR 0028](docs/decisions/0028-greenfield-replace-builds-final-form-guests-beside-the-restored-copies-under-vmid-old-100-after-pruning-the-fleet-state-of-every-proxmox-resource.md), [runbook](docs/ms01-cluster-iac-plan.md#greenfield-replace-runbook-day-3-adr-0028)). Ceph cluster network is switched 25G on the Pro-Aggregation's SFP28 ports, VLAN 21 (ADR 0014, renumbered from 33 — the FRR mesh is superseded). Corosync VLANs 31/32 live on the shared 48-port access switch, not a dedicated one ([ADR 0019](docs/decisions/0019-corosync-moves-onto-the-shared-48-port-access-switch-trading-physical-isolation-for-consolidation.md), superseding [ADR 0008](docs/decisions/0008-corosync-on-a-dedicated-switch-local-vlan-vlan-30-stays-infrastructure.md)'s dedicated-switch model — VLAN isolation itself is unchanged, only the physical switch). **Physical re-plan (PROPOSED 2026-09-15, ADRs 0056–0058):** ms-01c joins; msi leaves Ceph but stays a cluster member and Ceph client as the GPU host (2× B70 in PCI_E1/E2, its existing ConnectX-4 Lx in PCI_E3 becomes a 2×25G bond (~31 Gb/s, Gen3 x4) into the Pro-Agg carrying all its VLANs, 82599ES out; amended 2026-09-25), drained only when ms-01c is healthy **and** ms-01a's core-8 fault is resolved — always 3 OSD hosts ([ADR 0056](docs/decisions/0056-msi-leaves-ceph-but-stays-a-non-ceph-cluster-member-as-the-gpu-host-and-its-drain-waits-for-three-healthy-osd-hosts.md)); VLAN 21 moves to a MikroTik CRS518 island (bought 2026-09-25; ADR 0057 originally named the CRS510), 2×25G LACP per OSD host, VLAN 21 never leaves it (management uplink only) ([ADR 0057](docs/decisions/0057-ceph-replication-moves-to-a-dedicated-mikrotik-switch-island-with-2x25g-lacp-per-node-and-vlan-21-never-leaves-it.md), amends 0014); ring1 moves to a USW-Flex-2.5G-8 with STP off, token 5000 ms, msi via an Intel I226-V M.2 card in M2_4, which gates the ring1 move for every member ([ADR 0058](docs/decisions/0058-corosync-ring1-moves-to-a-usw-flex-2-5g-8-with-spanning-tree-disabled.md), amends 0019). End-state rebuild model ([design](docs/rebuild-as-routine-design.md)): durable state on detached Ceph data volumes, guest rootfs disposable ([ADR 0015](docs/decisions/0015-durable-state-rides-detached-ceph-data-volumes-the-guest-rootfs-is-disposable.md); holder is a single never-started **VM** whose raw disks get a one-time format+chown before first consumer start — appendable in-place, never a CT, [ADR 0020](docs/decisions/0020-detached-data-volumes-ride-a-single-never-started-holder-vm-not-a-holder-ct.md)); guest OS images pinned + deliberately rolled ([ADR 0016](docs/decisions/0016-guest-os-images-are-pinned-and-deliberately-rolled-container-tags-stay-latest.md)); guests single-homed on the services VLAN with storage via host bind mounts, squid retired ([ADR 0017](docs/decisions/0017-guests-are-single-homed-on-the-services-vlan-storage-reaches-containers-via-host-bind-mounts.md)). The dual-homed vlan10/vlan40 conventions below (SSH via vlan10, prefix translation) describe the live fleet and are amended at cutover (WP7).

**Post-migration program (decided 2026-08-22):** three management planes — **vlan10 out-of-band** (KVM/AMT/UniFi/switches + a `control` VM with MeshCentral; laptop-only ingress), **vlan30 hypervisor** (nodes, VIP, PDM, PBS, apt-cache, pxe; named guest rules only), **vlan40 services** (Talos + the client-reachable guests); AMT ports go native-10 with the host mgmt tagged 30; this amends ADR 0017's zero-guests-on-VLAN-10 ([ADR 0030](docs/decisions/0030-three-management-planes-vlan10-out-of-band-vlan30-hypervisor-with-pdm-pbs-apt-cache-pxe-vlan40-services.md)). A **3-node Talos Kubernetes cluster is the services plane** (registry + ARC runners first, then the docker-LXC stacks one at a time); the bootstrap tier — DNS, Infisical, PBS, apt-cache, pxe, unifi, plex, LLM, PDM — stays on Proxmox forever; **no further greenfield-replaces for k8s-bound guests** (github-runner 113 → ARC, ADR 0034; mcp 115 was never built out and was retired 2026-08-24 without a k8s successor); control-plane VMs pinned one per node, no HA, third etcd member on worklab until the msi RMA ([ADR 0031](docs/decisions/0031-a-three-node-talos-kubernetes-cluster-becomes-the-services-plane-and-the-bootstrap-tier-stays-on-proxmox.md)). **CI** is ephemeral ARC pods that build their own guests inside PVE pool `ci` (scoped token, VMIDs 5000–5999, isolated `ci` VLAN, reaper; ISO/import uploads land on **`ci-isos`**, a quota-capped cephfs-subdir datastore from `proxmox_host` storage.yml — never the cephfs root, where CI's upstream-named cloud images would collide with and delete the fleet's pinned images; CI guest DNS lives in **`ci.<service domain>`**, a BIND child zone whose `ci-update-key` TSIG (`/infrastructure/ci_tsig_key_secret`, bind9 role) is granted `zonesub` in that zone only — REFUSED anywhere else, so CI never needs and must never hold the fleet's `dhcp-update-key`); the Mac Studio runner is a separate trust tier, decided 2026-11-19 to become a wiped M4 runner host with disposable VMs for pull-request jobs and bare metal for trusted-branch GPU jobs ([ADR 0061](docs/decisions/0061-the-m4-mac-studio-is-rebuilt-as-a-ci-runner-host-with-disposable-vms-for-pull-request-jobs-and-bare-metal-for-trusted-branch-gpu-jobs.md), amends 0032); ARC is decided 2026-11-19 (built first) to leave the services cluster for a dedicated two-node CI cluster, App key kept from job nodes ([ADR 0062](docs/decisions/0062-arc-moves-off-the-services-cluster-onto-a-dedicated-two-node-ci-cluster-with-the-github-app-key-kept-from-job-nodes.md), amends 0031/0032/0034/0048; built as a second Talos cluster by the same cluster-named tooling, [ADR 0063](docs/decisions/0063-the-ci-cluster-is-a-second-talos-cluster-built-by-the-same-tooling-which-takes-a-cluster-name-and-gains-a-worker-role.md), on a dedicated `ci-runner` VLAN, [ADR 0064](docs/decisions/0064-the-ci-cluster-nodes-sit-on-a-dedicated-ci-runner-vlan-filtered-at-pfsense.md); [plan](docs/ci-cluster-plan.md)) ([ADR 0032](docs/decisions/0032-ci-runners-are-ephemeral-and-build-their-own-guests-inside-a-pve-pool-on-an-isolated-vlan-and-the-mac-studio-is-a-separate-trust-tier.md)). Phased change plan: [plan doc](docs/ms01-cluster-iac-plan.md#post-migration-change-plan-decided-2026-08-22). **Portainer was retired from `control` 2026-09-13 ([ADR 0053](docs/decisions/0053-portainer-is-retired-from-the-control-lxc-meshcentral-stays.md), amends ADR 0030):** its four agent environments were VMs 203/204/206/211, all retired at P4a–P4d, so it managed nothing; the compose service, role tasks, OIDC provider, homepage tile and the three secrets are gone. Container management is the guest's own Ansible role on the bootstrap tier and Headlamp on the cluster.

**Talos services plane — P3a built 2026-08-23 ([ADR 0033](docs/decisions/0033-talos-p3a-rides-talosctl-from-a-kubernetes-tree-with-the-factory-image-pinned-in-cloud-images-the-worklab-member-via-a-second-bpg-provider-alias-flannel-and-cluster-secrets-in-infisical.md), [plan](docs/talos-p3a-plan.md)):** `talos-cp-a/b/c` (VMIDs 230/231/232, pinned to ms-01a / ms-01b / msi, **never an HA resource**) are plain resources in `terraform/talos.tf` — not the VM module. The temporary worklab member `talos-cp-w` (ADR 0031) retired 2026-09-08 when msi rejoined post-RMA; the `proxmox.worklab` provider alias (`bootstrap.worklab_password`) stays for future worklab-hosted resources. Each node has a services leg (kubelet/etcd/API, Talos L2 VIP at services offset 60) and a Ceph-public VLAN 20 leg for CSI only. Image = factory v1.13.10 nocloud qcow2 pinned in `cloud_images.talos`; running nodes roll with `talosctl upgrade`, not a rebuild — the VMs `ignore_changes` their disk `file_id`, so a pin bump replaces only the downloaded image (before 2026-09-29 it planned a replace of all three control planes). **The talos VMs are OOM-exempt** (2026-08-31: a PSProxmoxVE CI provision spike OOM-killed talos-cp-a's kvm after the 08-27 8→16 GB bump): a `hook_script_file_id` snippet in `talos.tf` (one copy per node on `local:snippets/` — never cephfs, which pvestatd mounts *after* pve-guests has already tried the autostart, 2026-09-09) writes `oom_score_adj -1000` at post-start, so host memory pressure kills the aggressor guest, never a services-plane node — the hookscript fires on the next VM start only, so a hand-started talos VM needs the echo once. See Canonical pipelines.

## Canonical pipelines

The per-subsystem pipeline notes load from `.claude/rules/<subsystem>.md` when a matching file is touched (`ansible`, `kubernetes`, `proxmox`, `dns-network`, `identity-pki`, `llm`). Repo-wide:

**Agent GitHub identity** is chosen per session by `scripts/github-agent-mcp` from the repo's `origin` (`homelab` is `plain`: the operator pushes, the Apps do PRs); see [docs/github-agent-identity.md](docs/github-agent-identity.md), ADR 0059. Never put an App id, installation id or key path in a CLI config.

**Key directories:**
- `terraform/` — Single consolidated Terraform project with `modules/proxmox-vm/` and `modules/network/`
- `ansible/roles/` — Single flat directory (~30 roles)
- `ansible/playbooks/` — All playbooks (site.yml imports infrastructure.yml + services.yml)
- `ansible/tasks/` — Shared task files (secrets loading, generation, pre_tasks)
- `ansible/group_vars/` — Global vars (`all.yml`), bootstrap secrets (`bootstrap.sops.yml`)
- `ansible/inventory/` — Terraform-generated `vms.yaml` + static `proxmox.yaml`, `pfsense.yaml`, `vps.yaml`
- `network-data/` — Canonical `vlans.yaml` (gitignored; `vlans.example.yaml` is the tracked schema)
- `scripts/` — Infisical migration/backup, security guardrails, validation

Landing dates, measurements and "found en route" notes for each pipeline: [docs/LESSONS.md](docs/LESSONS.md), same headings.

## Before You Start Any Task

1. **Read before writing.** Always read the files you intend to modify and their related files (defaults, templates, tasks) before making changes. Understand the existing patterns.
2. **Check the inventory.** VM names, IPs, and group membership are in `ansible/inventory/vms.yaml` (Terraform-generated). Do not hardcode IPs.
3. **Check `group_vars/all.yml`** for existing variables before adding new ones to role defaults — `all.yml` overrides role defaults and causes silent variable collisions.

## Greenfield Philosophy

- **No migration tasks.** Do not write version-check conditionals, one-time migration logic, or upgrade paths. Every role should work correctly on a fresh VM and be idempotent on re-run.
- **No version pinning without reason.** Use `latest` tags for Docker images unless there's a specific compatibility constraint. Guest **OS images** are the exception with a reason: pinned by version + checksum and deliberately rolled ([ADR 0016](docs/decisions/0016-guest-os-images-are-pinned-and-deliberately-rolled-container-tags-stay-latest.md)) — `latest` OS images made plan output unreadable and `make apply` a fleet-replacement foot-gun.
- **Idempotent everything.** Every task must be safe to run repeatedly. Use `creates:`, `when:`, registered variables, and `changed_when:` to prevent unnecessary changes.
- **REPLACE_ME sentinel.** Secrets that haven't been generated yet use the string `REPLACE_ME`. The `generate_secret.yml` task checks for this value to decide whether to generate.

## Secrets Handling

### Two-Tier Architecture
- **Tier 1 (Bootstrap):** `ansible/group_vars/bootstrap.sops.yml` — SOPS-encrypted. Contains only provider credentials (Proxmox, Vultr, Cloudflare), Infisical auth (client_id, client_secret, admin creds), and external secrets (user-provided API keys, passwords). Referenced as `bootstrap.key_name` or `bootstrap_config.key_name`.
- **Tier 2 (Runtime):** Infisical VM — stores ALL runtime secrets, organized into the folders listed in the Infisical Folder Ownership table below (one owner role per folder; no second list is kept here).
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
- Special case: Recyclarr uses `secrets.yml` with `!secret` YAML tags instead of env vars (on the cluster it is an item of the `plex-services-secrets` managed Secret, mounted at `/config/secrets.yml`).
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
- **Never commit unencrypted secrets** — SOPS files only. The `homelab-security-guardrails` pre-commit hook (`scripts/security_guardrails.sh --staged`) runs `gitleaks protect --staged` plus the private-address guard; `detect-private-key` and `no-tfvars-secrets` cover keys and tfvars.
- **Always use `{{ secrets.key_name }}`** — never reference bootstrap-tier secrets in templates (except the Infisical role itself which needs bootstrap creds before Infisical exists).
- **Resolve `secret_comment` to a fact** before passing to `infisical_write_secret.yml` to avoid recursive template loops. The `generate_secret.yml` task handles this automatically.
- **Use `printf '%s' value`** not `echo -n value` in generation commands — some shells output `-n` literally.
- **All secret key names must be lowercase with underscores** — no UPPERCASE keys in Infisical. Convention: `{component}_{secret_type}` (e.g., `pbs_admin_password`, `grafana_admin_password`).

## Infisical Folder Ownership

Each Infisical folder is owned by the role that generates/provisions its secrets. Consumers read from the source folder — no copies.

| Folder | Owner Role | Agent Readers | Auto-Generated | External (User-Provided) |
|--------|-----------|---------------|----------------|-------------------------|
| `/shared` | proxmox_backup | All VMs (via pbs_client) | pbs_backup_token (`pbs_fingerprint` retired by ADR 0041 — PBS is verified through the root) | — |
| `/monitoring` | monitoring_users, proxmox_backup | k8s `monitoring` + `homepage` (InfisicalSecret) | grafana_admin_password, openobserve_root_user_pass, unifi_monitoring_password, pbs_api_token, proxmox_token_value | uptimerobot_heartbeat_url, alert_ntfy_topic |
| `/plex` | plex, plex_certificate | plex, homepage | plex_token, plex_smb_pass, plex_cert_pfx_password | plex_tv_username, plex_tv_password (seeded from `external_secrets.plex`; read only when `plex_token` is absent) |
| `/plex-services` | — (values pre-exist; `kubernetes/plex-services/` consumes, no generator since P4c) | k8s `plex-services` + `homepage` (InfisicalSecret) | postgres_password, *_db_password (×6), arr_admin_password, *_api_key (×9), libation_master_key | cloudflared_tunnel_token, usenet_*, nzb*_api_key, opensubtitlescom_* |
| `/docker` | — (values pre-exist; `kubernetes/games/` consumes via `InfisicalSecret`, no generator since P4d) | k8s `games` (InfisicalSecret) | valheim_server_password, valheim_supervisor_password | valheim_discord_webhook (optional — absent today, the join-code hook stays inert until it exists) |
| `/authentik` | values pre-exist (generated by the cluster deploy before 2026-09-10); the `authentik` role READS them and never regenerates `secret_key`/`postgres_password` (ADR 0049) | the `authentik` LXC (Infisical agent, `authentik.env`), k8s `monitoring` (grafana_oidc_client_secret only); the `control` role reads `secrets.authentik.*` at deploy time for MeshCentral | secret_key, postgres_password, bootstrap_password, bootstrap_token, grafana/meshcentral/pdm/pve/pbs/synology/homeassistant `_oidc_client_secret` (zot's removed 2026-09-10, ADR 0049; portainer's 2026-09-13, ADR 0053) | — |
| `/authentik-ext` | `k8s_apps` role (`make k8s-apps`, `generate_secret.yml`; the external realm) | k8s `authentik-ext` (InfisicalSecret), k8s `jellyfin` (InfisicalSecret, ldap_bind_password → the LDAP plugin config) | secret_key, postgres_password, bootstrap_password, bootstrap_token, ldap_bind_password | — |
| `/codeintel` | `k8s_apps` role (`make k8s-apps`, `generate_secret.yml`; ADR 0055) | k8s `codeintel` (InfisicalSecret, postgres_password); the `scratch` role delivers writer_password to `code-intel` 280; the mcp host's reader_password rides its own delivery (#47) | postgres_password, writer_password, reader_password | — |
| `/jellyfin` | `k8s_apps` role (`make k8s-apps`, `generate_secret.yml`) | k8s `jellyfin` (InfisicalSecret; the role reads the managed Secret to drive the API) | admin_password | — |
| `/vps` | vps_wireguard | — (no agent) | vps_wg_private_key | maxmind_license_key |
| `/pfsense` | — (manual ref) | — (no agent) | — | cloudflare_dns_api_token, bind_tsig_key_secret |
| `/pbs` | proxmox_backup | — (no agent) | pbs_admin_password (`pbs_backup_user_password` retired 2026-09-10, #17 — PBS users hold no password, only tokens) | — |
| `/infrastructure` | bind9, `scripts/pki_hosts.sh` (`acme_*`) | k8s `external-dns` (InfisicalSecret, TSIG), k8s `cert-manager` (InfisicalSecret, Cloudflare token); `proxmox_host`, `proxmox_backup`, `pdm`, `cert_client`, `api_certificate.yml` read `acme_*` at deploy time (each host only its own `acme_tsig_<host>`) | bind_tsig_key_secret, ci_tsig_key_secret, acme_tsig_<host> (one per `bind9_acme_hosts` entry, ADR 0050), acme_directory_url, acme_profile_id, acme_application_id | unifi_admin_password, synology_admin_password, cloudflare_dns_api_token (DNS:edit on both public zones; also read by `plex_certificate` at deploy time) |
| `/homepage` | adguard (adguard_*) | k8s `homepage` (InfisicalSecret) | adguard_* | unifi_* |
| `/control` | pdm | — (no agent) | pdm_root_password | — |
| `/github-runner` | `k8s_seed` role (`make k8s-seed` writes the `arc-runners/github-app` Secret; no generator) | — (no agent) | — | github_app_id, github_app_private_key, github_app_installation_id |
| `/github/mcp` | — (operator hand step, [docs/github-agent-identity.md](docs/github-agent-identity.md)) | — (no agent; the PEMs are pulled onto the operator workstation with the CLI from the repo root) | — | claude_app_id, claude_app_installation_id, claude_mcp_app_private_key, codex_app_id, codex_app_installation_id, codex_mcp_app_private_key (the agent GitHub Apps) |
| `/mcp` | `mcp` role (`mcp/tasks/accounts.yml` from the play's pre_tasks, `generate_secret.yml`; ADR 0052) | the `mcp` VM (Infisical agent: `mcp.env`, `mcp-tokens.json`, `mcp-users.json`, which also read `/plex` plex_token, `/llm` llm_api_key_mcp and `/codeintel` reader_password) | gateway_token_<agent>, gateway_user_token_<user>, github_deploy_key, openobserve_password, proxmox_token (minted by `pveum`) | — |
| `/llm` | `llm` role (`generate_secret.yml`, one `llm_api_key_<client>` per entry in `llm_api_clients`) | the `llm` VM (Infisical agent, `llm.env` → Caddy `EnvironmentFile`) | llm_api_key_agents, llm_api_key_operator, llm_api_key_code_intel (delivered to the `code-intel` scratch guest by the `scratch` role), llm_api_key_mcp (the mcp VM's code-intel embeddings) | — |
| `/scratch/<guest>` | — (operator seeds; ADR 0054) | — (no agent; the `scratch` role reads it at deploy time) | — | whatever the guest's `scratch_guests` spec lists (code-intel: openrouter_api_key) |
| `/talos` | `kubernetes/talos/talos.sh` (`make talos-secrets`, no Ansible role) | — (no agent) | talos_secrets_yaml, talosconfig (base64) | — |

**Key rules:**
- The `ansible-admin` identity's universal auth trusts `0.0.0.0/0` with a non-expiring client secret — deliberately, not by omission: Infisical's IP allowlist is a paid-plan feature and the self-hosted free instance answers any other value with a 400 (#21, 2026-09-10). The compensating control is the vault's reach: the services VLAN and pfSense's rules, not the identity.
- "Owner Role" is the Ansible role whose tasks write secrets to this folder via `generate_secret.yml` or `infisical_write_secret.yml`.
- "Agent Readers" are VMs whose Infisical Agent templates include `with secret` blocks reading from this folder, or cluster namespaces with an `InfisicalSecret` on it (ADR 0035).
- VMs without agents (vps, pfsense, pbs, infrastructure) consume secrets at Ansible deploy time via the `secrets` fact — not via agent.
- `/homepage` has no owner role that generates secrets — it contains only user-provided external credentials seeded from `bootstrap.sops.yml`.
- **A new folder must also be added to the nested-path loop in `ansible/tasks/infisical_login.yml`** — the `secrets` fact only loads the folders listed there, so an unlisted folder's secrets look absent to `generate_secret.yml` and get REGENERATED on every run (Portainer admin password rotated out from under the live instance, 2026-08-22). The loop is consumer-driven: `docker`, `plex-services`, `pfsense` and `talos` are cluster/hand-owned and were dropped from it 2026-09-10 (#27) — `jellyfin` stays because `k8s_apps` generates into it. Before dropping a folder, `git grep secret_dict_path` as well as `secrets.<folder>`.
- When adding a new secret, find the correct owner folder first. If no existing folder fits, consider whether the secret truly needs a new folder or should be added to an existing one.

## Ansible Conventions

### Playbook Structure
- Playbooks import `full_pre_tasks.yml` which loads: local overrides → bootstrap SOPS → secrets (Infisical, hard fail if unreachable) → VLAN definitions → VLAN prefix computation → dns_zones. **Infisical is read once per run (#27, 2026-09-10):** the first play through the loader logs in, reads the folders and publishes `secrets` + `infisical_login` to localhost (`load_secrets.yml`); every later play copies them from `hostvars['localhost']` — `infrastructure.yml`'s pre-flight play is tagged `always` so a `--tags` run loads there, and a `--limit <vm>` run (which excludes localhost) loads in the limited play. `generate_secret.yml` republishes the fact after a write so a later play sees the new key. The admin-API token is the same session: `tasks/infisical_admin_token.yml` sets `_admin_token` from it and only logs in from a play with no loader (#28). Facts are cached an hour under `.ansible-facts/` (`gathering = smart`; `make clean-ssh`, and so every `make inventory`/`build`/`rebuild`, drops the cache — a rebuilt guest must never read hour-old `ansible_distribution`).
- Playbooks are role-based — inline tasks only in bootstrap (`docker-config.yml` was deleted 2026-09-10, #25: its last caller was infisical, and `make ansible infisical` is idempotent and covers it).
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

**infrastructure.yml tags:** `phase1`, `phase2`, `phase3`, `timezone`, `ca-trust`, `bindings`, `dns`, `bind9`, `adguard`, `infisical`, `proxmox-backup`, `unifi`, `apt-cache`, `pxe`, `control`, `pdm`, `authentik`, `telegraf`, `monitoring`, `monitoring-users`, `users` (the play-level `tags:` in `ansible/playbooks/infrastructure.yml` are the source of truth)

**services.yml tags:** `plex`, `llm`, `mcp`, `scratch`, `telegraf` (homepage, plex-services and the games host are Flux trees `homepage`, `plex-services`, `games`, not plays)

**How tags work with pre_tasks:**
- All `pre_tasks` blocks have `tags: [always]`, so secrets/VLANs/facts always load regardless of `--tags` filter.
- The `infisical_client` role's "Enable and start infisical-agent" task is tagged `always` — even when filtering by tags within a play, the agent is guaranteed to be running.
- Tags filter at the **play** level: `--tags docker` runs only the docker play (and its pre_tasks).

**Usage via Makefile:** Pass `TAGS=` to any ansible target:
```bash
make ansible plex TAGS=plex              # only the plex play
make ansible-infra TAGS=phase1           # infrastructure phase 1 only
make ansible-services TAGS=plex,llm      # plex + llm plays
```

### Variable Sourcing Priority
1. `ansible/group_vars/local/all.yml` — local overrides (gitignored)
2. `ansible/group_vars/all.yml` — global vars (overrides role defaults!)
3. `ansible/roles/<role>/defaults/main.yml` — role defaults

## Docker Conventions

- **Compose file location:** `/opt/<service>/docker-compose.yml` on the VM (e.g., `/opt/infisical/`, `/opt/control/`). Each role defines a `*_base_dir` default variable for its path.
- **Restart policy:** `restart: unless-stopped` for all containers
- **Logging:** Docker daemon configured for syslog to OpenObserve (`configure_docker_logging.yml`)
- **NFS on the remaining compose hosts (authentik, control, infisical):** none. Storage reaches containers through host bind mounts (ADR 0017); the cluster's media trees are kubelet-mounted NFS PVs (ADR 0037).
- **NFS tuning:** `nfsvers=4.1,hard,intr,noatime,rsize=1048576,wsize=1048576,nconnect=4` (Synology negotiates down to 128KB rsize/wsize)
- **Restart on change:** Register template results, restart containers only `when: <registered_var> is changed`
- **env_file for Infisical agent secrets:** Path is `/etc/infisical/secrets/<name>.env`, rendered by the Infisical agent from Go templates in `infisical_client/templates/secrets/`

## Terraform Conventions

### Structure
- Single fleet project at `terraform/` with `main.tf`, `vm-configs.tf`, `variables.tf`, `outputs.tf`, `provider.tf`
- **`terraform/hosts/`** is a SEPARATE root (own local state) for the host/cluster plane — host networking (bpg `network_linux_bond/bridge/vlan`), and later cluster options / Ceph pool / SDN / ACME (ADR-0002, WP1). Two-stage apply ordering: `hosts/` (rare) before `terraform/` (routine). Answer-file install → `make node-iso` (bake) → `make node-bootstrap` (token) → `make hosts-apply ENDPOINT=…` → `make proxmox-hosts` (WP2 Ansible cluster plane: mgmt re-home, corosync rings, Ceph with the ADR-0009 public/cluster split, keepalived VIP — needs `inventory/proxmox.yaml` + the WP2 fields in `host-bindings.yaml`). It manages the X710/82599ES bond→`vmbr0`→VLAN 20/40 and never touches the VLAN 30 install link, the ConnectX 25G port (switched Ceph VLAN 21 — [ADR 0014](docs/decisions/0014-ceph-cluster-network-rides-switched-25g-sfp28-ports-not-a-switchless-mesh.md)), or ring1. Baked `answer-*.toml` + `nodes.auto.tfvars` + `network-data/local/host-bindings.yaml` are gitignored (carry MAC/IP/root-hash); templates + `*.example` are tracked. See `terraform/hosts/README.md`.
- `vm-configs.tf` defines all VMs in `local.infrastructure_vms` and `local.services_vms`
- **Storage entries vs backup jobs (boundary amended 2026-08-11, B3):** PVE *storage entries* are cluster-plane and Ansible-owned — bpg has no storage-definition resource, so Ceph storage defs come from the WP2 `proxmox_host` role and the PBS entry from `make backup-finalize` (once per cluster, after PBS provisioning). PVE *backup jobs* (`backup_jobs` var → `backup-jobs.tf`) live in the fleet root because they select fleet VMIDs and change with fleet composition; `backup-finalize` is their one-time prerequisite. Putting jobs in `terraform/hosts/` would couple the rare-apply host root to every fleet change.
- `vars.auto.tfvars` for non-sensitive config only

### Secrets Flow
- Makefile reads `bootstrap.sops.yml` via `sops -d --extract` and exports as `TF_VAR_*` env vars
- The five `TF_VAR_*` secrets are target-specific exports on `TF_TARGETS` (the terraform-reaching targets), recursively expanded through the memoized `_secret` helper — a plain `export X := …` at top level decrypts for every target (`make clean-ssh` used to hand the PVE root password to kubectl), and a target-specific `:=` expands once per listed target at parse time (150 sops calls). A new terraform-invoking target must be added to `TF_TARGETS` or its variables prompt (#12, 2026-09-10)
- `terraform refresh` updates state but NOT outputs — use `terraform apply -refresh-only -auto-approve`
- Targeted applies (`-target`) don't recompute `ansible_inventory_yaml` either — a brand-new guest never lands in `vms.yaml` from the targeted apply alone; `make build` runs a refresh-only apply before `inventory` for exactly this reason (found building apt-cache, 2026-08-11)

### VM Configuration Patterns
- Each VM: `name`, `vm_id`, `vlans` (list), `ip_offset`, `cores`, `memory`, `disk_size`; `node_name` pins placement; `pci_devices = [{ id = "<BDF>" }]` passes a host PCI device through (VM only, q35 — a bare `0000:01:00` takes every function)
- `protected = true` for critical VMs (currently: infisical). Override with `var.unprotect`
- `lifecycle.ignore_changes` on cloud-init file IDs to prevent VM recreation on template changes
- Management VLAN is always first interface; `vm_id` → static IP, no `vm_id` → DHCP
- MAC addresses: `52:54:00:{random}:{vlan_id/256}:{vlan_id%256}`
- Use `coalesce()` carefully — not short-circuit. Use `try()` for fallbacks referencing resources that may not exist during `-target` operations

### Inventory Generation
- `make inventory` runs `terraform output -raw ansible_inventory_yaml > ansible/inventory/vms.yaml`
- Always runs `clean-ssh` first to remove stale SSH keys

## Make Targets

The full table with the gotchas per target is [docs/make-targets.md](docs/make-targets.md). Routine: `make plan`, `make build <vm>`, `make rebuild <vm>`, `make ansible <vm> TAGS=`, `make update`, `make flux-check`, `make k8s-seed|apps|smoke|update`, `make dns-records`, `make uptime-kuma CHECK=1`, `make validate`. A push to `main` is the cluster deploy (ADR 0048).

## Change Discipline

1. **Read the role and its templates** before modifying anything
2. **Check the `generate_secret.yml` pattern** when adding new secrets — follow the existing convention exactly
3. **Test idempotency** — running the same playbook twice should produce zero changes on the second run
4. **Never modify Terraform-generated files** — `ansible/inventory/vms.yaml` is generated by `make inventory`
5. **Pre-commit hooks run automatically** — trailing-whitespace and end-of-file-fixer modify staged files; re-stage after hook failures

## Documentation Discipline

### README
- Update `README.md` any time you change: make targets, prerequisites, first-time setup
  steps, supported VMs, or the overall architecture
- Do NOT update README for internal refactors that don't affect how a user operates the repo
- If you're unsure whether a change warrants a README update, err on the side of updating it

### CLAUDE.md
- Update `CLAUDE.md` any time you establish a new convention, discover a new gotcha, or
  resolve one of the Known Inconsistencies
- When a convention entry describes a component that no longer exists, delete it; git history is the record
- A mistake that wasted meaningful time earns a What Never To Do line only if it would change what most future sessions do: one bold rule, its reason, and the one tell that proves it. The incident timeline (dates, commits, what was tried, false leads) goes to [docs/LESSONS.md](docs/LESSONS.md) under the same heading, never here

## Git Discipline

### When to commit
This section is the operator's durable pre-authorization to commit in this repo (global rule "Git & delivery discipline"): sessions commit at these checkpoints without asking. Pushing stays gated.
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

### Deploy gate
- Under ADR 0048 a merge to `main` is a cluster deploy. The `main` ruleset today has no pull-request or review rule; the required protection (PR + code-owner review, narrow CODEOWNERS on `kubernetes/**` + `k8s_seed` + governance paths, `validate` as a required check, no App bypass, Apps never merge or push `main`) is specified in [docs/repo-deploy-gate.md](docs/repo-deploy-gate.md) and is a prerequisite before any agent identity authors PRs here (ADR 0052).

### What never to commit
- Any file matching `*.sops.yml` that hasn't been encrypted with `sops --encrypt` first
- `vlans.yaml`, `private_bindings.yaml`, `infisical-backup.yml` (gitignored — if git
  somehow picks them up, stop immediately)
- Generated files: `ansible/inventory/vms.yaml`
- Anything with a raw secret value — pre-commit hooks should catch this but don't rely on them

### Before committing
- Run `make setup-hooks` if hooks aren't installed
- Pre-commit hooks will auto-fix whitespace/EOF — re-stage modified files after hook runs
- If gitleaks (inside `security_guardrails.sh`), `detect-private-key` or `no-tfvars-secrets` fires, do NOT use `--no-verify` to bypass — fix the leak first


## What Never To Do

One rule per bullet: the reason and the tell that proves it. The incident behind each rule (dates, what was tried, false leads) is in [docs/LESSONS.md](docs/LESSONS.md) under the same heading. Subsystem rules live in `.claude/rules/` and load with the files they cover; these apply everywhere.

- **Never hardcode IPs in templates** — derive from `ansible_host`, VLAN prefix replacement, or `hostvars`
- **Never put a specific RFC 1918 address or the internal domain in a tracked file** — the repo is public, so IPs/subnets/domains are bindings (gitignored or derived from `network_data.*` facts). The `security_guardrails.sh` pre-commit hook blocks added lines containing them.
- **Never put secrets in `vars.auto.tfvars`** — pre-commit hook blocks this
- **Never paste `flux diff`, `flux logs`, `flux describe`/`kubectl describe kustomization` or a rendered `kustomize build --load-restrictor none` + substitution into a public PR, issue or commit message** — Flux output is *post-substitution*: every `${VAR}` has already become the binding (private addresses, the service domain, the registry name, ceph ids), and the repo is public. Quote the tracked manifest, or redact to the `${VAR}` form, before it leaves the workstation (ADR 0048, WP8)
- **Never run `ansible-playbook` or a python Infisical/PVE client outside `make`** — the certifi+root bundle reaches python only through the Makefile's `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE` export (ADR 0042); a bare run fails "Infisical is unreachable" on a perfectly healthy vault. Prefix the two variables with `kubernetes/.secrets/ca-bundle.pem` for a one-off playbook
- **Never background a long job with `nohup … &` inside an `ssh 'cmd'`, and never `pkill -f` a script name from that same session** — the job dies with the session, and `pkill -f "<name>"` matches the ssh shell's own command line, killing the session with no output. Use `setsid -f <cmd> </dev/null >log 2>&1` and `pkill -xf`, and keep such scripts in `~`, not `/tmp`
- **Never feed `python3 -` (or any command) a heredoc that follows an env-prefixed command line in a script run by Homebrew bash 5.3** — `heredoc_write` blocks on its pipe before the child is forked and the script hangs with no process to blame. Pass the program with `-c` and the values through the environment
- **Never run a play or a Terraform plan from a git worktree before linking the gitignored bindings, and never trust a green run that lacked them** — a worktree starts with none of `ansible/group_vars/all.yml`, `bootstrap.sops.yml`, `terraform/terraform.tfstate`, `vars.auto.tfvars`, `.venv`, the inventories or `kubernetes/.secrets`; without them a play can run *green* and a plan shows the whole fleet as new. Symlink each from the main checkout first
- **Never name a tracked file `secrets.yml`.** `.gitignore` excludes that name anywhere in the tree, so `git add` silently skips it; local `make validate` passes because the file is on disk, and CI fails with `Could not find specified file in role: tasks/secrets`. Check new files with `git ls-files` before pushing.
- **Never leave a hostless line in `~/.ssh/known_hosts` on the workstation.** A bare `ssh-ed25519 AAAA…` with no host field is ignored by OpenSSH but kills bpg's SSH client (`knownhosts: missing key type pattern`), so every file resource and every `make build` fails before creating anything. `awk 'NF>=3 || /^#/ || NF==0'` over a backup strips them.
- **Never use `echo -n`** in secret generation commands — use `printf '%s'`
- **Never use `is succeeded` alone** to gate on a registered variable — add `is not skipped`
- **Never use `git add -i` or `git rebase -i`** — interactive mode not supported
- **Never commit `vlans.yaml`, `private_bindings.yaml`, or `infisical-backup.yml`** — these are gitignored
- **Never skip pre-commit hooks** with `--no-verify`
- **Never use `define`/`$(eval export)` in the Makefile for secret propagation, and never a top-level `export X :=` for a secret** — target-specific `export X = $(call _secret,…)` on `TF_TARGETS`
- **Never write to Infisical root `/`** — all secrets live in named subfolders. Root must remain empty.
- **Never reference `secrets.sops.yml` in operational context** — it is a DR artifact only, produced by `make infisical-backup`
- **Never write copies of secrets to consumer folders** — consumers read from the source folder via multi-folder agent templates. Secrets belong to the VM/role that generates them.

## Known Inconsistencies

None open. The original six (compose paths, NFS options, `timezone` duplication, AdGuard rewrites, PBS backend, one baked `.env` secret) were resolved by 2026-09-10; the details are in git history of this section.
