# PXE netboot for bare-metal node installs — change plan

Status: **implemented and proven 2026-08-19** — both MS-01 nodes reinstalled hands-off (warm `efibootmgr -n <PXE entry>` + reboot from Linux, or AMT *Reset to PXE*) and landed Ansible-ready; Day-1 chain PXE → `hosts-apply` → `proxmox-hosts` completed end to end (2-node cluster, QDevice, VIP). Decision record: [ADR 0026](decisions/0026-bare-metal-nodes-install-over-pxe-from-a-fleet-guest-answer-files-served-over-http-secure-boot-stays-on.md).

## Why now

Day 1 of the [MS-01 cutover](ms01-cluster-iac-plan.md) installs nodes from an answer-file ISO mounted over AMT IDE-R. Measured 2026-08-18/19 on ms-01b: IDE-R boots only with Secure Boot off, streams at ~1–2 MB/s (boot >1 min, install still at 70% after ~4 h), and the media session dies with the MeshCommander session. The [July research](research-baremetal-iac-2026-07-10.md) already named the intended end state — DHCP + HTTP → iPXE → PVE kernel/initrd → answer file over HTTP — with AMT/JetKVM as power/console only. This change builds that, as a fleet guest, and retires IDE-R to a documented fallback.

## Scope

In: a `pxe` guest built by the existing fleet module, a `pxe` Ansible role, the pfSense DHCP netboot options for VLAN 30 (hand-applied, ADR 0005), and a `wipefs` guard in `proxmox_host` for reused OSD disks. Out: pfSense IaC, a bare-metal control plane (Tinkerbell/MAAS — rejected in the research doc), third-party-signed iPXE binaries, mirroring netboot.xyz.

## Design

