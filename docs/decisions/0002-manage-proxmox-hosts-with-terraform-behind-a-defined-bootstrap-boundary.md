# ADR 0002 — Manage Proxmox hosts with Terraform behind a defined bootstrap boundary

- **Status:** Proposed
- **Date:** 2026-07-10
- **Deciders:** operator + agent
- **Context source:** docs/ms01-cluster-iac-plan.md · docs/audit-2026-07-07.md (PVE host unmanaged gap)

## Context

The Proxmox hosts themselves have never been in IaC — host networking, users, ACME, and backup jobs are hand-configured (audit gap). The operator wants the MS-01 nodes "managed via Terraform from the beginning." bpg/proxmox v0.111 covers host networking (`network_linux_bond/bridge/vlan`), cluster options, SDN, storage, Ceph pools, HA, and IAM — but not the PVE install itself, `pvecm` cluster membership, Ceph daemon bootstrap (`pveceph`, MON/MGR/OSD), FRR, or keepalived.

## Decision

Host lifecycle splits at a fixed boundary. (1) **Install:** a committed `proxmox-auto-install` answer file per node (`answer-<node>.toml`) produces an unattended PVE 9 install with the initial mgmt IP on the 2.5G i226; a single bootstrap step creates the `terraform@pve` token. (2) **Terraform** owns everything the API exposes, in a new root **`terraform/hosts/`** with its own state: bonds, VLAN-aware bridges, VLAN interfaces/MTU, cluster options, SDN (all nodes), storage definitions, Ceph pool, HA, ACME, users/tokens. Host-networking applies always run over the stable 2.5G mgmt link, never over an interface being reconfigured. (3) **Ansible** (new `proxmox_host` role) owns what the API can't: `pvecm` create/join, temporary QDevice, `pveceph` install + MON/MGR/OSD, FRR OpenFabric mesh, keepalived VIP.

## Rejected alternatives

- **All host config in Ansible (ifupdown2 templates etc.)** — contradicts the operator's explicit Terraform-first requirement and forfeits plan/diff on host networking.
- **Everything in the existing single Terraform project** — host plane must exist before the fleet; separate state keeps a connectivity-breaking host apply from holding the fleet state hostage and keeps routine fleet plans fast.
- **Manual PVE install per runbook checklist** — not reproducible from git; the answer file is the "from the beginning" story.
- **Adopt the existing 9.2.3 installs via import** — inherits unknown manual state; wipe is cheap since their VMs are disposable.

## Consequences

- New artifacts: `terraform/hosts/` root, per-node answer files, a node-bootstrap make target, Ansible `proxmox_host` role, a multi-node `proxmox` inventory group (replacing the single-host `inventory/proxmox.yaml` and the hardcoded `proxmox_host` in `group_vars/all.yml`).
- Two-stage apply ordering becomes part of the operating model: `hosts/` (rare) before `terraform/` (routine); Makefile encodes it.
- CLAUDE.md gains: "Never reconfigure host networking over the interface carrying the PVE API session."
- The bootstrap token step is the one unavoidable hand-off; it is documented, minimal, and idempotent.
