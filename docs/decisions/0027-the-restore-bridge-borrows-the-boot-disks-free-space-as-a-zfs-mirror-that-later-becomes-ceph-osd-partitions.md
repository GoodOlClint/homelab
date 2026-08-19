# ADR 0027 — The restore-bridge borrows the boot disks' free space as a ZFS mirror that later becomes Ceph OSD partitions

- **Status:** Accepted
- **Date:** 2026-08-19
- **Deciders:** operator + agent
- **Context source:** Day 1 cutover session — first restore onto the new cluster had nowhere to land

## Context

The MS-01 answer file caps the ZFS boot mirror at `hdsize = 120` GiB on purpose: the two 1 TB Crucials' remaining ~810 GiB each was always meant to become Ceph OSD capacity alongside the whole-disk 2 TB Samsung per node (bindings note, 2026-08-16). That leaves a node with ~2 GiB free on `rpool` on Day 1.

ADR 0024's restore-bridge restores the old fleet (~316 GB of real data, 19 VMs) onto the MS-01s' local ZFS *before* msi joins — and Ceph cannot bootstrap until msi joins (a 2-node size-3 pool is rejected by the role; ADR 0024). So on Day 1–2 there is no Ceph to restore onto and no room on `rpool`: the bridge needs a local pool that exists today and disappears cleanly once Ceph is up.

Putting the bridge on the Samsungs instead is circular: Day 2's Ceph bootstrap needs those disks empty, but the VMs on them can only move once Ceph exists.

## Decision

Each MS-01 carves a fourth partition from each boot Crucial's free space and builds a ZFS mirror `bridge` on the pair (~800 GiB usable per node), registered as the PVE `zfspool` storage `bridge` restricted to the nodes that carry it. The `proxmox_host` role owns it (`tasks/bridge_pool.yml`, gated on the per-node `bridge_disks` binding — the two boot-disk by-id paths). The Samsungs stay untouched for the Day-2 Ceph bootstrap.

The loan is repaid after the bridge: once every interim disk has moved to Ceph (`qm move-disk`), the pool is destroyed and the same `-part4` paths are appended to each node's `osd_disks` — Ceph takes a partition as an OSD exactly like a disk, and the role's per-device OSD create is idempotent. Net Ceph capacity is unchanged; the Crucial OSDs simply arrive after the Samsung ones instead of with them.

## Rejected alternatives

- **Bridge on the 2 TB Samsungs** — blocks the Day-2 Ceph bootstrap until the disks are empty, which needs Ceph. Circular.
- **Bridge on the NAS (NFS/iSCSI)** — the old fleet already thrashes the single 10G NAS path during the final backup pass; restoring and then running 19 VMs over it doubles the load on the slowest link, and `qm move-disk` to Ceph later reads it all back again.
- **Widen `hdsize` so `rpool` holds the bridge** — a reinstall to change a boot pool we'd shrink again at WP4, and it permanently loses OSD space to a pool that only needs to exist for days.
- **Keep the Crucial space as permanent local scratch** — rejected as the default; the bindings already promise it to Ceph. If a node-local scratch pool ever earns its place, it is a separate decision.

## Consequences

- `host-bindings.yaml` gains `nodes.<node>.bridge_disks` (two by-id paths); `make proxmox-hosts` is idempotent on the pool and the storage entry (a second run changes nothing).
- Restored guests land on `bridge` with their storage NIC back at MTU 9000 (the MS-01 `vmbr0` is jumbo); the Day-2 kickoff carries the move-to-Ceph → `zpool destroy bridge` → append `-part4` to `osd_disks` → `make proxmox-hosts` sequence.
- ZFS cannot shrink a vdev: the 120 GiB boot cap is the split until the next rebuild, which ADR 0015/0016 make routine.
