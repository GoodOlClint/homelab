# ADR 0026 — Bare-metal nodes install over PXE from a fleet guest via the vendor-signed shim→GRUB chain, answer files served over HTTP, Secure Boot stays on

- **Status:** Proposed
- **Date:** 2026-08-19
- **Deciders:** operator + agent
- **Context source:** Day-1 MS-01 install session 2026-08-18/19; [docs/pxe-netboot-plan.md](../pxe-netboot-plan.md); [research-baremetal-iac-2026-07-10.md](../research-baremetal-iac-2026-07-10.md)

## Context

> **Amended 2026-08-19 — the title is now aspirational: Secure Boot is OFF, not on.** TWO independent SB gaps, do not conflate them: (1) *PXE transport* — GRUB's `efinet` can't transmit on the i226, so the vendor-signed shim→GRUB chain is parked and installs ride unsigned iPXE with SB off (iPXE offers an MS-trusted signed shim — ipxe.org/secboot — which works on the i226 and could un-park this, but the chained PVE kernel would still need its Proxmox CA enrolled as a MOK per node). (2) *Installed-system boot* — this is what bricked ms-01b when SB was re-enabled: `proxmox-boot-tool` selects the on-disk bootloader at install time by SB state, so an SB-off install lands **systemd-boot** (Proxmox-unsigned), not shim+grub. Verified: host ESP holds only `systemd-bootx64.efi` while `shim-signed`/`grub-efi-amd64-signed` are installed-but-unused. Gap (2) is FIXABLE in place, no reinstall — the [Proxmox Host_Bootloader](https://pve.proxmox.com/wiki/Host_Bootloader) procedure: booted SB-off, run `proxmox-boot-tool init /dev/<esp> grub` for each ESP (deploys the Proxmox-signed shim+grub, keeps systemd-boot as fallback), verify `efibootmgr -v` shows `\EFI\proxmox\shimx64.efi`, THEN enable Secure Boot in BIOS. Runs entirely under SB-off, so no chicken-and-egg. To be proven on the disposable **msi** install, then optionally codified as a post-install task so nodes come out SB-capable regardless of the PXE transport. Until proven on our hardware, SB stays OFF on all PVE nodes; never re-enable it on a systemd-boot node.


WP1 installs PVE nodes from a per-node answer-file ISO (`make node-iso`) that has to reach the box somehow. With the rack closed up the only remote medium was AMT IDE-R, and it was measured on ms-01b: it boots only with Secure Boot disabled, streams at roughly 1–2 MB/s through the ME (boot alone over a minute, the install still at 70 % after four hours), and the media session lives and dies with the MeshCommander KVM session. The July research had already concluded that the intended end state is DHCP + HTTP → iPXE → PVE kernel/initrd → answer file over HTTP, with AMT and JetKVM reduced to power and console — but WP1 shipped the ISO path as the shortcut. Three more bare-metal installs are ahead (ms-01a, msi at Day 2, worklab), plus rescue boots over the life of the cluster.

## Decision

Bare-metal PVE nodes install over **PXE** served from a **fleet guest** (`pxe`, a fleet-module VM on a pinned Debian 13 image, built with `make build pxe` — never hand-made). pfSense's DHCP on the install network hands out `next-server`, the UEFI boot file **`shimx64.efi`**, and **DHCP option 250** carrying the answer URL (hand-applied, ADR 0005). The boot chain is entirely **vendor-signed**: Proxmox's Microsoft-signed `shimx64.efi.signed` (embeds the Proxmox Secure Boot CA) → Proxmox's signed network GRUB (`grubnetx64.efi.signed`, served as `grubx64.efi` beside shim, with `efinet/tftp/http/linuxefi`) → `grub.cfg` → the ISO's Proxmox-signed `linux26` + the initrd that embeds the `prepare-iso --fetch-from http` image, both over HTTP. The guest also serves an answer endpoint that returns each node's TOML **keyed by install-NIC MAC**. Answer files are rendered by `scripts/bake-answer.sh` on the operator's machine and copied to the guest, so bootstrap-tier secrets never enter a role template. **Secure Boot is the target, not yet the practice (2026-08-19 amendment):** the signed shim→GRUB chain is built and served, but GRUB's `efinet` driver cannot transmit on the MS-01's i226 UEFI driver (`couldn't send network packet`), so it is **parked**. Until a firmware/GRUB fix lands, installs ride **iPXE** (`ipxe.efi` + `autoexec.ipxe` from the TFTP dir, DHCP on the install NIC only) with **Secure Boot disabled for the install session only** and re-enabled afterwards — the installed PVE boots signed. Revisit the signed chain on each MS-01 BIOS update. AMT and JetKVM are power/console only — a node is installed by *Reset to PXE*. The IDE-R ISO path remains a documented fallback for when the network itself is down. A `wipefs` guard precedes OSD creation so a disk that carried an installer image is reusable.

## Rejected alternatives

- **Keep AMT IDE-R as the install medium.** Measured too slow and too fragile (SB off, session-bound, hours per install); acceptable only as a fallback.
- **Hand-built temporary VM on the current pve.** An undeclared parallel guest that must be rebuilt as IaC later — the "parallel implementation" defect the house rules forbid, for no time saved over `make build pxe`.
- **Drive the pfSense DHCP options from the local pfSense Terraform provider.** Unproven for DHCP netboot options; ADR 0005 keeps pfSense hand-managed through the migration.
- **iPXE as the first stage (unsigned, or the Microsoft-signed iPXE 1.21.1 Broadcom ships for Ghost/Deployment Solution).** Unsigned iPXE forces Secure Boot off; the Broadcom binary is a third-party-signed generic loader of unclear redistribution terms, and it would still have to hand off to shim→GRUB to load a kernel under SB — the shim→GRUB chain alone does the whole job with Proxmox's own signed binaries.
- **Turning Secure Boot off permanently** (this ADR's first draft). Unnecessary once the vendor-signed netboot chain was confirmed (`sbverify` on the ISO kernel; `grubnetx64.efi.signed` present in `grub-efi-amd64-signed`).
- **A bare-metal control plane (Tinkerbell, MAAS, Metal³).** Rejected in the July research: they *are* PXE + answer-file workflows with a database in front; three nodes do not justify one.
- **Per-node baked ISOs over PXE (`--fetch-from iso`).** One image per node and a rebuild on every bindings change; the HTTP-fetch mode gives one generic image and per-node answers for free.

## Install safety gate (added 2026-08-19)

Once the old fleet was restored onto the cluster, an accidental re-PXE of a live node became catastrophic (the unattended installer wipes the boot disks). Two independent guards, both defaulting safe:
- **`boot.ipxe` defaults to local-disk boot**, not the installer — a stray PXE (boot-order fallthrough, leftover BootNext, mis-clicked *Reset to PXE*) boots the OS. Install is a deliberate console keypress (`i`).
- **The answer server refuses unless the node is armed.** `make node-arm NODE=<n>` writes an auto-expiring flag (`answers/armed/<n>`, default 30 min); unarmed → 404 → the unattended installer has no answer file and does not wipe. `make node-disarm` / `make node-arm-status` manage it. Arming is the operator's explicit wipe confirm.

Trade-off accepted: installs are no longer fully hands-off at the console (the `i` keypress + arm). A future refinement could let iPXE auto-select install only when the node is armed (arm-check over HTTP), restoring hands-off while keeping the gate.

## Consequences

- New: `pxe` role + guest, `docs/pfsense-netboot.md` (hand-applied DHCP/firewall values + verification), the answer matcher, pinned PVE ISO version/checksum in role defaults (rolled deliberately, ADR 0016 posture).
- WP1's install step becomes "AMT *Reset to PXE*"; `make node-iso` is demoted to fallback in `terraform/hosts/README.md` and the cutover plan.
- Nodes run with Secure Boot enabled; an install or rescue over iPXE needs SB disabled for that session (AMT KVM → Setup), then re-enabled. A node whose install port trains at 10 Mb/s in PXE (seen once, ms-01b p38) takes ~30 min to pull the image — check the switch port's speed first; ms-01a pulled it in 17 s at 2.5G.
- The install path now depends on pfSense DHCP and the `pxe` guest being up — a cold-start of the whole fleet still has the ISO fallback, which is why it is kept.
- The install NIC's **native VLAN 30** serves three things that cannot tag: the PXE first hop (DHCP/TFTP), the installer's own address, and **AMT** (`AMT_EthernetPortSettings.VLANTag` is unsupported in AMT 6.0 and later — Intel class reference). AMT therefore lives on the infrastructure VLAN by design; do not re-propose tagging it.
- The answer endpoint serves a root-password hash and public keys over plain HTTP on internal VLANs — the same exposure as the baked ISO had; revisit if the install VLAN ever becomes reachable from outside pfSense.
