# ADR 0009 — worklab joins the cluster as a non-voting, compute-only member

- **Status:** Proposed (future work — executes at the worklab rebuild, after the MS-01 migration)
- **Date:** 2026-07-15
- **Deciders:** operator + agent
- **Context source:** ADR-0001 (rejected worklab as a 4th node) · docs/ms01-cluster-iac-plan.md · live worklab inventory 2026-07-15
- **Amends:** ADR-0001

## Context

ADR-0001 rejected worklab as a fourth node: *"puts a reboot-often lab box in production quorum for no gain; PDM covers the single-pane want."* Two of those premises have since been corrected:

1. **The reliability premise was wrong.** worklab's outages were accidental power disconnects caused by the current messy rack — not instability. The closet rebuild removes that cause. It is not a "reboot-often" box.
2. **The driver was never single-pane.** The operator's actual goal is **scaling out multi-version work labs**: the company ships new product versions, and support requires running several versions concurrently (each lab = a multi-VM set — RootDC1/2, ChildDC, App, SQL, per the existing `DSP5.2-*` / `HS-*` / `ADFR-*` guests). That needs pooled capacity and one IaC endpoint. ADR-0001 weighed neither.

The quorum objection, however, survives independently of reliability: **3→4 nodes adds zero fault tolerance** (both tolerate exactly one failure), and an even node count introduces 2-2 split-brain ties that three nodes cannot have.

Verified worklab hardware (2026-07-15): ASUS NUC 15 Pro (NUC15CRH), Core Ultra 7 255H (16 cores), 100.5 GB RAM (platform max), PVE **9.2.4** (same major as the cluster), native **Intel I226-V 2.5G**, **OWC Thunderbolt 10G (Aquantia AQC113)**, and a **single 2 TB NVMe** (one M.2 slot populated; a second is likely available). Bulk VM storage today is an **HDD-backed NAS iSCSI LUN** — the exact pattern ADR-0001 ruled out as a VM SAN.

## Decision

worklab joins the cluster as a **non-voting, compute-only member**, at its rebuild:

- **`quorum_votes: 0`** in `corosync.conf`. It gains cluster membership, shared config, migration, and a single API endpoint, but **never participates in production quorum** — preserving the clean 3-node quorum and avoiding even-node ties.
- **Corosync rides the native I226-V 2.5G on VLAN 31** — **never** the Thunderbolt adapter. Cluster membership then survives any TB re-enumeration.
- **No Ceph OSDs on worklab** (single disk, none to spare). It is a **Ceph client only**, which requires Ceph's **`public` network on the 10G fabric** and the **`cluster` (replication) network on the 25G mesh** — see WP2. The 3-node switchless mesh cannot extend to a 4th node.
- **Directional workload policy, enforced in config:** homelab HA resources are pinned to HA groups/rules **restricted to `crete`, `crete2`, `pve`** so they can never fail over to worklab. Work-lab guests may run anywhere, including worklab. Terraform `node_name` sets initial placement.
- worklab is added to `terraform/hosts` and the Ansible `proxmox` inventory group like any node.

## Rejected alternatives

- **Leave worklab standalone (status quo, ADR-0001).** Still valid for the *original* premises, but it forces two Terraform endpoints and two capacity pools, which is precisely the friction the multi-version lab goal is trying to remove.
- **Join as a full voting member.** No fault-tolerance gain, plus even-node split-brain ties — pure downside versus `quorum_votes: 0`.
- **Contribute OSDs from worklab.** Only one 2 TB NVMe; donating it costs local lab storage, and a TB-attached data path makes it a poor OSD host (rebalance churn on any flap).
- **Extend the 25G switchless mesh to worklab.** A triangle does not extend to four nodes without a 25G switch, and the NUC has no free PCIe slot — hence Ceph client over 10G instead.

## Consequences

- **WP2 must split Ceph `public` (10G fabric) from `cluster` (25G mesh) at bootstrap.** Retrofitting a public-network change onto a live Ceph cluster is painful, so this is decided now even though worklab joins later.
- The **Thunderbolt 10G is worklab's weakest link** (TB tunnels can re-enumerate on disturbance or fail to come back if unpowered at boot). Contained by design: a flap costs only worklab's own lab VMs — not quorum (0-vote), not Ceph (no OSDs), not homelab workloads (HA-restricted). Mitigations: set the BIOS TB security level so the adapter auto-authorizes headlessly, and MAC-pin it.
- worklab is **not** a peer for HA-critical workloads: single 10G path (no LACP bond), single disk, RAM at platform max.
- A **second M.2** in the NUC would reduce NAS-iSCSI dependence for lab scratch — worth doing before scaling lab versions, since HDD-backed iSCSI is the likely bottleneck.
- The larger lever for the stated driver remains **above** the cluster: an IaC lab-environment module parameterized by product version, SDN-isolated VNets per lab, and templates/linked clones. Clustering supplies capacity; automation supplies manageability.
