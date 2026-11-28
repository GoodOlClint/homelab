# Tenant edges change plan

Change plan for [ADR 0067](decisions/0067-the-homelab-hosts-tenant-enclaves-through-a-fixed-set-of-interface-edges.md) (tenant edges) and [ADR 0068](decisions/0068-the-second-b70-is-released-from-vm-240-to-a-tenant-through-a-named-pci-mapping-and-the-bge-m3-embedder-retires.md) (GPU mappings, code-intel retirement). Status: draft, 2026-11-27, revised after one Codex review (disposition at the end); awaiting operator approval. The tenant's own build is planned in the tenant's private repository, not here.

## Goal

1. Code-intel and the BGE-M3 embedder are gone, and VM 240 serves chat from its first B70 attached by a named PCI mapping.
2. The homelab offers a tenant every edge in ADR 0067's table through code or a documented hand step, with the tenant's name, VLAN, VMID range and addresses only in gitignored bindings.
3. A tenant can build its first two VMs (no GPU) with its own token and Terraform state, they are backed up nightly to the tenant's own PBS datastore, and `make update` patches them.

## What the map found

Read 2026-11-27 from the repo. CI is the precedent, but every CI edge is a hard-coded singleton named `ci`.

- **Proxmox:** pool `ci`, user `ci@pve`, token and ACLs are singletons in `terraform/hosts/iam.tf:7-94`. The VMID range is a comment, not enforced. `ci-isos` comes from `proxmox_host` `storage.yml:26-63` and has no `snippets` content. Pool rights (`VM.Allocate` plus `Datastore.AllocateSpace`) also allow unprivileged containers.
- **PCI:** the VM module takes raw ids only (`modules/proxmox-vm/variables.tf:112-119`, `virtual_machines.tf:290-298`). Nothing creates a PCI resource mapping. The pinned bpg 0.111.1 has both the mapping resource and `hostpci.mapping`; no provider upgrade is needed. VM 240 is `vm-configs.tf:219-239`, raw ids `03:00.0` and `07:00.0`.
- **Cloud-init:** the module uploads user data as a snippet over SSH (`virtual_machines.tf:158-177`). A pool-scoped API token cannot do that, so a tenant root uses `initialization.user_account`, and its images need a store it may upload to (`Datastore.AllocateTemplate`).
- **VLAN:** a `vlans.yaml` entry plus a `private_bindings.yaml` zone gives the SDN VNET (`make sdn-apply`) and the pfSense DHCP scope. A network in `dns_server.zone_vlans` registers leases in the fleet zone with `dhcp-update-key`. The UniFi network and pfSense interface and rules are hand steps (ADR 0005, `docs/pfsense-ci-vlan.md`). `docs/pfsense-firewall-rules.md` has a VPN-source pass to all internal subnets.
- **DNS:** one hard-coded child zone and key (`bind9/defaults/main.yml:25-34`, `named.conf.local.j2:18-45`).
- **Infisical:** the project and admin identity come from one-shot bootstrap with `projectName: "homelab"` hard-coded (`bootstrap_infisical_setup.yml:160-275`). Every machine identity is an organization member. `refresh-identity.yml` deletes organization identities ending in `-vm` that are not in fleet inventory. The vault's PBS backup (`infisical_pbs_backup.sh.j2`) saves the whole database and its encryption key to fleet storage.
- **PBS:** `backup@pbs` and its token hold `DatastoreAdmin` on every datastore in `pbs_datastores` (`proxmox_backup/tasks/main.yml:483-575`). The role logs into one iSCSI target. `backup-finalize.yml` hard-codes the fleet user and secret. Backup jobs live in `terraform/backup-jobs.tf` and need `Sys.Modify` on `/`, which a pool token lacks.
- **Holder volumes:** the module's holder is VMID 900 with `backup = true`, and the module has no `pool_id`.
- **NAS:** no automation for targets, LUNs or NAS users.
- **authentik:** no Caddy `forward_auth` exists; the internal realm's one forward-auth app is admin-gated as a whole.
- **`make update`:** `Makefile:315-322` with `update-all.yml`, which loads no secrets.
- **Code-intel footprint:** about 40 files across Terraform, the `llm`, `mcp`, `scratch`, `k8s_apps`, `k8s_seed` and `infisical_client` roles, the Flux tree (`apps/codeintel.yaml` has `prune: false`, so removing files deletes nothing live), `vlans.example.yaml`, CLAUDE.md, rules files and ADRs 0051, 0052, 0054, 0055, 0060. The gateway's `code_intel` tools ship in the external homelab-mcp package.

