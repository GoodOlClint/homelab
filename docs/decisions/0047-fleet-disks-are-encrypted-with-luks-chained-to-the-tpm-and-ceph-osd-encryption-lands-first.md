# ADR 0047 — Fleet disks are encrypted with LUKS chained to the TPM and Ceph OSD encryption lands first

- **Status:** Proposed — intent settled, install mechanism open (see §Open questions)
- **Date:** 2026-08-29
- **Deciders:** operator + agent
- **Context source:** constrained by [ADR 0026](0026-bare-metal-nodes-install-over-pxe-from-a-fleet-guest-answer-files-served-over-http-secure-boot-stays-on.md) (PXE installs, Secure Boot) and the shim+grub conversion recorded in CLAUDE.md · touches the Ceph layout of [ADR 0009](0009-worklab-joins-the-cluster-as-a-non-voting-compute-only-member.md) / [ADR 0014](0014-ceph-cluster-network-rides-switched-25g-sfp28-ports-not-a-switchless-mesh.md) · blocked on the msi RMA

## Context

Nothing in the fleet is encrypted at rest. Measured 2026-08-29: all 8 Ceph OSDs report `encrypted 0`, and the PVE root is an unencrypted ZFS mirror (`nvme2n1p3`, `zfs_member`, 120 GiB pool).

TPM 2.0 is present and usable on every live host — ms-01a, ms-01b and worklab all expose `/dev/tpm0` with `tpm_version_major = 2` at ACPI ID `MSFT0101`. The MS-01 has no TPM header, so this is Intel PTT firmware TPM. **msi could not be verified** — it is powered off for the CPU RMA; its board and 14900K support PTT but this is inference, not measurement.

Two beliefs about the blocker needed correcting before the decision could be framed:

- **Secure Boot is not the obstacle to a rebuild.** The PXE flow already handles it: iPXE under Secure Boot refuses the Proxmox-CA-signed installer kernel (ADR 0026), so installs run with SB off and the node is converted to shim+grub and re-enabled afterwards. That sequence is proven on both MS-01s (2026-08-28).
- **The actual obstacle is the installer.** The `proxmox-auto-install` answer schema has no encryption option in `[disk-setup]` under any filesystem. It cannot produce an encrypted root, regardless of boot mode.

A third correction shapes the threat model. **TPM auto-unlock does not protect a stolen machine that the thief simply boots** — the TPM unseals for anyone who powers it on with the expected PCR state. TPM-sealed FDE protects against drive removal, offline access and disposal. It does not, on its own, protect against node theft. Unattended boot and theft resistance are in direct tension, and no configuration delivers both from the TPM alone.

## Decision

1. **Full disk encryption is the goal for the fleet.** Intent is settled; §Open questions records what is not.
2. **LUKS is the primitive, not ZFS native encryption.** `systemd-cryptenroll --tpm2-device` is first-class for LUKS; ZFS native encryption has no TPM integration and would mean a hand-rolled unseal script in the initramfs. Where ZFS features are wanted, the pool is created **on top of** a LUKS device (`zpool create rpool /dev/mapper/…`), which keeps snapshots and rollback intact.
3. **Ceph OSD encryption lands first and independently.** `pveceph osd create --encrypted` uses dm-crypt with keys held in the **Ceph mon config-key store**, fetched automatically at OSD activation — no TPM, no passphrase, no PCR policy, no boot fragility. Migration is destroy-and-recreate one OSD at a time letting Ceph backfill, which is the existing rebuild-as-routine shape.
4. **OSD encryption alone is honestly scoped to drive disposal, not theft.** The OSD unlock keys live in the mon store on the unencrypted root, so a whole-node compromise still yields the data. This is stated so the partial win is not mistaken for the full one — and with msi out for RMA, drive disposal is the concrete, present threat.
5. **Root encryption requires a reinstall**, and the natural moments are taken rather than manufactured: worklab first as the proving ground, then **msi on its RMA return** (it needs a reinstall anyway), then ms-01a and ms-01b one at a time with Ceph backfill between.
6. **TPM enrolment happens after the Secure Boot conversion, never during install.** PCR7 measures Secure Boot state; sealing before the shim+grub conversion and SB enable would bind to a state the node is about to leave.
7. **A recovery passphrase is always enrolled alongside the TPM keyslot.** Non-negotiable: a firmware update, a TPM clear or a bootloader change otherwise bricks the node.
8. **Nothing starts until the cluster is healthy and msi is back.** Current state is `HEALTH_WARN`, 1/3 mons down, 2 OSDs down, 33% of objects degraded, `noout` set. OSD recreation needs real redundancy margin.

