# terraform/hosts/ — Proxmox host/cluster plane

Separate Terraform root (own state) for the host plane: host networking, and later
cluster options / Ceph pool / SDN / ACME. It exists **before** the VM fleet in
`../` and changes rarely, so a connectivity-breaking host apply can't hold the
fleet's state hostage (ADR-0002).

**This root owns**, per node, over the stable VLAN 30 mgmt link:
the X710 (pve: 82599ES) LACP `bond0` → VLAN-aware `vmbr0` → the storage (VLAN 20,
jumbo) and services (VLAN 40, web-UI/VIP) host interfaces.

**It deliberately leaves alone** the i226-V/VLAN 30 install link (carries the API
session + corosync ring0), the ConnectX 25G ports (FRR mesh, WP2), and the second
i226 (ring1, WP2) — so a re-apply can never drop the link Terraform is talking over.

## Day-1 bring-up (per node: crete, crete2, then pve on Day-2)

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

3. **Install.** Boot the node off the baked ISO (unattended). It comes up on its
   VLAN 30 mgmt IP with `nicN` names pinned (incl. the ConnectX).

4. **Capture the bond slaves.** SSH in and record the two 10G NIC `nicN` names into
   `nodes.auto.tfvars` (gitignored — copy from `nodes.auto.tfvars.example`):
   ```
   for n in $(ls /sys/class/net); do d=$(ethtool -i "$n" 2>/dev/null | awk '/^driver/{print $2}'); \
     echo "$n $d"; done | grep -E 'i40e|ixgbe'   # crete/crete2: i40e (X710); pve: ixgbe (82599ES)
   ```

5. **Hand-off token** (ADR-0002 boundary — the one manual step):
   ```
   make node-bootstrap IP=172.16.30.103   # creates terraform@pve + token; store it in bootstrap.sops.yml
   ```

6. **Apply the host networking.** Endpoint = the node's VLAN 30 mgmt URL (the stable
   link — never the bond being reconfigured):
   ```
   make hosts-plan  ENDPOINT=https://172.16.30.103:8006/
   make hosts-apply ENDPOINT=https://172.16.30.103:8006/   # interactive confirm
   ```

## DoD (WP1)

- Fresh answer-file install of crete → `make hosts-apply` converges with **zero**
  manual host edits; a re-apply is a **no-op**.
- After a host reboot all planes come up: `bond0` LACP negotiated, `vmbr0` VLAN-aware,
  VLAN 20/40 addresses present, and jumbo to the NAS works:
  ```
  ping -M do -s 8972 172.16.20.10   # storage VLAN, 9000-byte frames, no fragmentation
  ```

## Notes

- Provider auth currently uses `root@pam` + `proxmox_password` (matches the main
  project). `node-bootstrap` provisions the `terraform@pve` token for the eventual
  least-privilege switch; set `TF_VAR_virtual_environment_api_token` and add
  `api_token` to `provider.tf` when ready.
- Cluster create / Ceph bootstrap / FRR / keepalived are **not** here — they land in
  the Ansible `proxmox_host` role (WP2), being outside the provider's API surface.