## Scope

In scope: Phase 0, Phase 1 and Phase 2's homelab steps.

Out of scope:
- The authentik application and Caddy `forward_auth` edge, until a web UI must be reached by anything other than an SSH tunnel. Until then tenant dashboards bind to loopback and the operator uses `ssh -L`.
- pfSense and UniFi IaC (ADR 0005 stands) and Synology automation.
- Enforcing VMID ranges and "VMs only": Proxmox has no per-pool VMID ACL, and pool rights allow containers. Both are tenant conventions, checked by the tenant's Terraform validation, and ADR 0067 says so.

## Phases

### Phase 0: code-intel retirement and GPU mappings (now)

Split into a reversible cutover (0a) and a destructive retirement (0b). Nothing in 0b runs until 0a has passed its gates.

**0a: cutover, one VM 240 rebuild.**

| Step | Change |
|---|---|
| 0a.1 | Record the known-working state: VM 240's current `qm config` and the host BDF (bus/device/function address) of each card, kept off-repo. Rollback is restoring those raw ids from `root@pam`. |
| 0a.2 | `terraform/hosts`: two `proxmox_virtual_environment_hardware_mapping_pci` resources, one per B70 on msi, names and BDFs from a gitignored tfvars binding. `make hosts-plan`, then `make hosts-apply`. |
| 0a.3 | VM module: `pci_devices` gains `mapping = optional(string)` with `id` optional; a validation requires exactly one. The hostpci block passes `mapping`. |
| 0a.4 | VM 240: both cards by mapping name. |
| 0a.5 | `llm` role: remove the embedder service, warmup, Caddy route, defaults and handlers; in `vllm.service.j2` remove `After=llama-embed`, `PartOf` and the `ExecStartPre` health gate, keeping the Docker and model-mount ordering; drop `code_intel` and `mcp` from `llm_api_clients`. The model file stays on the data volume until 0b. |
| 0a.6 | **In place, not a rebuild (operator, 2026-11-27).** A fresh guest cannot install: the role's pinned Mesa build (`llm_mesa_version`) is gone from the Kisak PPA, which now offers only a newer build; the running guest has it installed. So: `make hosts-apply`, a targeted apply of VM 240 (hostpci change, one restart), `make ansible llm`, then a one-time hand step on the guest: `systemctl disable --now llama-embed`, remove its unit and warm-up script, `daemon-reload`. No cleanup task is written into the role (greenfield rule). Re-pinning Mesa and proving a clean VM 240 rebuild is its own change before VM 240 is next rebuilt. |

Gates for 0a:
1. `make plan` and `make hosts-plan` show only the mappings and VM 240.
2. Cold start: an authenticated chat answer; `systemctl status llama-embed` reports no such unit; nothing listens on the embedder port.
3. Card identity: the guest card chat uses resolves, through the mapping, to the first card's recorded host BDF, and the second card shows no process in the guest.

**0a result (2026-11-27): passed.** Mappings `b70-0`/`b70-1` created; VM 240 updated in place (`hostpci0: mapping=b70-0` → host `03:00.0`, `hostpci1: mapping=b70-1` → host `07:00.0`); `llm` role ran with 0 failures; the old embedder unit was removed by hand. Gates: authenticated chat answered through Caddy, unauthenticated got 401, `/llama/v1/embeddings` now 404, no embedder unit or listener; vLLM holds only the guest render node on pcie-port-1 (host `03:00.0`), and the second card's node has no user. The Mesa rebuild blocker is issue #68.

**0b: retirement, after 0a passes.**

