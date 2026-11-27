# ADR 0067 — The homelab hosts tenant enclaves through a fixed set of interface edges

- **Status:** Accepted (operator, 2026-11-27)
- **Date:** 2026-11-25
- **Deciders:** operator + agent
- **Context source:** design session 2026-11-25; Codex design review 2026-11-25. The tenant's own design lives in the tenant's private repository, not here.

## Context

The operator wants to run a bounded tenant on the shared cluster: workloads that must separate cleanly from the homelab so they can be handed to a different owner later, on the same hardware (no dedicated node), administered by the same operator. The tenant's shape (its guests, storage design, backups) must stay out of this public repository. The CI pool ([ADR 0032](0032-ci-runners-are-ephemeral-and-build-their-own-guests-inside-a-pve-pool-on-an-isolated-vlan-and-the-mac-studio-is-a-separate-trust-tier.md), [ADR 0064](0064-the-ci-cluster-nodes-sit-on-a-dedicated-ci-runner-vlan-filtered-at-pfsense.md)) is the existing pattern for a bounded tenant. A Codex review of the first draft found places where homelab mechanisms would silently cross the line: the fleet PBS token's datastore-wide admin rights, the fleet holder VM's backup, the one-login-per-run Ansible loader, raw PCI passthrough needing `root@pam`.

## Decision

The homelab provides a tenant exactly these edges and nothing else. The tenant's name, VLAN id, VMID range and addresses are **bindings** (gitignored, like `vlans.yaml`); the tenant's IaC, state and inventory live in its own repository.

| Edge | Homelab provides | Rule |
|---|---|---|
| Proxmox | a pool, a pool-scoped API token, a VMID range, a tenant-only image store | The tenant builds its guests with its own Terraform root and state, as CI guests are built. The VMID range and "VMs only, no LXCs" are tenant conventions checked by the tenant's own validation: Proxmox has no per-pool VMID ACL, and pool rights also allow containers. |
| PCI | named resource mappings for devices released to the tenant | `Mapping.Use` on the named mapping only; never raw `hostpci` by address. |
| Network | a VLAN filtered at pfSense | Default deny to every internal network. Allowed tenant → homelab: DNS, apt-cache, the registry pull-through, Infisical, the ACME endpoint (`cert_client`), PBS, authentik's outpost, one-way metrics push. Homelab guests → tenant: nothing. Operator's workstation → tenant: SSH and the tenant's named service ports. Internet egress allowed. Every flow is named (source, destination, port, identity) in the tenant's change plan and exercised behind the final rules. |
| DNS | a BIND child zone with its own scoped TSIG key | The CI zone pattern: the key is REFUSED outside the child zone. |
| Infisical | separate tenant projects (admin and runtime) and identities, none named `*-vm` | No tenant secret in the homelab project, no homelab secret in the tenant's. Fleet identity cleanup touches only homelab-project members. Tenant Ansible never runs in the same invocation as fleet plays (the loader caches one login and one `secrets` fact per run). |
| PBS | a separate datastore on its own NAS LUN, a backup-only credential scoped to it, its own PVE storage entry, and a nightly backup job in the fleet root (creating a job needs `Sys.Modify` on `/`) | The fleet token gets no rights there; the tenant credential none on the fleet's. The PBS LUN is attachable only by the PBS guest. Gate: each is denied listing and restoring the other's backups. |
| Durable volumes | nothing: the tenant keeps its own never-started holder VM in its pool | Exception to [ADR 0020](0020-detached-data-volumes-ride-a-single-never-started-holder-vm-not-a-holder-ct.md): the fleet holder VM 900 never holds a tenant disk. |
| NAS | dedicated iSCSI targets/LUNs and a NAS user | Tenant data is never written to homelab shares, the fleet's Ceph volumes or homelab offsite buckets. A tenant LUN attached to a VM carries `backup=0` unless the tenant ADR says otherwise. |
| Auth | a group-gated authentik application per tenant web UI | No public DNS record ([ADR 0044](0044-a-declared-ingress-mode-per-service-drives-the-public-dns-record-and-nothing-else.md) mode `none`). |
| Patching | a tenant-inventory hook on `make update` | `make update` adds the tenant's generated inventory when its gitignored path is bound; the guest update play loads no secrets. |
| SSH | the operator's key through cloud-init | Same key as the fleet until the tenant has its own administrator. |

- **Shared on purpose:** Proxmox, Ceph (tenant VM disks only), the NAS, pfSense, the PBS server, Infisical and authentik instances, and the operator as administrator of all of it. The tenant is not hidden from its hypervisor's administrator and this ADR does not claim it is. In particular, the Infisical instance's own backup (database and encryption key, to fleet PBS) contains the tenant projects, so fleet disaster recovery can read tenant secrets; the hand-over is a project export, and tenant recovery material is also held offline.
- **Hand-over test:** a tenant can be taken away without being given a homelab credential: restores from its own PBS target, LUN copies, an Infisical project export, its own repository and accounts.
- **Capacity is booked, not observed:** a tenant guest is placed against configured guest memory and OSD reservations, not instantaneous usage.

## Rejected alternatives

- **Tenant guests in the fleet Terraform root and `vms.yaml`.** Puts the tenant's shape in this public repository and its state in the fleet's.
- **A folder in the homelab Infisical project.** The hand-over would mean untangling shared secrets.
- **The fleet PBS token and namespace.** The token holds `DatastoreAdmin` at the datastore root; rights would cross in both directions.
- **Tenant disks on the fleet holder VM 900.** Puts tenant data in the homelab backup and makes a tenant-only restore impossible.
- **The Talos services cluster.** Namespaces are a weaker hand-over unit than VMs, and bulk tenant I/O does not belong beside the control-plane etcd.
- **A dedicated node.** Cleanest line; rejected by the operator.

## Consequences

- Homelab build work per tenant: the binding entries, the VLAN (UniFi, pfSense rules), the pool and token, the child zone and key, the Infisical project and identity, the PBS target, any NAS target and PCI mapping, the `make update` hook. It goes through the brownfield gate as one change plan.
- The tenant-inventory hook is the only Makefile change; no tenant name appears in tracked files.
- `pbs_client` and the backup-job wiring gain a way to target a non-fleet PBS storage entry, or the tenant brings its own client config.
- A second tenant reuses these edges; it does not need a new ADR unless it needs a new edge.
