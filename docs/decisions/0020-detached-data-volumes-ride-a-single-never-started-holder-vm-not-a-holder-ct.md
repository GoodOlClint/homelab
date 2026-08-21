# ADR 0020 — Detached data volumes ride a single never-started holder VM, not a holder CT

- **Status:** Accepted
- **Date:** 2026-08-10
- **Deciders:** operator + agent
- **Context source:** Worklab validation campaign W1 (docs/pre-migration-state/worklab-campaign-w1-results.md)

## Context

ADR 0015 parks every detached data volume on a never-started holder guest so that rebuilding a consuming guest never deletes its data. The original mechanism was a holder **CT** (VMID 900), chosen because PVE formats CT volumes at creation. W1 validation against a real PVE 9 API falsified the append path: bpg marks any container `mount_point` change "forces replacement" (upstream [#1392](https://github.com/bpg/terraform-provider-proxmox/issues/1392), acknowledged, parked for v2.0), so once the first volume exists, no volume can ever be added through Terraform — the plan proposes destroying the holder, which `protection=1` blocks (proven live). The fleet's volume set will grow with every new stateful service; an append-hostile holder is unusable. Separately, the operator rejected UI clutter from multiplying holder guests.

bpg's own VM documentation recommends the same holder shape with a never-started **VM** ("attached disks" example). W1 probes on worklab proved the two facts the switch depends on: adding a `disk` block to an existing stopped VM plans as an **in-place update**, and an LXC `mount_point` can attach a VM-owned raw volume once its filesystem exists and its root is chowned to the container-mapped owner (a raw `mkfs` leaves host-root ownership; PVE's CT-volume path had been doing that chown implicitly).

## Decision

The data-volume holder is a single never-started, never-booted **VM** (`vm_id = data_volume_holder_vmid`, `started=false`, `on_boot=false`, `protection` on, no OS image, no network): one `disk` block per entry in `data_volumes`, interface derived from the operator-assigned index. Consumers attach cross-VMID exactly as before — LXCs via `mount_point` with the holder volume ID, VMs via `datastore_id`/`path_in_datastore` — resolving the volume from the holder resource's computed attributes (safe for VMs: `path_in_datastore` is genuinely computed, unlike the CT read-back W1 disqualified). Appending a volume is a pure in-place holder update.

Each new volume requires a **one-time format step before its first consumer starts**: `mkfs.ext4` + `chown` of the filesystem root to the consumer's mapped owner (default `100000:100000` for unprivileged CT root). This is cluster-plane work and belongs with the node-side Ansible (same boundary as PVE storage entries); landed 2026-08-21 as `make data-volumes` (`ansible/playbooks/data-volumes.yml`, blkid-guarded; also removes `lost+found`, which a CT cannot own).

Volume indices remain unique and are never renumbered (the index names the disk slot); the contiguous-from-1 constraint is no longer load-bearing once attach resolves from holder state rather than list position.

## Rejected alternatives

- **Holder-per-volume CTs** (one never-started CT per volume, pool/VMID-corralled): keeps PVE's auto-format and pure-Terraform appends, but multiplies stopped guests in the UI (~1 per stateful service) — operator rejected on clutter; PVE has no way to hide guests, only corral them.
- **Single holder CT + Ansible-reconciled mount points** (`ignore_changes = [mount_point]`, `pct set` appends): keeps one guest and auto-format, but moves attach topology out of Terraform's plan visibility and puts two actors on one resource.
- **Raw first-class volumes** (`pvesm alloc` / raw RBD images): closest to the EBS/PVC industry shape, but PVE volumes must be VMID-owned (a guestless VMID is squattable and rescan-adoptable), vzdump/PBS backs up guests only — the volumes would fall out of the B3 backup lane entirely — and bpg has no standalone-volume resource ([#1465](https://github.com/bpg/terraform-provider-proxmox/issues/1465)).
- **Wait for bpg v2.0 mount_point fix**: open-ended timeline against a fixed cutover date.

## Consequences

- ADR 0015's principle (durable state on detached volumes; guest rootfs disposable) stands; its holder-CT mechanism is superseded by this ADR. The holder VM must never gain an OS disk, network device, or `started=true`.
- The proxmox-vm module replaces the holder CT with the holder VM; the B1 tftest is rewritten around index→interface mapping instead of mount-point list order. State migration: none needed — no real environment has data volumes yet; the worklab scratch holder is rebuilt.
- New-volume rollout order becomes: apply (holder gains disk) → format+chown → apply/start consumer. The format step is idempotent (guard on `blkid`) and lands in the cluster-plane Ansible (follow-up work item, plan 1.9 neighborhood).
- The holder VM's disks stay inside the PBS lane via the holder's backup job (B3 pins the holder VMID); W2 must show restore evidence for a stopped raw-disk VM.
- bpg's docs flag the pattern experimental and warn against moving/resizing holder disks: volume growth is a deliberate offline operation (resize + consumer config change together), never a routine apply.
- Terraform can never destroy the holder while `protection` is set (proven live on PVE); teardown requires an explicit `unprotect=true` apply first.