| Step | Change |
|---|---|
| 0b.1 | Data decision first: the operator either asks for a final `pg_dump` of the `codeintel` database (kept off-repo, hash recorded) or writes "discard" in the PR. Same for the `/codeintel` and two `llm_api_key_*` secrets and the scratch guest's seeded `openrouter_api_key`. |
| 0b.2 | `mcp` role and `mcp.env` template: remove `CODE_INTEL_*`, the units file and the `/codeintel` read. Check that the pinned homelab-mcp gateway starts with no code-intel settings; if not, the gateway package change lands first. |
| 0b.3 | Cluster teardown through its owner: suspend the `codeintel` Flux Kustomization, delete its namespace (PostgreSQL, both PVCs, the backup job, the `InfisicalSecret` consumers), then remove the Flux tree, the Kustomization, `k8s_apps` `codeintel.yml`, the `k8s_seed` PSA entry and bindings, and `metallb.offsets.codeintel` (tracked example and gitignored binding). |
| 0b.4 | Scratch guest: remove `scratch_vms` code-intel and its `scratch_guests` entry; retire LXC 280 by ADR 0054's path: `terraform state rm` of its `code-intel` instances, then `pct destroy 280` on its node. Never a targeted destroy (LESSONS.md: `-target` destroy takes every dependent of a shared resource block). |
| 0b.5 | Remove the `codeintel` loader-loop entry, then delete the secrets per 0b.1. Delete the model file from the data volume. |
| 0b.5a | Added after the 0b Codex review: before deleting the namespace, record each `codeintel` PVC → PV → Ceph image; the `ceph-rbd` class is `Retain`, so after the namespace goes, delete both PVs and their RBD images (`docs/ceph-rbd-static-pv.md`). After LXC 280 goes, `make inventory` and check `code-intel` is absent from `vms.yaml`. After the mcp deploy, the rendered `mcp.env` holds no `CODE_INTEL_` key (names only, never values) and the operator tool list has no `code_intel.*`. Remove `metallb.offsets.codeintel` from the gitignored `vlans.yaml`, then delete the `codeintel` and `code-intel` forward and reverse records by hand (the DNS task never deletes) and check them against BIND. |
| 0b.6 | Docs: CLAUDE.md rows for `/codeintel`, `/llm`, `/scratch`; `.claude/rules/llm.md` embedder paragraphs; README; ADR 0060 marked superseded in part; consequence notes on 0051, 0052, 0054, 0055. |

Gates for 0b:
1. After 0b.2: the gateway restarts and its remaining tools answer.
2. After 0b.3–0b.4: `kubectl get ns codeintel` is NotFound; no `codeintel` PVC or PV remains; LXC 280 is absent from Proxmox and from Terraform state.
3. After 0b.5: `make ansible-all` and `make k8s-apps` succeed, then a second run regenerates none of the deleted secrets.
4. `git grep -n -i -e code.intel -e codeintel -e llama-embed` shows only history (ADRs, LESSONS.md, superseded plans).

**0b result (2026-11-27): passed.** Gateway redeployed with no `CODE_INTEL_*` in its env files or live process (the pinned gateway registers code-intel tools only when `CODE_INTEL_PG_DSN` is set). LXC 280 retired by `terraform state rm` + `pct destroy` (state backed up first); `make inventory` dropped it. After the push, Flux removed the `codeintel` Kustomization; the namespace was deleted by hand, then both `Retain` PVs and their RBD images. `/codeintel` (four keys and the folder), `llm_api_key_code_intel` and `llm_api_key_mcp` deleted; the model file deleted; the `codeintel` offset removed from the binding; `codeintel`/`code-intel` A and PTR records deleted and checked at BIND; the 29 `codeintel-postgres` PBS snapshots deleted. Two runs each of `make ansible-all` and `make k8s-apps`: 0 failures, and nothing regenerated. ADRs 0067/0068 accepted; 0055 and 0060 superseded by 0068.

### Phase 1: tenant edges for the first two VMs (now)

Prerequisite from the tenant repository: its flow table (source, destination, port, identity for every flow in its ADR 0001), delivered before 1.3.

