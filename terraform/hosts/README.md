# terraform/hosts/ — Proxmox host/cluster plane

Separate Terraform root (own state) for the host plane: host networking, and later
cluster options / Ceph pool / SDN / ACME. It exists **before** the VM fleet in
`../` and changes rarely, so a connectivity-breaking host apply can't hold the
fleet's state hostage (ADR-0002).

**This root owns**, per node, over the stable VLAN 30 mgmt link:
the X710 (pve: 82599ES) LACP `bond0` → VLAN-aware `vmbr0` → the storage (VLAN 20,
jumbo) host interface. Host mgmt (VLAN 30) + the keepalived VIP are **not** here —
WP2 re-homes mgmt from the i226-V install link to the bond and stands up the VIP
(adding a VLAN 30 IP on the bond here would collide with the install link — ADR-0008).

**It deliberately leaves alone** the i226-V/VLAN 30 install link (carries the API
session + corosync ring0), the ConnectX 25G ports (Ceph VLAN 21 link, WP2 — ADR 0014), and the second
i226 (ring1, WP2) — so a re-apply can never drop the link Terraform is talking over.

## Day-1 bring-up (per node: ms-01a, ms-01b, then msi on Day-2 — proven end to end 2026-08-19)

> **Seat the 25G ConnectX card BEFORE installing.** The PVE 9 installer pins every
> present NIC by MAC to a stable `nicN` name. If the card is added later it stays
> `enpXsY` and renumbers the bus (this is why crete lost networking and pve's GPU
> passthrough broke — see the plan). Verified 2026-07: the ConnectX ports are **not**
> pinned on any node today, so a fresh install-with-card-seated is what fixes it.

1. **Fill bindings.** Copy `network-data/host-bindings.example.yaml` →
   `network-data/local/host-bindings.yaml` (gitignored) and set each node's
   install NIC MAC, VLAN 30 CIDR/gateway, fqdn, root SSH key (pve: also `boot_disks`).

2. **Bake the answer file + ISO.** Injects the root-password hash (from
   `bootstrap.sops.yml` `proxmox_password`) and the bindings — nothing secret is
   committed.
   ```
   make node-iso NODE=crete ISO=/path/to/proxmox-ve_9.x.iso
   # -> terraform/hosts/pve-autoinstall-crete.iso  (gitignored)
   # validates via `proxmox-auto-install-assistant validate-answer` if installed
   ```

3. **Install — PXE (ADR 0026).** `make node-answers` bakes every node's answer
   file; `make ansible pxe` ships them to the `pxe` guest, which serves the PVE
   installer over iPXE (the signed shim → GRUB chain is parked — GRUB's efinet
   cannot transmit on the i226, see the plan) and answers each node by its
   install-NIC MAC. pfSense DHCP values:
   [docs/pfsense-netboot.md](../../docs/pfsense-netboot.md).
   **Arm the node first — this is the wipe confirm:** `make node-arm NODE=<node>`
   (the answer server 404s until armed, so an unarmed PXE never wipes a disk;
   auto-expires after 30 min, `make node-disarm` to cancel). Then AMT
   *Reset to PXE* on the node (at the console/KVM, press `i` — iPXE defaults to
   local-disk boot so a stray PXE can't auto-install) — or, from a running node, `efibootmgr -n <the
   I226-LM IPv4 PXE entry> && systemctl reboot` (the warm path keeps the PHY at
   2.5G; a cold firmware PXE trains at 10 Mb/s). Unattended, no media session.
   It comes up on its VLAN 30 mgmt IP with `nicN` names pinned (incl. the ConnectX).
   The answer file's `[first-boot]` hook (served by the pxe guest) pins NIC
   names (`pve-network-interface-pinning generate` — the 9.2 auto-installer does
   not), quiets the console, and reboots once, so the node needs **no hand
   steps** before step 4. Secure Boot must be OFF and STAYS off (iPXE is
   unsigned and the installed systemd-boot is not enrolled in the firmware SB
   db, so re-enabling SB bricks boot — recovery is disabling SB in BIOS; see
   ADR 0026).
   *Fallback when the network itself is down:* step 2's ISO over AMT IDE-R
   (~1–2 MB/s — measured 2026-08-18); without the pxe guest the `[first-boot]`
   section is dropped at bake time, so run the pinning command by hand.

4. **Capture the bond slaves.** SSH in and record the two 10G NIC `nicN` names into
   `nodes.auto.tfvars` (gitignored — copy from `nodes.auto.tfvars.example`):
   ```
   for n in $(ls /sys/class/net); do d=$(ethtool -i "$n" 2>/dev/null | awk '/^driver/{print $2}'); \
     echo "$n $d"; done | grep -E 'i40e|ixgbe'   # crete/crete2: i40e (X710); pve: ixgbe (82599ES)
   ```

5. **Hand-off token** (ADR-0002 boundary — the one manual step):
   ```
   make node-bootstrap IP=<node-vlan30-ip>   # creates terraform@pve + token; store it in bootstrap.sops.yml
   ```

6. **Apply the host networking.** Endpoint = the node's VLAN 30 mgmt URL (the stable
   link — never the bond being reconfigured):
   ```
   make hosts-plan  ENDPOINT=https://<node-vlan30-ip>:8006/ NODE=<node>
   make hosts-apply ENDPOINT=https://<node-vlan30-ip>:8006/ NODE=<node>   # interactive confirm
   ```
   `NODE=` scopes the apply to that node — required while the node is still
   standalone (its API cannot reach the other nodes in `nodes.auto.tfvars`).
   After the cluster exists, omit `NODE=` and point `ENDPOINT` at the VIP to
   converge every node in one apply.

## DoD (WP1)

- Fresh answer-file install of crete → `make hosts-apply` converges with **zero**
  manual host edits; a re-apply is a **no-op**.
- After a host reboot all planes come up: `bond0` LACP negotiated, `vmbr0` VLAN-aware,
  VLAN 20 storage address present, and jumbo to the NAS works:
  ```
  ping -M do -s 8972 <nas-storage-ip>   # storage VLAN, 9000-byte frames, no fragmentation
  ```

## Notes

- Provider auth currently uses `root@pam` + `proxmox_password` (matches the main
  project). `node-bootstrap` provisions the `terraform@pve` token for the eventual
  least-privilege switch; set `TF_VAR_virtual_environment_api_token` and add
  `api_token` to `provider.tf` when ready.
- Cluster create / Ceph bootstrap / keepalived are **not** here — they land in
  the Ansible `proxmox_host` role (WP2), being outside the provider's API surface.