## Rejected alternatives

- **ZFS native encryption on the root pool.** No TPM path, so unattended unlock means a bespoke initramfs unseal script — custom code on the boot path of every node, to avoid a primitive (LUKS) that already does this.
- **In-place `zfs send | recv` migration to an encrypted dataset.** Avoids the reinstall but is hands-on, per-node and risky on a live cluster member, and still leaves the no-TPM problem of the alternative above.
- **Encrypting the root but not the OSDs.** Inverts the value: the data lives on the OSDs, and OSD encryption is by far the cheaper of the two.
- **Skipping Secure Boot to simplify PCR policy.** SB was deliberately enabled on both MS-01s after a costly conversion; PCR7 sealing is a *reason* to keep it, not to undo it.
- **Doing this before the msi RMA returns.** Two OSDs and a mon are already down; recreating OSDs with no redundancy margin risks data loss to save waiting.

## Consequences

- **Unattended boot and theft resistance cannot both come from the TPM.** PCR7-only sealing gives unattended boot and protects the disk at rest; it does not stop a thief booting the node. Closing that gap needs a TPM+PIN (breaking unattended boot, though enterable over AMT/JetKVM) or network-bound decryption. This is the decision's central trade and §Open questions carries it.
- **PCR7-only sealing has a local-attack weakness**: anything that boots with the same Secure Boot state unlocks the volume, including a GRUB command line edited to `init=/bin/bash`. A GRUB password, or binding to a PCR covering the kernel command line, is required — not optional hardening.
- **The fleet is on shim+grub, not systemd-boot.** The modern robust path (UKI + `systemd-stub` + PCR11) assumes systemd-boot, so this fleet is on PCR7 + GRUB password instead. Revisiting the bootloader choice is a separate decision.
- **Every node needs a reinstall.** The PXE path makes that tolerable but not free, and each one is a full install → convert to shim+grub → enable SB → enrol TPM cycle.
- **worklab proves the procedure but not the PCR values** — it runs with Secure Boot disabled and plain GRUB, so its PCR7 differs from the MS-01s by construction.
- **dm-crypt costs a few percent on NVMe** with AES-NI; small but not zero, and it lands on the Ceph data path.
- **Encrypted OSDs cannot be imported into another cluster** without the mon key — an intended property that also removes a disaster-recovery shortcut.
- **msi's TPM remains unverified** until it returns; if it lacks one, node 3 needs a different unlock path and the fleet is heterogeneous.

## Open questions

These are why the status is Proposed. None block the OSD-encryption half, which can proceed on decisions 3–5 alone once the cluster is healthy.

1. **How is the encrypted root actually installed,** given the auto-installer cannot do it? Candidates: a `[first-boot]` script that rebuilds root onto LUKS; a custom debootstrap-plus-`proxmox-ve` install; or a post-install migration. Each needs proving on worklab before it touches a cluster member.
2. **TPM-only, TPM+PIN, or network-bound (Clevis/Tang)?** Tang gives unattended boot *and* makes a removed node useless off-LAN — the closest thing to having both — but a Tang server hosted on the cluster it unlocks is circular. Mutual Tang (worklab serves the MS-01s, an MS-01 serves worklab) or an off-cluster host would be needed, and a Shamir threshold of TPM-and-Tang is stricter than either alone.
3. **Which PCRs**, and what the re-seal runbook is after a firmware or bootloader update.
4. **Does msi have a usable TPM** — verify on RMA return before planning node 3.