| Step | Edge | Change |
|---|---|---|
| 1.1 | NAS | Hand steps first: a tenant NAS user; one new LUN for the tenant PBS datastore on the existing PBS target, whose initiator list must name only the PBS guest (2026-11-27: a second LUN, not a second target, so the role keeps one login and picks the disk by LUN number); one target per tenant application LUN, whose initiator list names only the Proxmox nodes. **Access (2026-11-27):** a first attempt at DSM per-LUN host permissions cut PBS off its datastore until reverted; the second attempt held. `Target-1` (fleet PBS LUN 1, tenant PBS LUN 2) grants the PBS guest's IQN only and allows a single session, so no other initiator can log in while PBS is connected. The tenant data-lake LUN is Read/Write for msi only (DSM allows one Read/Write host on a non-clustered LUN) and No access for the other nodes: the store moves between nodes only stopped, after changing that permission by hand. |
| 1.2 | Proxmox | `terraform/hosts/iam.tf`: a `tenants` map read from the gitignored `network-data/local/tenants.yaml` (schema: tracked `network-data/tenants.example.yaml`, shared by every Phase 1 consumer) (pool, user, storages, image store, SDN zone and VNET, `pci_mappings`). `for_each` creates pool, user, privsep-off token and CI's ACL set, plus `PVEDatastoreUser` on the tenant's storages. A custom role `TenantMapping` (`Mapping.Use`, `Mapping.Audit`) on `/mapping/pci/<name>` for each listed mapping. `proxmox_host` gains a parameterised copy of the `ci-isos` block for a tenant image store (`iso,import`, with `Datastore.AllocateTemplate` for the tenant only), and a PVE iSCSI storage entry per tenant application LUN, ACL'd to the tenant user. Outputs keyed by tenant; the token is handed to the tenant by hand. CI is unchanged. |
| 1.3 | Network | Gitignored `vlans.yaml` and `private_bindings.yaml` entries; `make sdn-apply`; the pfSense DHCP scope from the existing role, with the tenant VLAN **not** in `zone_vlans`, its domain set to the tenant child zone and the tenant's resolver. Hand steps: UniFi network; pfSense interface and the rules from the tenant's flow table; a block from the VPN source to the tenant subnet ahead of the VPN pass-all. |
| 1.4 | DNS | `bind9`: a `bind9_child_zones` list (name, key, VLAN keys, TTL) from a gitignored binding; key generation, key stanzas, `zonesub` grants and the allow-query negation loop over it. The CI zone becomes the list's tracked default entry. The tenant key goes to the tenant by hand. |
| 1.5 | Infisical | Hand step, documented: two tenant projects. **Admin** (Terraform state copy, tokens, recovery material) is read only by an operator-workstation identity. **Runtime** (job keys) is read by per-guest identities. Identity names never end in `-vm`. `refresh-identity.yml` is narrowed to delete only identities that are members of the homelab project. |
| 1.6 | PBS | `proxmox_backup`: datastore creation and the fleet ACL loop are separated, so a tenant datastore on the 1.1 LUN is created without the fleet grants; a tenant user and token with `DatastoreBackup` on it only. `backup-finalize.yml` takes the user, secret and storage id as variables and creates the tenant's PVE storage entry. |
| 1.7 | Backup job | `terraform/backup-jobs.tf`: a nightly tenant job from gitignored bindings (tenant VMIDs, the tenant PBS storage). The fleet root owns it because creating a job needs `Sys.Modify` on `/`. |
| 1.8 | Patching | Makefile: `TENANT_INVENTORIES` read from a gitignored include; each listed path is added with `-i` to both `update` lines; a listed path that is missing, unreadable or has no hosts fails the target. No include means today's behaviour. |
| 1.9 | SSH | Nothing to build: the tenant root reads the same public key path into `initialization.user_account`. |

Phase 1 gates, all run with the real tenant token and identities:
1. **CI unchanged:** CI's rendered BIND config and `terraform/hosts` ACLs are byte-identical before and after.
2. **Proxmox:** from empty tenant state, the token uploads an image to its store and builds a test VM in its pool on its VNET. It is denied: a VM outside the pool, an unmapped PCI device, any fleet VM, the CI and fleet image stores, the PBS iSCSI target. A container-create attempt is recorded (allowed is expected; it is a convention).
3. **Network:** each flow in the tenant table works from its real source behind the final rules. A fleet guest, a services-VLAN client and a VPN client each fail to open any connection to the tenant subnet. The workstation reaches only the approved ports.
4. **DNS:** a lease renewal on the tenant VLAN creates its record in the child zone and changes no fleet record. The tenant key is REFUSED outside its zone. The tenant issues a certificate by DNS-01 in its child zone with its own key.
5. **Infisical:** each runtime identity reads its own keys and is denied the admin project and `/shared`. A dry run of `refresh-identity.yml` with a test tenant identity selects nothing.
6. **PBS:** after the first nightly job, the tenant datastore holds snapshots of the test VM; the tenant token restores one to a scratch VMID; each token is denied listing and restoring the other's datastore; the PBS disk is absent from every storage the tenant can attach.
7. **Patching:** `make update` with no include runs as today; with the include, the tenant hosts appear in the resolved host list and are patched; with a wrong path, it fails.

