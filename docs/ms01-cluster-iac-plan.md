# MS-01 Cluster Migration — IaC Change Plan

**Status:** awaiting operator approval (brownfield gate step 4). **Date:** 2026-07-10.

Repoints this repo from the single-node `pve` hypervisor to a 3-node PVE 9 cluster (`crete`, `crete2`, rebuilt `pve`) with Ceph, brings the Proxmox hosts themselves under Terraform from first boot, and rebuilds the service fleet greenfield as static-IP LXCs / docker-on-LXC / VMs per the placement doc.

**Design inputs (canon for the ops side):** `~/okf/playbooks/ms01-cluster-migration.md` (runbook), `~/okf/brainstorm/ms01-cluster-network.md` (network design), `~/okf/brainstorm/workload-placement-vm-lxc-docker.md` (placement), `docs/audit-2026-07-07.md` (IaC gaps).

## Decisions locked (interview 2026-07-10 + design docs)

| Decision | Choice |
|---|---|
| Host OS install | Wipe + committed `proxmox-auto-install` answer file per node; unattended PVE 9 install; Terraform takes over at first boot |
| Migration mechanism | **Greenfield rebuild everything** — Infisical re-seeded from the SOPS DR export, DNS ephemeral, UniFi re-imported from cloud backup (accept re-adoption blip). vzdump backups are rollback insurance only |
| PBS placement | VM on the cluster, datastore on the Synology NAS (portable datastore = the asset) |
| Infisical isolation | Stays a VM (crown jewel), `protected = true`, Ceph-backed |
| Storage | Ceph `size=3, min_size=2` on local NVMe day one; 25G switchless mesh (CX-4 Lx + DACs, hardware in hand); Synology = media + PBS datastore + ISO/templates only |
| GPU | vGPU retired entirely; LLM VM on `pve` with full passthrough (driver in guest); Plex uses MS-01 iGPU QuickSync via LXC `/dev/dri` bind-mount; `nvidia-licensing` VM retired |
| Endpoint | keepalived VRRP VIP on VLAN 40 (DNS name in the gitignored bindings) is the Terraform/Ansible endpoint |
| Management pane | PDM VM for human single-pane (cluster + standalone worklab); worklab never joins the cluster |
| LXC rule | Static IPs only — **never DHCP an LXC**. Verified 2026-07-10: bpg reads DHCP LXC IPs since v0.88, so this is convention (deterministic plan-time inventory), not workaround |
| DNS availability | Redundancy over migration: 2× AdGuard LXCs + BIND9 primary/secondary on different nodes, both resolvers handed out (LXC restart-migration verified: no live migration, blip is stop+start on Ceph) |
| UniFi | New aggregation switch configured via Terraform from first adoption (`modules/unifi-network/`, provider already in project); pfSense IaC deferred to future work (ADR 0005) |
| Repo visibility | Stays public; private IPs/domain scrubbed from tracked files going forward + pre-commit guard; history exposure accepted (ADR 0004 era values rotate anyway as the fleet rebuilds) |
| DNS-first access | Every guest/node/VIP gets a DNS record generated from the IaC inventory; names are the access layer, static IPs stay as IaC plumbing (`ansible_host` remains IP) (ADR 0006) |
| Certs | Hybrid: Infisical PKI (internal CA, ACME issuance) for the fleet with Ansible-distributed root; LE wildcard per zone for browser-facing UIs so unmanaged devices need no root install. step-ca is the fallback if self-hosted PKI is license-gated (ADR 0007) |
| Infisical hardening | Already gets the base hardening role; tighten during rebuild: UFW + PVE firewall to mgmt/services VLANs only, SSH from mgmt only, unattended-upgrades; consider cluster-wide Ceph OSD at-rest encryption |

## Terraform / Ansible boundary

Terraform (bpg `~> 0.111`, bumped from `~> 0.78`) manages everything the PVE API exposes; Ansible covers the bootstrap the API can't do.