| Piece | Decision |
|---|---|
| Guest | `pxe` VM in `vm-configs.tf` (`infrastructure_vms`), pinned **Debian 13 genericcloud** image (same lineage as ADR 0025's PBS decision) so `proxmox-auto-install-assistant` installs from the Proxmox trixie repo; 2 vCPU / 2 GiB / 20 GiB; live-fleet dual-homed vlan10+vlan40 like its neighbours (single-homed at WP4 per ADR 0017). Built with `make build pxe` — targeted, never `make apply`. |
| Boot chain (Secure Boot ON) | **Vendor-signed end to end:** TFTP serves Proxmox's `shimx64.efi.signed` (Microsoft-signed, embeds the Proxmox Secure Boot CA) as the DHCP boot file, with `grubnetx64.efi.signed` beside it as `grubx64.efi` (Proxmox-signed network GRUB: `efinet/tftp/http/linuxefi/chain`). `grub.cfg` loads the ISO's Proxmox-signed `linux26` + the installer initrd over **HTTP** (nginx). Verified on pve 2026-08-19: `sbverify` shows the 9.2-1 ISO kernel signed by the Proxmox CA; both signed binaries ship in `shim-signed` / `grub-efi-amd64-signed`, so the role copies them from the Proxmox repo. `next-server` may be any routable IP, so the guest does not sit on the install VLAN; pfSense passes install-VLAN → pxe on 69/udp + 80/tcp. |
| Boot image | Role downloads the pinned PVE ISO (version + sha256 in role defaults, rolled deliberately — ADR 0016 posture), runs `prepare-iso --fetch-from http --url http://<pxe>/answer`, extracts `boot/linux26`, and builds the PXE initrd by appending the prepared ISO into the initramfs (the community `pve-iso-2-pxe` method the research doc cites; ~1.8 GiB, `ramdisk_size=16777216`). One generic image for every node. |
| Answer files | Rendered per node on the operator's machine by the existing `scripts/bake-answer.sh` (it already owns bindings + the bootstrap-tier root hash, keeping `bootstrap.*` out of role templates), copied to the guest as `/srv/pxe/answers/<node>.toml` (0600). A ~60-line matcher (`answer.py`, stdlib) handles the installer's POST: reads the `install_nic_mac` map (rendered from `host-bindings.yaml` at deploy), matches `network_interfaces[].mac`, returns that node's TOML, 404 otherwise. |
| GRUB menu | Default (timeout 10 s) = PVE unattended install; entries: PVE install, local disk, **netboot.xyz** (chainloads an unsigned `ipxe.efi` that chains `https://boot.netboot.xyz` — works only in a one-shot Secure-Boot-off session; rescue/other devices), memtest. |
| pfSense (hand) | *Services → DHCP Server → INFRASTRUCTURE → Network Booting*: enable; next-server = pxe vlan40 IP; UEFI 64-bit file `ipxe.efi` (shim chain parked — see Live findings; BIOS/legacy file unset — all nodes are UEFI); custom option **250** (text) `http://<pxe>/answer`. Firewall rule VLAN 30 → pxe 69/udp, 80/tcp. Documented in `docs/pfsense-netboot.md` with a verification step. |
| Nodes | BIOS: **Secure Boot OFF and stays off** (superseded the design's SB-ON — the signed chain is parked and the installed systemd-boot is not SB-enrolled, so enabling SB bricks boot). UEFI network stack / PXE on the install NIC enabled, boot order local disk first — PXE is invoked one-shot via AMT *Reset to PXE*. |
| `proxmox_host` | `wipefs -a` each `osd_disks` entry before `pveceph osd create` **only if** `ceph-volume lvm list` shows no OSD on it (idempotent; covers ISO-dd'd or reused disks). |

**Install VLAN vs AMT VLAN (decided 2026-08-19):** the installer cannot tag today (Proxmox [bug 2164](https://bugzilla.proxmox.com/show_bug.cgi?id=2164) — gyptazy's series adding a VLAN tag to the installer and the auto-installer answer file is PATCH AVAILABLE, unmerged as of 2026-08-10), and AMT can never tag (`VLANTag` unsupported since AMT 6). So for the Day-1/Day-2 installs the install port keeps **native 30** and AMT sits on 30. The ADR 0017 end state (AMT on the VLAN 10 network plane, hosts on 30) is reached **after WP2** with no OS change: WP2 re-homes host mgmt onto the bond (tagged 30) and leaves the install NIC as a tagged-31 carrier, so the port's native VLAN is then used only by AMT and the PXE first hop — flip `node_install` native 30→10 and re-IP AMT to `172.16.10.x` per node. Reinstalls after the flip use the answer-file VLAN key once bug 2164 merges (install tagged 30 directly), or a temporary VLAN 10 install until then. Do not force native 10 before WP2: it would require installing on a temporary `.10.x` and teaching `proxmox_host` to re-home to a different IP mid-cutover.

Conflicts with existing rules: none. `bootstrap.*` stays out of role templates (bake script renders); pfSense remains hand-managed (ADR 0005); no DHCP for LXCs (not involved); images pinned (ADR 0016). The WP1 `make node-iso` path stays as the documented fallback when the network is down.

## Sequencing

1. ADR 0026 + this plan (this commit).
2. `pxe` role + `vm-configs.tf` entry + `make pxe-answers` (bake all nodes, copy) → `make build pxe`.
3. Operator applies the pfSense DHCP/firewall values; verification from a VLAN 30 client.
4. First real node: whichever MS-01 is free (ms-01a, or ms-01b if its IDE-R install has died) — AMT *Reset to PXE* → unattended install → WP1 step 4 onward unchanged.
5. `hosts/README.md` + plan doc: IDE-R demoted to fallback; PXE becomes the WP1 install step. msi (Day 2) and worklab use the same path.

## Live findings 2026-08-19 (first boots on ms-01b)

- **GRUB `efinet` cannot transmit on the MS-01's i226 UEFI driver** (`error: couldn't send network packet` at the `grub>` prompt; firmware TFTP of shim/grub itself works). The vendor-signed shim→GRUB chain is therefore parked (files stay served); installs ride **iPXE** (`snponly.efi`/`ipxe.efi` + `autoexec.ipxe` from the TFTP dir, no DHCP iPXE-filename option needed) with Secure Boot off for the session. `autoexec.ipxe` DHCPs only the install NIC (MAC match from `host-bindings`) so iPXE doesn't walk the 6 NICs. Revisit SB-on when a BIOS/UEFI-driver update fixes efinet.
- **ms-01b's pre-OS link was 10 Mb/s** (switch p38 showed 10 in PXE, 2500 under PVE) → its 1.7 GiB pull took ~30 min. **ms-01a on p34 negotiated 2500 in PXE and pulled the initrd in 17 s** — The operator's hypothesis fits all observations: **a warm reset from running Linux keeps the PHY at the 2.5G `igc` negotiated, while a node sitting in firmware (cold, or after many firmware-only resets, as b was) trains at 10 Mb/s** — i.e. a firmware/LPLU-class behaviour masked on a by the warm reboot. Test when convenient: cold-boot a node straight into PXE and read its switch port speed (prediction: 10), then warm *Reset to PXE* from Linux (prediction: 2500). Operational rule meanwhile: reinstalls from a running node are fast; first installs/after power loss take the slow path. Durable fix options: iPXE `intel` driver programming the PHY as `igc` does, or an Intel NVM LPLU change.
- pfSense ISC netboot has no "iPXE boot file name" field; `autoexec.ipxe` replaces it. Option 250 + `next-server` + UEFI-64 file (`ipxe.efi`) are the only fields.

## Day-1 chain proven 2026-08-19 (second full run)

- Hands-off reinstall of both nodes: answer POST ~2.5 min after the warm reset, `[first-boot]` hook pins `nicN`, moves the mgmt IP from the installer's `vmbr0` onto the install NIC and reboots once → node up with 6 `nicN`, no `vmbr0`, bootstrap resolver (AdGuard lands minutes later via `proxmox_host` `repos.yml`). `make hosts-apply … NODE=<node>` creates bond0/vmbr0/vmbr0.20; re-plan = no changes; jumbo to the NAS verified from both.
- `make proxmox-hosts` bugs fixed in the role (live, Day 1): role defaults are not visible via `hostvars[other]` under ansible-core 2.20 → per-node addresses published as facts; `proxmox_cluster` join idempotency key is the master's **mgmt** IP (PVE resolves nodenames via `/etc/hosts`), not ring0; ring1 on a dedicated NIC is **untagged** (the WP5 `corosync_ring1` port profile is access — tagged `nic0.32` never passed, UniFi drops tagged-native frames), the bond-carried ring1 (msi) keeps the VLAN 32 sub-if; QDevice prep is now hands-off (qnetd install + node keys authorized + host key trusted on the qnetd host — `pvecm qdevice setup` otherwise hangs on an interactive host-key prompt under Ansible). Second run: 0 changed.
- One of three PXE attempts on ms-01a stalled after the initrd download (no answer POST, fell back to local disk) and one firmware PXE timed out; the next warm retry succeeded each time. Not root-caused — watch the console if it recurs.
- QDevice host = worklab (standalone PVE, never a member) and the VIP are bindings (`cluster.qdevice_addr`, `cluster.vip_cidr`), filled 2026-08-19.

## Follow-ups surfaced on Day 1 (not blocking)

- `terraform/hosts` still authenticates as `root@pam` + password; `node-bootstrap.sh`'s `terraform@pve!provider` token is minted but unused. Wire `virtual_environment_api_token` into the hosts provider (ADR-0002's least-privilege intent); only the cluster-bootstrap node's token survives a join, so store that one.
- The PVE 9.2 auto-installer does not pin `nicN` names; the PXE `[first-boot]` hook does it (verified on ms-01a). Keep the hook as the WP1 contract; the ISO/IDE-R fallback needs the pinning command by hand.

## Definition of Done (discriminating, evidenced)

- `make build pxe` converges twice (second run: 0 changed).
- From an install-VLAN host: `tftp <pxe> -c get shimx64.efi` and `-c get grubx64.efi` succeed; `curl -fsS http://<pxe>/pve/linux26 -o /dev/null` works; `curl -fsS -X POST http://<pxe>/answer -d '{"network_interfaces":[{"mac":"<ms-01a LM MAC>"}]}'` returns ms-01a's TOML and an unknown MAC returns 404.
- End-to-end: AMT *Reset to PXE* on a node (**Secure Boot OFF** — the parked signed chain, live findings) → unattended install with no media session → `ssh root@<node> hostname` returns the node name within 15 min of the reset, `nicN` names pinned, OSD disk untouched. (SB-on is a future item gated on BOTH the i226 efinet fix and a proxmox-boot-tool signed-shim/MOK setup on the installed system; do not re-enable SB in the meantime — it bricks boot.)
- Rollback: disabling the pfSense Network Booting section returns nodes to local-disk boot; the guest is inert.

## Risks

GRUB's HTTP client is single-stream; the 1.8 GiB initrd needs the node to have RAM for it (MS-01s: 96 GiB — fine) and a 2.5G link (seconds). The answer endpoint is plain HTTP on internal VLANs; it serves only a root-password *hash* and public keys, same exposure as the baked ISO. Version roll of the PVE ISO is a role-defaults edit + redeploy, never automatic.