### Phase 2: GPU release (after ms-01b returns)

Same sequence in both plans:
1. Check msi's configured guest memory covers the tenant GPU VM.
2. Add the second mapping to the tenant's `pci_mappings`; `make hosts-apply`.
3. The tenant creates its GPU VM **stopped**, with the mapping. Gate: created; the first card's mapping is denied.
4. Remove the second mapping from VM 240; `make apply` for VM 240; cold-start; chat answers on one card.
5. The tenant starts its GPU VM and runs a GPU job.
6. Failure return: stop the tenant VM, put the second mapping back on VM 240, apply.

## Test bar

Every gate's output is kept in the tenant's private repository, not here. Public PRs carry redacted assertions only ("the tenant token was denied a fleet VM"), and staged text is checked against the private binding values as well as the guardrail hook. Before each phase's PR: `make validate`, `make plan` and `make hosts-plan` showing only the intended resources, and a Codex adversarial review of the branch.

## Rollout and rollback

- **0a:** restore the recorded raw ids and `qm config` from `root@pam`, revert the commit, `make rebuild llm`. The model file is still on the data volume.
- **0b:** not reversible after deletion; each deletion follows the 0b.1 copy-or-discard record.
- **Phase 1:** no fleet guest changes except `refresh-identity.yml` and the PBS role split, both gated by CI-unchanged and dry-run checks. Removing the tenant binding plans the tenant resources' destruction.

## Operator decisions

1. Phase 0b (2026-11-27): discard the `codeintel` database and its secrets; no final dump.

## Review disposition (Codex, 2026-11-27, one pass)

| # | Finding | Disposition |
|---|---|---|
| 1 | Fleet vault backup holds tenant secrets and the key | Accepted as a stated limit: the Infisical instance is shared on purpose (ADR 0067), so fleet disaster recovery can read tenant secrets; ADR 0067 now says so. Recovery material moves to the tenant admin project and offline custody, and the hand-over is a project export. |
| 2 | Tenant DHCP can write the fleet zone | Fixed: 1.3 keeps the VLAN out of `zone_vlans`; gate 4 checks a real lease and tenant DNS-01. |
| 3 | No owner for the nightly tenant backup job | Fixed: 1.7 in the fleet root; gate 6 needs real snapshots and a tenant restore. The "skip tenant backup" option is removed. |
| 4 | PBS disk could be tenant-attachable | Fixed: 1.1 restricts initiators per target; 1.6 splits datastore creation from fleet grants; gate 6 checks absence. |
| 5 | Flux `prune: false` leaves code-intel running | Fixed: 0b.3 tears down through Flux and kubectl; 0b.1 decides data first; gate 2 checks absence. |
| 6 | GPU hand-off order is circular | Fixed: one Phase 2 sequence shared with the tenant plan. |
| 7 | Firewall never exercised | Fixed: flow table is a prerequisite; gate 3 tests fleet, services and VPN sources. |
| 8 | No tenant image upload path | Fixed: tenant image store in 1.2; gate 2 builds from empty state. |
| 9 | Pool rights allow containers | Partly: recorded as a convention in Scope and ADR 0067, with the attempt recorded in gate 2. No enforcement added. |
| 10 | One identity for provisioning and guests | Fixed: admin and runtime projects in 1.5; gate 5. |
| 11 | Identity cleanup can delete tenant identities | Fixed: 1.5 narrows `refresh-identity.yml` and bans the `-vm` suffix; gate 5. |
| 12 | Gate passes with embedder running or cards swapped | Fixed: 0a.6 rebuilds the guest instead of a cleanup task (greenfield rule); 0a gates 2 and 3. |
| 13 | Rollback cannot recover deletions | Fixed: 0a/0b split, recorded raw config, copy-or-discard before deletion. |
| 14 | Missing inventory skips patching silently | Fixed: 1.8 fails on a listed missing path; gate 7. |
| 15 | Evidence could leak tenant identity | Fixed: evidence lives in the tenant repo; public PRs carry redacted assertions; `hosts-plan` reviewed. |