| Layer | Tool | Mechanism |
|---|---|---|
| PVE install | answer file | `answer-<node>.toml` committed; `proxmox-auto-install-assistant` bakes the ISO (checklist in repo) |
| First-boot API token for Terraform | bootstrap script | one small first-boot hook (or `make node-bootstrap <node>`) creates the `terraform@pve` user + token; the only hand-off step |
| Host networking (bond0 LACP on X710s, VLAN-aware vmbr0, VLAN interfaces, MTU 9000 on storage VLAN) | **Terraform** | `network_linux_bond` / `network_linux_bridge` / `network_linux_vlan`, applied over the stable 2.5G mgmt link so the API path is never the link being reconfigured |
| Cluster create/join (`pvecm`), Ceph bootstrap (`pveceph install`, MON/MGR/OSD), FRR OpenFabric 25G mesh, keepalived VIP | **Ansible** (new `proxmox_host` role) | not exposed usefully via the API/provider |
| Ceph pool, storage definitions, SDN zones/VNETs (all nodes), cluster options, HA groups/resources, ACME, users/tokens | **Terraform** | `proxmox_ceph_pool`, storage resources, existing network module extended |
| VMs + LXCs | **Terraform** | existing `proxmox-vm` module + new container support |

New Terraform root **`terraform/hosts/`** with its own state for the host/cluster plane (networking, cluster options, Ceph pool, SDN). Rationale: it must exist before the VM fleet, changes rarely, and a host-networking apply that drops connectivity must not hold the VM project's state hostage. The main `terraform/` project keeps the fleet. (ADR-0002.)

## Repo work packages

