# ADR 0025 — PBS 4 rides a pinned Debian 13 cloud image, not the PBS ISO

- **Status:** Accepted
- **Date:** 2026-08-12
- **Deciders:** operator + agent
- **Context source:** session 2026-08-12 — operator noticed the fleet runs PBS 3.4.8 against an upstream 4.2

## Context

The fleet runs Proxmox Backup Server 3.4.8. Upstream is 4.2. Three facts constrain the response:

**The guest is Ubuntu, and PBS 4 is Debian-13-only.** `proxmox_backup` installs `proxmox-backup-server` from the *bookworm* `pbs-no-subscription` repo, unpinned, onto the fleet-default pinned Ubuntu **noble** cloud image. That works today only by forward-compatible glibc — bookworm-built binaries run on noble because noble's glibc is newer. PBS 4 is built against trixie, whose glibc is newer than noble's, so the direction reverses and the packages cannot resolve. Proxmox has never supported the PBS *server* on Ubuntu (only the *client* ships Ubuntu builds). There is no in-place upgrade path: PBS 3 → 4 here is a guest rebuild on a different OS, not an `apt dist-upgrade`.

**Nothing about the cluster migration requires it.** Proxmox explicitly supports backing up from PVE 9 to a PBS 3 server. Meanwhile ADR 0024's restore-bridge makes PBS the single load-bearing component of the cutover — the entire old fleet passes through it — and the pre-cutover VM-level backup pass has never run against production `pve`. Changing PBS's major version *and* its guest OS immediately before that is the worst available sequencing.

**Two install paths qualify.** Proxmox documents four; two fit a guest here — their installer ISO (which `proxmox-auto-install-assistant` can bake with an answer file, machinery this repo already has in `scripts/bake-answer.sh` / `make node-iso` for the PVE nodes), and "on top of a standard Debian installation", which is a first-class documented path rather than a workaround.

## Decision

PBS moves to 4.x as a **post-cutover (WP4) guest rebuild on a pinned Debian 13 generic cloud image**, keeping cloud-init and the existing `modules/proxmox-vm` provisioning model. The `proxmox_backup` role changes only its repo suite and key (`bookworm` → `trixie`); every other task — datastores, users, ACLs, API tokens, and the verify, GC and prune jobs — is untouched.

Do **not** upgrade before or during cutover. The migration proceeds on 3.4.8.

## Rejected alternatives

**In-place `apt dist-upgrade` on the existing guest.** Not possible, not merely inadvisable — trixie packages will not install on noble.

**Roll the fleet image to a newer Ubuntu so the glibc clears.** Would make the packages resolve and would still leave the PBS server on an unsupported base. Choosing the OS of the backup server to avoid pinning a second image is the tail wagging the dog. (Whether the *fleet* rolls off noble is a separate question with its own answer — see the WP4 image roll.)

**PBS installer ISO + baked answer file.** The reusable machinery is a genuine point in its favour, and it is the correct choice for the PVE nodes — bare metal on ZFS root. It is the wrong one for this guest. It costs cloud-init (the guest leaves the uniform `modules/proxmox-vm` model), needs a per-guest answer file carrying root password and network config (gitignored, like the node ones), replaces ADR 0016 image pinning with ISO pinning for exactly one guest, and makes rebuild-as-routine a special case. What it buys is the Proxmox kernel and ZFS — and this guest has no ZFS: the datastore is ext4 on an iSCSI LUN from the Synology and the local disk is a 20 GB rootfs. Paying uniformity for a kernel feature the VM does not use is a bad trade.

**A second PBS instance for host-failure redundancy.** Considered and rejected as a *response to this problem*. PBS 4 has no HA or clustering; replication is remote sync jobs (pull preferred — the secondary holds the credentials, so a compromised primary cannot reach it). But in the new cluster PBS is a VM on 3-node Ceph, so HA restarts it elsewhere and host death is no longer PBS death; `backup_jobs.pbs-self` already backs the PBS guest up to `nas-nfs` rather than to itself. The residual single point of failure is the Synology holding the datastore, and a second PBS VM against that same NAS addresses none of it. The real answer is a second *copy of the data* — a pull-sync secondary on separate storage, or PBS 4's S3 datastore backend to an offsite bucket — which is follow-on work enabled by this rebuild, not a reason to build a second server now.

## Consequences

- **First per-guest OS image override in the repo.** Requires a second pinned image variable (Debian 13 generic cloud, URL + checksum per ADR 0016) and plumbing an image override through `modules/proxmox-vm`. Every other guest stays on the fleet default.
- **The datastore is the asset and it survives.** The iSCSI LUN on the Synology is untouched by the guest rebuild, consistent with the plan's "portable datastore" framing. The rebuild is a guest replacement, not a data migration.
- **Migration risk stays where it was.** Cutover runs on 3.4.8 against PVE 9, a supported combination. The higher-value pre-cutover work is proving the VM-level backup pass on production `pve`, not the version number.
- **Unblocks the offsite question.** PBS 4's S3 datastore backend becomes available, which is the most credible shape for real backup redundancy. That decision stays open and gets its own ADR.
- **The role can no longer produce a 3.x once rolled.** After the suite swap, `make build proxmox-backup` against a noble image would fail rather than silently install PBS 3 — the image override and the repo suite must land together.

## Validation (W6, 2026-08-12)

Built on worklab before WP4 depends on it — [W6 results](../pre-migration-state/worklab-campaign-w6-results.md). The decision holds unchanged; three things it did not anticipate:

- **PBS 4.2.5 installs and the full role runs green and idempotent on a Debian 13 cloud image**, so the "rebuild, don't upgrade" premise is confirmed rather than assumed.
- **Debian 13 removed `apt-key` and ships no `gpg`**, so `ansible.builtin.apt_repository` aborts before reading the repo line. The role now uses `deb822_repository`. Any other role pointed at a Debian guest inherits this constraint.
- **The bigger portability risk was `pbs_client`, not the server.** Suite choice is driven by libfuse (bookworm→`libfuse3-3`, trixie→`libfuse3-4`), which is what actually decides installability on a given guest OS. Both roles now carry a suite variable defaulting to `bookworm`.
