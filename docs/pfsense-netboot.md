# pfSense — PXE netboot options for the node install VLAN (hand-managed, ADR 0005)

Decision: [ADR 0026](decisions/0026-bare-metal-nodes-install-over-pxe-from-a-fleet-guest-answer-files-served-over-http-secure-boot-stays-on.md) · plan: [pxe-netboot-plan.md](pxe-netboot-plan.md). The `pxe` guest is a fleet VM (`make build pxe`); everything below is the pfSense half that Terraform does not own.

Values come from the live fleet: `<pxe-ip>` is the `pxe` guest's **services-VLAN (VLAN 40)** address (`terraform output` / `ansible/inventory/vms.yaml`, `service_ip`). The install VLAN is the one whose native the node install ports carry — **INFRASTRUCTURE (VLAN 30)** today; when the post-WP2 flip moves the install ports' native to Management (plan), repeat this section on the MANAGEMENT interface.

## 1. DHCP server — Network Booting

*Services → DHCP Server → INFRASTRUCTURE → Network Booting*

| Field | Value |
|---|---|
| Enable network booting | ✔ |
| Next Server | `<pxe-ip>` |
| Default BIOS file name | *(empty — all nodes are UEFI)* |
| UEFI 32 bit file name | *(empty)* |
| UEFI 64 bit file name | `ipxe.efi` (iPXE with native drivers; `snponly.efi` = firmware-driver variant; `shimx64.efi` = the Secure-Boot chain, parked — GRUB efinet cannot transmit on the i226, see plan) |
| iPXE boot file name | *(field does not exist in pfSense ISC; iPXE runs `autoexec.ipxe` from the TFTP dir instead)* |
| Root path | *(empty)* |

The file is fetched over **TFTP** from Next Server. iPXE then runs `autoexec.ipxe` from the same TFTP directory, which DHCPs only the install NIC and chains `http://<pxe-ip>/boot.ipxe`.

## 2. DHCP server — custom option 250 (answer URL)

Same page, *Additional BOOTP/DHCP Options*:

| Number | Type | Value |
|---|---|---|
| `250` | `Text` | `http://<pxe-ip>/answer` |

The `prepare-iso --fetch-from http` image already carries this URL, so option 250 is belt-and-braces (it is what a stock/rescue installer would use). Leave option 251 (TLS fingerprint) unset — the endpoint is plain HTTP on internal VLANs.

## 3. Firewall

Rule on the INFRASTRUCTURE interface (above any block): source `INFRASTRUCTURE net` → destination `<pxe-ip>`, protocols **UDP 69** (TFTP) and **TCP 80** (HTTP). If the Management/operator VLAN does not already reach VLAN 40 on 80, nothing else is needed — the installer talks only to `<pxe-ip>`.

## 4. Node side (once per node)

BIOS: **Secure Boot OFF for the install session** (iPXE is unsigned; re-enable after — the installed PVE boots signed), UEFI network stack on, PXE on the install NIC enabled, boot order local disk first. Install = AMT *Reset to PXE* (MeshCommander power action) — one shot, no media session.

## Verification (from any VLAN 30 host, e.g. a bench node)

```
tftp <pxe-ip> -c get shimx64.efi && tftp <pxe-ip> -c get grubx64.efi && ls -la shimx64.efi grubx64.efi
curl -fsS http://<pxe-ip>/pve/linux26 -o /dev/null && echo kernel-ok
curl -fsS -X POST http://<pxe-ip>/answer -d '{"network_interfaces":[{"mac":"<install-NIC MAC of a node>"}]}' | head -5
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://<pxe-ip>/answer -d '{"network_interfaces":[{"mac":"<unknown-mac>"}]}'   # expect 404
```

Then on a node: *Reset to PXE* → GRUB menu appears over AMT KVM within ~20 s → "Install Proxmox VE (automated)" auto-selects after 10 s → unattended install → node answers SSH on its `install_cidr` as its own hostname. Rollback: untick *Enable network booting*; nodes boot local disk as before; the guest is inert.