### WP0 — Day-0 safety net (ops, no code)
- vzdump every production pve VM → Synology NFS; test-restore one on an MS-01 before wiping anything.
- `make infisical-backup` → fresh SOPS DR export; verify `bootstrap.sops.yml` decrypts; **verify every key in the gap table of [infisical-external-credentials.md](infisical-external-credentials.md) is present in the export** (docker cloudflared token, github-runner app creds, homepage tokens).
- Confirm UniFi cloud backup is current; download a local copy of the `.unf` too.
- Capture `qm config <id>` for every VM + `pvesh get /cluster/resources` into `docs/pre-migration-state/` (reference, gitignore if it contains secrets — it shouldn't).
- **DoD:** one vzdump restore verified on MS-01 scratch; SOPS export decrypts; `.unf` in hand.

### WP1 — `terraform/hosts/` root + auto-install
- `answer-crete.toml` / `answer-crete2.toml` / `answer-pve.toml`: disk layout (ZFS boot mirror where applicable), initial mgmt IP on the i226-V / VLAN 30, root key.
- Host networking per node: `bond0` (X710 ×2, 802.3ad layer3+4) → VLAN-aware `vmbr0`; host VLAN 40 IP (web UI) + VLAN 20 IP (storage, MTU 9000) on the bridge; i226-V keeps VLAN 30 (corosync ring0); i226-LM = ring1 subnet (+ AMT is ME-side config, documented not managed); 25G ports left for the mesh (FRR, WP2). pve variant: 82599ES bond, single I225-V.
- **NIC naming: install the 25G cards BEFORE the answer-file install.** The PVE 9 installer auto-pins every present NIC by MAC via `/usr/local/lib/systemd/network/50-pmx-nicN.link` (`MACAddress=` match) — so a fresh install gives stable `nicN` names immune to later PCIe renumbering, *including the ConnectX ports* as long as the card is seated at install time. Reference the pinned `nicN` names in the answer-file/`interfaces`, not `enpXsY`. (Verified 2026-07: crete2, fresh-installed, was MAC-pinned and survived its card install untouched; crete, upgraded-from-PVE-8, kept unpinned `enpXsY` and lost all networking when its card renumbered the bus — the config still pointed at the old `enp90s0`. Upgraded nodes not being rebuilt need manual MAC `.link` pinning; pve was pinned by hand to `mgmt0/sfp0/sfp1`.)
- **Same rule protects GPU passthrough.** Adding the ConnectX card to pve renumbered its IOMMU groups, breaking the RTX 5000 resource mapping (`iommugroup` 20→21) and stopping the vGPU guests until the mapping was corrected. IOMMU groups, like NIC names and PCI addresses, are stable across reboots but shift when PCIe hardware changes — so seat every card (NIC + GPU) *before* configuring the LLM-VM passthrough. Full passthrough binds by PCI path (`0000:01:00.0`); the optional `iommugroup` pin in the PVE resource mapping can be omitted for extra robustness.
- Cluster options, ACME, `terraform@pve` ACLs once the cluster exists.
- **DoD:** fresh answer-file install of crete → `terraform apply` in `hosts/` converges with zero manual host edits; re-apply is a no-op; host reboot comes up with all planes (bond, VLANs, jumbo `ping -M do -s 8972` to the NAS).

### WP2 — Ansible `proxmox_host` role
- Idempotent `pvecm create`/`add` (skip when already a member), temporary QDevice while 2-node (drop when pve joins).
- `pveceph install` + MON/MGR/OSD creation (idempotent: check before create), FRR OpenFabric on the 25G mesh, keepalived VIP with `pveproxy` track_script + unicast peers.
- New `proxmox` inventory group: `crete`, `crete2`, `pve` (replaces the single-host `inventory/proxmox.yaml`); `update-all.yml` and `monitoring_users` (currently hardcoding a single `proxmox_host` IP in `group_vars/all.yml:34`) go per-node.
- **DoD:** role run twice = zero changes; `pvecm status` quorate; `ceph -s` HEALTH_OK; VIP answers on VLAN 40 and survives killing pveproxy on its holder.

### WP3 — Main project cluster rework
- Provider bump `~> 0.78` → `~> 0.111`; endpoint → the VIP; per-node `node {}` SSH blocks for file uploads.
- `vm_configurations` schema gains `node_name` (placement) + `ha` (bool); HA resources for Ceph-backed guests; LLM VM pinned to pve, excluded from HA.
- Storage: default disk storage → Ceph RBD pool (`proxmox_ceph_pool` + storage def); cloud-init snippets → a small CephFS datastore (shared, so snippet upload is node-agnostic).
- SDN: `nodes = [all three]` (fixes `modules/network/sdn.tf:13`); bridge references updated to the new `vmbr0` model.
- Delete `pci.tf`, `gpu_mapping`, `needs_gpu`, mediated-device plumbing.
- LXC support: `proxmox_virtual_environment_container` alongside VMs in the module (static IP via `initialization.ip_config`, `nesting`/`keyctl` flags for docker hosts, `/dev/dri` device passthrough for Plex); inventory output gains guest type + node.
- **DoD:** `terraform plan` clean against the live 3-node cluster; a test LXC + test VM deploy on each node, land on Ceph, and appear in `vms.yaml` with correct static IPs.

### WP4 — Fleet rebuild definitions
Placement per the okf doc: **VMs** — infisical (protected), pfsense-test, github-runner, proxmox-backup, unifi, LLM (new). **LXCs** — plex (iGPU), adguard ×2, dns ×2 (BIND primary/secondary), lancache, squid, homepage, mcp, minio, doge. **docker-on-LXC** (nesting) — plex-services, openobserve, docker-legacy. **Retired** — nvidia-licensing.
- DNS redundancy (ADR 0003): the two AdGuard instances get identical IaC config; BIND secondary via zone transfer; instances pinned to different nodes via `node_name`; pfSense DHCP hands out both resolver IPs (manual step this round, documented).
- DNS-first (ADR 0006): `dns` role templates BIND zone records from the Terraform inventory + node/VIP list — every guest gets a name automatically; AdGuard forwards internal zones to BIND; homepage/monitoring/inter-service configs use names, not IPs.
- Infisical hardening tightening: UFW + PVE firewall scoped to mgmt/services VLANs, SSH from mgmt only, unattended-upgrades enabled.
- Ansible roles port as-is (SSH is SSH); expected touch-ups: anything assuming a full VM (qemu-guest-agent tasks, kernel/sysctl tasks like the SABnzbd NFS tuning move to the host or get `when: not lxc` guards), plex role gains the `/dev/dri` render group bits.
- Stateful-data checklist (see below) drives per-service restore steps.
- **DoD:** `make apply` from a clean clone (+ SOPS key) converges the whole fleet; second run zero changes; per-service smoke checks pass (DNS resolves, Plex plays with QuickSync transcode, arr stack healthy, monitoring ingesting).

### WP5 — UniFi network module (ADR 0005)
- `modules/unifi-network/` in the main project: `unifi_network` resources from the gitignored `network-data/vlans.yaml`, port profiles (node-bond trunks, NAS LAG, corosync access), port overrides + LACP aggregation for the new switch, jumbo MTU on the storage VLAN. Port-to-device assignments in a gitignored bindings file.
- Scope: the new aggregation switch + migration-touched ports only; full-fabric import is future work.
- **DoD:** switch adopted → `terraform apply` produces the complete working switch config with zero hand edits in the controller; re-apply is a no-op; node bonds negotiate LACP; jumbo validated end-to-end.

### WP6 — Public-repo scrub + guard
- Repo is public; 15 tracked files carry private IPs, 6 the internal domain (scan 2026-07-10) — violating the policy-vs-binding rule. Operator decision: keep public, scrub going forward, accept history exposure.
- Move concrete IPs/domains out of role defaults, templates, and examples into gitignored bindings or inventory-derived vars; examples get RFC 5737 / placeholder values; delete `archive/` (pre-consolidation cruft holding full old IP maps) and the obsolete `scripts/nvidia-vgpu-project-prompt.md`.
- Pre-commit hook blocking RFC 1918 addresses and the internal domain in tracked files (allowlist for `*.example.*` placeholders where needed).
- Scope call to confirm during WP6: hostnames and VLAN *numbers* stay tracked (they're structural, already public throughout the repo, and unavoidable in working IaC); IPs, subnets, and domain names are the scrub targets. Tighten later if the operator wants VLAN IDs treated as bindings per the strict policy reading.
- **DoD:** the leak scan (`git grep` for private-IP ranges + domain over tracked files) returns zero hits; hook demonstrably rejects a test commit containing an internal IP.

### WP8 — PKI + certs (ADR 0007)
- **Gate first:** verify Infisical PKI (internal CA + ACME) is available on the self-hosted tier and that `make infisical-backup` captures PKI objects; if gated → step-ca LXC, same shape.
- Infisical PKI: internal CA + cert profiles; PVE node certs via native ACME pointed at the internal directory (bpg ACME resources in `terraform/hosts/`); guest certs via a `cert_client` role (lego/certbot, ACME against Infisical).
- Root CA distribution: common role installs the internal root into every managed guest/node trust store.
- LE wildcard per internal zone: generalize `plex_certificate` (DNS-01, existing Cloudflare token), renew centrally, deliver via the Infisical-agent file pattern to browser-facing services (homepage, plex, arr UIs).
- **DoD:** `curl https://<any-fleet-name>` verifies from a managed guest with no `-k`; browser-facing UIs show trusted certs on an unmanaged device (no root installed); renewal dry-runs pass for both planes.

### WP7 — Docs + guardrails
- README: new prerequisites (answer-file/ISO step, `terraform/hosts/` root, node bootstrap), updated make targets.
- CLAUDE.md: cluster architecture, LXC conventions, **add to What Never To Do:** "Never DHCP an LXC"; "Never reconfigure host networking over the interface carrying the PVE API session".
- Retire `scripts/nvidia-vgpu-project-prompt.md` (obsolete with vGPU gone); keep the packer golden-image plan (orthogonal, still valid).

## Sequencing (interleaved with hardware/ops)

| When | Work |
|---|---|
| Day 0 (today) | WP0 backups (incl. credential-gap verification). Rack + adopt the new SFP+ switch, then **WP5 UniFi apply** configures it (VLANs, port profiles, LACP, jumbo) before cabling. Install 25G NICs + cable mesh DACs + 10G links on the MS-01s (their VMs are disposable — power off freely). Write WP1+WP2 code against the docs. |
| Day 1 | Wipe crete/crete2 → answer-file install → `hosts/` apply → `proxmox_host` role → 2-node cluster (+ temp QDevice). Verify DoD gates. |
| Day 1–2 | `make bootstrap` at the new cluster (adguard + infisical on MS-01 local ZFS interim), `make infisical-seed` from the SOPS export, dns LXC, unifi VM + cloud re-import. Per-service cutover: stop the old VM on pve as each replacement goes live (avoids static-IP conflicts). |
| Day 2 | Nothing left needed on pve → wipe pve (25G NIC installed, GPU stays), answer-file install, join cluster, drop QDevice, Ceph bootstrap + pool, validate mesh/`HEALTH_OK`. Keepalived VIP up; repoint endpoint at it. |
| Day 2–3 | Move interim guests' disks → Ceph. Deploy the rest of the fleet greenfield in final form (WP3/WP4). Stateful restores per checklist. |
| Day 3+ | LLM VM (vfio passthrough, pinned), HA resources, PDM VM, monitoring per-node, PKI + certs (WP8), repo scrub + guard (WP6), docs (WP7), decommission sweep. |

## Stateful-data checklist (decide per service before its rebuild)

| Service | State at risk | Proposal |
|---|---|---|
| Infisical | all runtime secrets | re-seed from SOPS DR export (decided) |
| UniFi | controller config/adoption | cloud backup re-import (decided; expect re-adoption blip) |
| Plex | library metadata, watch history | copy `Library` dir out of the old VM before wipe; restore into the LXC — cheap vs a full re-scan + lost watch state |
| plex-services | postgres (arr DBs), configs | pg_dump before wipe → restore into fresh stack (the PBS-restore gap is a known issue; a manual dump sidesteps it) |
| minio | bucket contents | inventory what's in it first; likely copy out via `mc mirror` |
| openobserve | metrics/log history | drop (observability history, rebuildable) |
| lancache | cache contents | drop (it's a cache) |
| doge | chain data | copy datadir if re-sync time matters, else re-sync |
| Tautulli/home­page/etc. | small app DBs/configs | config is IaC; small DBs copied out with their service if wanted |

## Test bar / verification

- Every Terraform change: `terraform validate` + clean `plan`; applies are idempotent (second apply = no changes).
- Every Ansible role: run-twice-zero-changes on a fresh guest (repo standard).
- Phase gates are the DoDs above — no phase starts until the prior gate's evidence is captured (command output in the session / `docs/pre-migration-state/`).
- Rollback: until pve is wiped, full rollback = power the old VMs back on (they're stopped, not destroyed, during cutover). After pve is wiped, rollback = vzdump restore onto the cluster (verified in WP0).

## Future work (explicitly out of scope this migration)

- **pfSense IaC** (ADR 0005): evaluate pfsensible Ansible collection vs a REST-API Terraform provider (needs the pfSense-API package); targets firewall rules, DHCP/resolver options, WireGuard peers. The redundant-DNS DHCP change and any migration-driven rule edits are documented manual steps until then.
- **Full UniFi fabric under Terraform**: import the Pro-24, Flex, APs, and remaining port profiles (WP6 covers only the new switch + touched ports).
- **Re-publicizing history**: operator accepted history exposure; if that changes, a git-filter-repo rewrite is the path.

## Open items (not blocking approval)

- **BOINC:** keep CPU-only or drop — decide before WP4 lands the docker-legacy stack.
- **Corosync ring1:** design allows ring1 on the i226-LM subnet or the bond; default to configuring ring1 on i226-LM in WP2 (cheap), drop if flaky.
- **MS-01 PCIe lane-sharing:** verify the x4 slot doesn't starve an M.2/OSD when the 25G NIC is installed (check during Day-1 bring-up, before Ceph).
- **Packer golden images:** unaffected; revisit after migration.

## CLAUDE.md conflicts surfaced

- The repo overview + conventions describe a single-node pve world; WP5 amends them (same edit window as implementation, per house rules).
- "No migration tasks" rule **holds**: roles stay greenfield; all migration mechanics live in this plan + the okf runbook + Make targets, never in role logic.
