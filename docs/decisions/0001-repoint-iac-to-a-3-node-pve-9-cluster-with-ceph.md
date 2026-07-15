# ADR 0001 — Repoint IaC to a 3-node PVE 9 cluster with Ceph

- **Status:** Proposed
- **Date:** 2026-07-10
- **Deciders:** operator + agent
- **Context source:** ~/okf/playbooks/ms01-cluster-migration.md · ~/okf/brainstorm/ms01-cluster-network.md · docs/ms01-cluster-iac-plan.md

## Context

The repo targets a single Proxmox node (`pve`, PVE 8.4) — one endpoint, one `node_name` threaded through every module, node-local `iscsi-ssd-lvm`/`local` storage, SDN zones bound to that node. `pve` runs NVIDIA GRID vGPU whose out-of-tree driver taints the kernel and has crashed the host (KSM `BUG_ON`). Two Minisforum MS-01 nodes (`crete`, `crete2`, PVE 9.2.3) hold only disposable VMs. Single node = no HA, no maintenance without full-homelab downtime.

## Decision

The IaC target is a 3-node PVE 9 cluster — `crete` + `crete2` (MS-01) + rebuilt `pve` (MSI) — with Ceph `size=3, min_size=2` on local NVMe over a 25G switchless FRR mesh as the VM/LXC disk store. Every guest gets an explicit `node_name`; Ceph-backed guests get HA resources. Terraform and Ansible talk to a keepalived VRRP VIP on VLAN 40 (DNS name kept in the gitignored bindings), not a node IP. *(Amended by ADR-0008: the VIP/endpoint moved to VLAN 30, with host mgmt.)* Cloud-init snippets move to a small CephFS datastore. The Synology stays media + PBS datastore + ISO/templates only — never the VM SAN. Worklab stays standalone; PDM (not corosync) provides the single management pane over cluster + worklab.

## Rejected alternatives

- **Join pve to the MS-01 cluster as-is** — PVE doesn't cluster across major versions (8.4 vs 9.2); pve must be rebuilt anyway.
- **Synology as shared VM storage (iSCSI/NFS)** — HDD random IOPS already bottlenecked a single VM; three nodes of VMs is strictly worse. 10G moves throughput, not IOPS.
- **ZFS local + scheduled replication instead of Ceph** — simpler, but async (data-loss window on node failure) and retrofitting Ceph onto a running cluster is far harder than building it in day one; the 25G mesh hardware is ~$270 and already purchased.
- **Worklab as a fourth/voting node** — puts a reboot-often lab box in production quorum for no gain; PDM covers the single-pane want.
- **Per-node endpoints in provider config instead of a VIP** — IaC breaks whenever the named node is down; the VIP + pveproxy forwards to any live node.

## Consequences

- Provider bump `bpg/proxmox ~> 0.78` → `~> 0.111`; `vm_configurations` schema gains `node_name`/`ha`; SDN `nodes` lists all three; default disk storage becomes the Ceph RBD pool.
- New keepalived + FRR + Ceph bootstrap responsibilities land in Ansible (ADR 0002).
- The LLM VM (GPU passthrough) is pinned to `pve` and excluded from HA; vGPU and its `nvidia-licensing` VM are retired (ADR 0004).
- LXCs restart-migrate only (no live migration) — availability-critical services accept a seconds-long blip on host maintenance, or stay VMs.
- Ceph replication is not a backup: PBS (VM on cluster, datastore on NAS) remains mandatory.
