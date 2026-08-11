# ADR 0024 — Cutover rides a restore-bridge — restore the old fleet onto the 2-node PVE 9 cluster, rebuild pve early

- **Status:** Accepted
- **Date:** 2026-08-11
- **Deciders:** operator + agent
- **Context source:** Day-1 walkthrough session, 2026-08-11 (operator proposal, refined)

## Context

The plan's original Day 1–2 order gated the pve wipe on the greenfield backbone: build the 2-node cluster, greenfield-rebuild adguard/infisical/dns/unifi on it, cut each service over, and only when "nothing left is needed on pve" wipe and rejoin it. That couples the pve rebuild (and therefore Ceph formation, which needs all three nodes) to the pace of the whole backbone cutover, and keeps the old fleet running on a host we already want gone (KSM bug, vGPU-tainted kernel).

The operator proposed inverting it: get all three hosts rebuilt first, carry the old VMs across, greenfield-replace afterwards. The literal version — create the cluster on the existing PVE 8 node and join freshly-installed PVE 9 nodes into it — founders on version support: Proxmox sanctions mixed-major clusters only as the transient state of an in-place rolling upgrade; joining new nodes across a major version is unsupported, and the cluster config would be born on the tainted host besides.

The supported route to the same goal already exists in the plan's own machinery: PBS backups of the old fleet land on a Synology-backed datastore that survives every host rebuild, and the restore path was verified in WP0.

## Decision

Day 1–2 runs as a **restore-bridge**:

1. Build the 2-node PVE 9 cluster (answer-file installs → `hosts/` apply → `proxmox_host` role, temp QDevice) exactly as planned.
2. Take the final PBS backup pass of the old fleet on pve, then **restore the old VMs as-is onto the MS-01s' local ZFS**, stopping each old VM on pve as its restored copy comes up (avoids static-IP conflicts). Retiring VMs (lancache, and anything else already condemned) are not restored.
3. Verify the restored fleet runs on the new cluster; pve then has nothing left → wipe pve, answer-file install, join (third node), drop QDevice, bootstrap Ceph across all three, VIP up, endpoint repointed.
4. Move interim disks to Ceph and **greenfield-replace services at leisure** — the restored VMs are a longer-lived bridge, not the end state; ADRs 0015–0017 still govern what each service becomes.

## Rejected alternatives

- **Mixed PVE 8/9 cluster** (cluster on pve8, join PVE 9 nodes, live-migrate, rebuild pve): unsupported across major versions — the only sanctioned mixed state is a transient in-place rolling upgrade; new-node joins across majors are untested territory, and pve would need hand-retrofitted corosync ring VLANs so the cluster config could be created on the host we trust least.
- **Keep the original order** (greenfield backbone first, pve wiped last): safe but couples the pve rebuild and Ceph formation to the full backbone cutover; the old fleet keeps running on the tainted host for the duration, and Day 1–2 carries rebuild-everything time pressure.
- **In-place pve8to9 upgrade of pve first**: puts the tainted kernel/host in the cluster's founding position; the whole point of the migration is a greenfield host rebuild.

## Consequences

- The plan doc's sequencing table (Day 1–3) is rewritten to this order in the same change window.
- Interim capacity check enters the Day-0 checklist: old fleet is ~1.4 TB *provisioned* (thin; actual usage smaller, retiring VMs excluded) — verify actual usage vs the MS-01s' free ZFS before the restore pass.
- The restored VMs keep their dual-homed vlan10/vlan40 networking during the bridge, so those VLANs must be live on the MS-01 trunks (WP5 port profiles) before restores start.
- The 2-node + QDevice window now covers the restore/verify period instead of the backbone rebuild; the QDevice prerequisite (external qnetd + `cluster.qdevice_addr` binding) is unchanged.
- Rollback shifts: once a restored copy is verified and its original stopped, the restored VM *is* production; until the pve wipe the originals still exist stopped on pve as a fallback.
- `make bootstrap` / greenfield backbone work moves after Ceph formation and loses its time pressure; fleet tfvars are still written at cutover per WP4 (unchanged).
