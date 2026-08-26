# Operator hand steps — register and automation audit

Snapshot 2026-08-25, after P11 and the LLM VM pre-RMA test. This is the one list of everything the fleet still needs a human for: the steps pending right now, the surfaces that are hand-managed by standing decision, and for each an honest verdict on whether IaC could absorb it and what that costs. It is the input to the next tranche decision (P12): drain the automatable rows, or leave them and build the PBS second copy (ADR 0025 gap).

Verdict key: **AUTO** = existing tooling covers it, just wire it; **AUTO-NEW** = automatable, needs a new role/resource/one-time credential; **PARTIAL** = the mechanical half automates, a human decision or device stays; **HUMAN** = no API or a judgment call.

## 1. Pending right now

| # | Step | Where | Probe that says "done" | Verdict | What it takes |
|---|---|---|---|---|---|
| (d) | DHCP `domain` + DDNS on every DHCP VLAN (only mgmt is done; Infrastructure + Core still carry retired `.internal` zones and their lease updates fail) | pfSense | `dig <a lease's name>.<service domain>` from a non-mgmt VLAN answers; DHCP log has no `REFUSED` | **AUTO** | `make ansible-pfsense` already renders all 11 scopes (`pfsensible.core.pfsense_dhcp_server`, DDNS on the 9 `zone_vlans`). The only gate is the `ansible` user's password-prompted sudo — see §3 lever 1 |
| (e) | Seerr → Jellyfin backend | Seerr | `GET /api/v1/settings/public` `mediaServerType` = 2 | **PARTIAL** | The decision (reset costs 65 requests' history) is human; once decided, the wizard is an API sequence like `kubernetes/jellyfin/deploy.sh` |
| (f) | TV-app logins + phone passkey | devices | — | **HUMAN** | Real devices, real fingers |
| (g) | PVE/PBS role grants for the authentik users | PVE, PBS | `pvesh get /access/acl` and `proxmox-backup-manager acl list` show `@homelab` entries | **AUTO-NEW** | PVE: `pveum realm modify homelab --groups-claim groups --groups-autocreate 1` + ACLs on a `@homelab` group, with authentik emitting a `groups` claim (scope mapping in `blueprint-internal.yaml`) — grants then need no user to exist. PBS has no groups claim: pre-seed with `proxmox-backup-manager user create <name>@homelab` + `acl update` in the `proxmox_backup` role (login later just matches). PDM: `access/user.cfg` is a plain file (no ACL file yet) |
| (h) | msi BIOS Secure Boot flip (ESPs already grub-converted) | BIOS | `mokutil --sb-state` = enabled | **HUMAN** | MSI Z690 has no vPro; the MS-01s' AMT does power/console only — no BIOS-setting API anywhere in the fleet |
| (j) | PBS-collection CI secret (`PVETEST_*`) + CI rule tightening | GitHub, pfSense | `gh secret list` on the collection repo; pfSense CI rules match [pfsense-ci-vlan.md](pfsense-ci-vlan.md) | **AUTO** / **AUTO** | `gh secret set` from `terraform -chdir=terraform/hosts output -raw ci_api_token` = a 3-line make target; the rules are `pfsense_rule` rows once lever 1 lands. Operator-deferred, not blocked |
| (l) | Synology DSM-side bond for the Pro-Agg LAG | DSM | `ovs-appctl lacp/show` on the NAS shows both members | **HUMAN** | DSM has no IaC surface worth building for one bond |
| — | `qm destroy 100 --purge 1 --destroy-unreferenced-disks 1` on ms-01a (the one sweep survivor) | PVE | `rbd -p ceph-rbd ls \| grep vm-100-` empty | **HUMAN** (one command) | The permission classifier refused it three times; nothing to automate |
| — | PBS retention for the 20 swept VMIDs + 112 + rehearsal 1000 | PBS | `proxmox-backup-client snapshot list` shows no `vm/1xx` groups | **PARTIAL** | The decision (last copies of the pre-cutover fleet) is human; the prune is `proxmox-backup-manager prune`/`forget` per group and could be a `make pbs-forget VMIDS=` target |
| — | Intel RMA ticket for the 14900K | Intel portal | ticket number | **HUMAN** | Evidence is ready at `msi:/root/rma-evidence-20260825-gpu-resets.txt` + `/root/rma-evidence-20260819.tgz` |
| — | msi vfio modprobe config (hand-applied 2026-08-25) | msi | `lsmod` shows `vfio_pci` bound to 01:00.* after a reboot | **AUTO-NEW** | Per-node `pci_passthrough` list in `host-bindings.yaml` → `proxmox_host` templates `/etc/modprobe.d/vfio-*.conf` + `/etc/modules` + `update-initramfs`. Small |
| — | In-guest NVIDIA driver + Ollama on VM 240 (hand-applied) | llm | `nvidia-smi` + `systemctl is-active ollama` after `make rebuild llm` | **AUTO-NEW** | An `ollama` role: `nvidia-driver-580-server`, `/data` mount by label, Ollama install, the `nvidia-powercap.service` + `OLLAMA_*` env, Kuma row, homepage tile |

## 2. Standing hand-managed surfaces (by decision, with their runbooks)

| Surface | Decision | Runbooks | What is hand-managed today | Verdict |
|---|---|---|---|---|
| pfSense — DHCP, DDNS, firewall rules, NAT, WireGuard peers, remote syslog, netboot options, NUT, config backup, pfBlockerNG | ADR 0005 (hand-managed until pfSense IaC is evaluated; "Future work") | [pfsense-firewall-rules.md](pfsense-firewall-rules.md), [pfsense-wireguard-vps-peer.md](pfsense-wireguard-vps-peer.md), [pfsense-wireguard-mobile-peers.md](pfsense-wireguard-mobile-peers.md), [pfsense-ci-vlan.md](pfsense-ci-vlan.md), [pfsense-netboot.md](pfsense-netboot.md), [pfsense-nut.md](pfsense-nut.md), [pfsense-config-backup.md](pfsense-config-backup.md), [ipv6.md](ipv6.md) | Everything except the DHCP scopes, which have a role nobody can run unattended | **AUTO** for DHCP/DDNS/rules/NAT/log target/WireGuard (tooling exists, §3); **HUMAN** for NUT package config, pfBlockerNG feeds, the WAN DDNS client, package upgrades |
| UniFi controller | ADR 0005 (network fabric is Terraform since WP5; controller *settings* are not) | `terraform/unifi/` README | Remote syslog + netconsole target (re-pointed by hand at P4b), inform-host override, the 6 GHz radio disable, controller backups, `.unifi` restore on rebuild | **AUTO** for syslog/netconsole (`unifi_setting.syslog` in provider 0.55 — one resource); **PARTIAL** for radios (`unifi_device` has radio tables, untested); **HUMAN** for restore-from-backup (wizard) |
| Cloudflare tunnel routes (`tautulli`, `seerr`, `auth.<media domain>`) | none recorded — dashboard-managed since the tunnel was built | [cloudflare-tunnel-setup.md](cloudflare-tunnel-setup.md), [authentik-setup.md](authentik-setup.md) | Every ingress rule | **AUTO-NEW** | `cloudflare_zero_trust_tunnel_cloudflared_config` (provider v5) in `cloudflare-dns.tf`; the tunnel becomes locally-managed by Terraform, routes derive from the k8s Service names already in the docs |
| PDM remotes + fingerprint strip | ADR 0041 consequence (wizard pins; [pdm-remotes.md](pdm-remotes.md)) | [pdm-remotes.md](pdm-remotes.md) | Every remote after a PDM rebuild, plus the pin removal | **AUTO** | `proxmox-datacenter-manager-admin remote add --id --type --authid --token --nodes` is non-interactive; the token comes from a `proxmox_virtual_environment_user_token` in `terraform/hosts/iam.tf` (the `ci` pattern) instead of the wizard's `root@pam!pdm-admin-pdm`, so a rolled PDM stops leaving orphan tokens behind. `remotes.cfg` is a plain file — `remote update --nodes` per remote is idempotent |
| authentik realms on PVE / PBS / PDM | [authentik-setup.md](authentik-setup.md) ("hand step, bpg has no realm resource") | same | Realm creation after any rebuild of the three | **AUTO-NEW** | PVE: `pveum realm add/modify homelab --type openid …` from `secrets.authentik.pve_oidc_client_secret` in `proxmox_host` (idempotent by name, `pvesh get /access/domains/homelab` to diff). PBS: `proxmox-backup-manager openid create/update`. PDM: `/etc/proxmox-datacenter-manager/access/domains.cfg` is a plain `root:www-data 0640` file — template it. All three secrets already exist in Infisical `/authentik` |
| Proxmox host BIOS (Intel Default profile, turbo, SB, VT-d, boot order) | physical | [ms01-cluster-iac-plan.md](ms01-cluster-iac-plan.md) SB notes, memory | Per node at install and at every firmware event | **HUMAN** | No API; AMT/JetKVM give a console, not settings |
| Synology (NFS exports, iSCSI LUN, LAG, the `docker`/`plex` shares) | none | [physical-buildout-plan.md](physical-buildout-plan.md), `cluster.nas_mounts` for the client half | Everything server-side | **HUMAN** | DSM's API is not worth a role for a handful of one-time objects; the client half is already `proxmox_host` |
| Application UIs: Plex claim/library, Jellyfin users, authentik invitations, MeshCentral first account, Libation Audible login, Portainer agents, UptimeRobot monitors | per-app docs | [authentik-setup.md](authentik-setup.md), [uptimerobot-setup.md](uptimerobot-setup.md), [libation-audiobook-sync-plan.md](libation-audiobook-sync-plan.md) | First-run identity steps only; configuration is API-driven where it exists (Jellyfin, Portainer, Kuma, homepage, the arr stack) | **HUMAN** for OAuth/device logins (Audible, Plex claim, passkeys); **AUTO-NEW** for UptimeRobot (a terraform provider exists; three monitors) |
| GitHub: App credentials, repo secrets for CI | ADR 0032 | CLAUDE.md `/github-runner` row | The App itself (one-time), `PVETEST_*` on the collection repo | **AUTO** for repo secrets (`gh secret set`), **HUMAN** for App creation |
| JetKVM (`/etc/TZ`, EDID) | — | CLAUDE.md netconsole/RFC 3164 gotcha | Device settings | **HUMAN** (tiny) |

## 3. Automation audit — the levers, ranked by hand steps retired per unit of work

### Lever 1 — pfSense unattended (retires (d), (j)-rules, the P4b/P5 log-target and netboot repoints, WG forwards; ~8 recurring steps)

Three ways in, smallest first:

1. **Passwordless sudo for the `ansible` user on pfSense** — one checkbox in *System → User Manager → the `ansible` user → sudo* (or the `sudo` package's "no password" flag). Nothing in the repo changes: `make ansible-pfsense` runs unattended immediately with `pfsensible.core` (which already has `pfsense_dhcp_server` with DDNS, `pfsense_rule`, `pfsense_nat_port_forward`, `pfsense_log_settings`, `pfsense_dns_resolver`). Cost: one UI click, then the play can carry the remote-log target, the WG_VPS pass/forward rules, and the CI rules as new tasks. Risk: the `ansible` user then has root over ssh — same trust as every fleet guest.
2. **The REST API path with the operator's own tooling** — pfSense-API v2 is **already installed** (`/api/v2/status/system` answers 401 from the laptop) and reachable from the laptop (443 open on the vlan10 address). `goodolclint.pfsense` (35 modules: DHCP server/static mappings, rules, aliases, NAT, WireGuard tunnels/peers, DNS resolver, VLANs, gateways) and `terraform-provider-pfSense` (same surface, dev-override active in `~/.terraformrc`) authenticate with username/password (basic or JWT). Needs: a dedicated pfSense API user + password in `bootstrap.sops.yml` (nothing pfSense-shaped is there today — the `pfsense:` block only carries the Cloudflare token), and the collection lacks **DDNS fields on `dhcp_server`, custom DHCP options (netboot 250), and log settings** — so path 1 still has to carry those three. This is the ADR 0005 evaluation the plan calls "Future work"; the evaluation is now cheap because both halves exist.
3. **Config-file management** (template `config.xml` fragments over ssh) — rejected: pfSense rewrites the file and the schema is undocumented.

Recommendation: do 1 now (it is the whole of (d)), evaluate 2 as the ADR 0005 revisit when a Terraform-shaped surface (rules as code, reviewed in a plan) is worth more than one more Ansible play.

### Lever 2 — PDM as code (retires the remote wizard + pin strip, the realm re-add; every PDM rebuild)

`terraform/hosts/iam.tf`: a `pdm@pve` user + token with `PVEAuditor`/`PVEVMAdmin` on `/` (the `ci` pattern; the wizard today uses `root@pam!pdm-admin-pdm`, which survives PDM rebuilds as an orphan). `pdm` role: `remote add`/`remote update --nodes` for the cluster (three node FQDNs), worklab (its own token through the `proxmox.worklab` alias), and PBS (a `pdm@pbs` token from the `proxmox_backup` role); no `fingerprint=` is ever written, so [pdm-remotes.md](pdm-remotes.md) retires. Realm: template `access/domains.cfg`. Half a day, no ADR (ADR 0030 consequence).

### Lever 3 — OIDC realms + grants as code (retires (g) and the three realm hand steps on every rebuild)

- authentik: add a `groups` scope mapping to the PVE/PBS/PDM providers in `blueprint-internal.yaml` (blueprint change, `make talos-authentik`).
- PVE (`proxmox_host`): `pveum realm add|modify homelab --type openid --issuer-url … --client-id pve --client-key … --autocreate 1 --username-claim username --groups-claim groups --groups-autocreate 1`; ACLs on `@admins-homelab`-style groups — no user needs to exist first.
- PBS (`proxmox_backup`): `openid create|update` + pre-seeded `user create <operator>@homelab` + `acl update` (PBS has no groups claim; the username is known).
- PDM (`pdm`): `domains.cfg` template; ACLs the same way once PDM grows an `acl.cfg` (today the operator user is `default true` on the realm).

One day; the secrets already sit in `/authentik`. Records as an ADR 0040 consequence note in [authentik-setup.md](authentik-setup.md).

### Lever 4 — UniFi controller settings (retires the syslog/netconsole repoint; one resource)

`unifi_setting` in `terraform/unifi/` with the `syslog` block (`enabled`, `ip`, `port`, `netconsole_enabled`, `netconsole_host`, `netconsole_port`) pointed at the services prefix + `monitoring_syslog_offset` — the same binding `openobserve_listen_host` derives from. Provider 0.55 ships it. An hour; the UniFi apply is classifier-blocked for Claude, so the operator runs `make unifi-apply`.

### Lever 5 — Cloudflare tunnel config in Terraform (retires the dashboard routes; every new tunnelled app)

`cloudflare_zero_trust_tunnel_cloudflared_config` in `cloudflare-dns.tf` with the three ingress rules (`tautulli:8181`, `seerr:5055`, `authentik-ext-server:80`). One-time: flip the tunnel from remotely-managed to config-managed in the dashboard (or recreate it and rotate `cloudflared_tunnel_token` in `/plex-services`). Two hours.

### Lever 6 — small make targets (retires (j)-secret, the PBS prune decision's mechanics, the vfio hand config)

- `make ci-secrets`: `gh secret set PVETEST_TOKEN -R GoodOlClint/ansible-collection-proxmox_backup_server --body "$(terraform -chdir=terraform/hosts output -raw ci_api_token)"` (+ the endpoint/user values). Ten minutes.
- `make pbs-forget VMIDS=…`: `proxmox-backup-manager forget`/`prune` per group through the PBS API with the `/pbs` admin creds. One hour; the *decision* stays human.
- `proxmox_host` vfio: `pci_passthrough: ["10de:1eb0", …]` per node in `host-bindings.yaml` → modprobe + modules + initramfs. One hour; the LLM build proper needs it anyway.

### Stays human, on purpose

BIOS/Secure Boot/turbo (no settings API on any node), Synology server-side objects, device logins (TVs, passkeys, Audible, Plex claim), the Seerr reset and PBS-retention *decisions*, the RMA ticket, UniFi/pfSense restore-from-backup wizards, pfSense package upgrades (they drop NUT), physical cabling. These get runbooks, not roles.

## 4. Suggested P12 shape

If P12 is a drain tranche: levers 1 (path 1, one click) + 2 + 3 + 4 retire every *recurring* hand step on the rebuild path in about two days, leaving only decisions and devices in §1. The PBS second copy (ADR 0025) is orthogonal and gated; it can be P13 or run beside this. Either way (d) should not wait for the tranche — it is one checkbox and one `make ansible-pfsense`.
