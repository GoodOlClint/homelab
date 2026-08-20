# ADR 0028 — Greenfield-replace builds final-form guests beside the restored copies under VMID old+100, after pruning the fleet state of every proxmox resource

- **Status:** Accepted
- **Date:** 2026-08-20
- **Deciders:** operator + agent
- **Context source:** Day 3 cutover session — first greenfield replacement (adguard) against the 3-node cluster

## Context

The restore-bridge ([ADR 0024](0024-cutover-rides-a-restore-bridge-restore-the-old-fleet-onto-the-2-node-pve-9-cluster-rebuild-pve-early.md)) is complete: 16 restored guests (VMIDs 100–117) run on `ceph-rbd` across ms-01a/ms-01b and are the live services. They keep their pre-cutover shapes (dual-homed, unpinned, no data volumes) and were placed by hand, outside Terraform.

The fleet root's state still describes the *old* fleet: every `proxmox_*` resource carries `node_name = "pve"`, `local-ssd` disks and `local` snippets. Measured 2026-08-20 with a read-only `terraform plan -refresh-only` against the VIP: the bpg provider crashes on every such resource (`Plugin did not respond` ×18, `hostname lookup 'pve' failed`), the backup jobs and PCI mapping are gone, and the plan never completes. `make build <guest>` ends with a full `terraform apply -refresh-only`, so no per-guest build can succeed while those entries exist. Even if refresh worked, bpg reconciling `started = true` on a restored VMID would be the foot-gun the bridge rehearsal already hit (MAC/IP conflicts from restarting stale copies).

The design end state ([rebuild-as-routine](../rebuild-as-routine-design.md), ADRs 0015–0017, 0020) is a *new* fleet, not a migrated one — the restored copies were always scaffolding.

## Decision

1. **Prune the fleet state of every `proxmox_*` resource** once, before the first replacement: archive `terraform.tfstate` to the gitignored `docs/pre-migration-state/`, then `terraform state rm` all VMs, snippets, images, SDN zones/VNETs/applier, backup jobs and the PCI mapping. Vultr and Cloudflare resources stay — they are live and correct. The restored copies become unmanaged artifacts Terraform has never heard of: from here a blind `terraform apply` can only *create*, and a create against a VMID a restored copy holds fails on the PVE side instead of replacing or restarting anything. The full fleet plan is therefore expected to show create-all until the last guest is replaced; nobody tries to make it converge.
2. **Final-form guests take VMID = old VMID + 100** (adguard 102 → 202, infisical 105 → 205, …); the holder stays 900. The restored copy and its replacement coexist, so the VMID cannot be reused, and old+100 keeps the mapping readable in `qm list` and in PBS. MAC bytes derive from the VMID and stay unique.
3. **Per-guest swap, one guest at a time via `make build <guest>` (targeted):** build the replacement → seed/restore state per the plan's Stateful-data checklist → verify it serves → **`qm shutdown` + `onboot 0` on the restored copy, never destroy** → destroy later in the decommission sweep once the replacement has survived a week of real traffic. For a guest whose identity is a fixed IP the fleet depends on (adguard at `.40.53`), the replacement is first built at a scratch offset beside the running copy, verified, and only then rebuilt at the real offset after the copy is stopped — the two never hold the address together.
4. **Cutover tfvars land with the first replacement:** endpoint → VIP, `virtual_environment_storage` → `cephfs` (shared — snippets and images no longer pin a guest to the upload node), `primary_disk_storage` → `ceph-rbd`, `proxmox_nodes` → the three nodes, `guest_access_plane` → `services` (ADR 0017: `ansible_host` becomes the services address; the restored dual-homed guests carry that leg too, so inventory stays valid for them). SDN zones re-home to the nodes' `vmbr0` (bindings change in `vlans.yaml`, where the old `vmbr1` interim hack lived).

## Rejected alternatives

- **`state rm` + re-`import` each restored guest into its resource** — imports the *wrong* shape (dual-homed, unpinned, local snippets) and the very next plan proposes an in-place replacement of the running copy; bpg containers must never be imported at all (W1 finding). Buys nothing over building new.
- **Prune only the guest being replaced** — every other node=pve entry still crashes the refresh that `make build` ends with, so each of the remaining 15 guests needs the same surgery first. Same end state, spread over 16 sessions.
- **Reuse the old VMIDs** — requires destroying the restored copy before its replacement exists, removing the 30-second rollback (`qm start <old>`) that makes the swap safe to run unattended.
- **Keep `local` for snippets/images** — a node-local datastore ties every guest to the upload node (`virtual_environment_node`) or fails the cloud-init attach on any other node; `cephfs` already exists with `snippets,iso` content.

## Consequences

- Restored copies are stopped, not destroyed — ceph-rbd holds both rootfs images until the decommission sweep; a stopped copy is restartable in seconds if a replacement misbehaves.
- `backup_jobs` in `vars.auto.tfvars` must be re-authored for the new VMIDs and re-applied once the replacements exist (the old jobs are gone with the old cluster; PBS storage `pbs` already exists on the new one).
- CLAUDE.md's "SSH uses vlan10" / prefix-translation conventions are amended at WP7 as ADR 0017 foresaw; until then `ansible_host` is already the services address for every guest and `replace(mgmt_vlan_prefix, …)` calls are no-ops.
- AdGuard rewrites (`<vm>.core.<domain>`) now answer services-VLAN addresses instead of management ones; the restored guests hold both, so nothing breaks, and the management answers were always going away (ADR 0017).
