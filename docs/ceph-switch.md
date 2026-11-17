# Ceph switch (CRS518) runbook

The MikroTik CRS518-16XS-2XQ-RM that carries the Ceph cluster network (VLAN 21, [ADR 0057](decisions/0057-ceph-replication-moves-to-a-dedicated-mikrotik-switch-island-with-2x25g-lacp-per-node-and-vlan-21-never-leaves-it.md)). RouterOS is hand-managed (ADR 0005 pattern): this file is the record, the live `/export` is the truth.

- Identity `ceph-switch`, RouterOS 7.24.6 long-term with RouterBOOT to match (upgraded from 7.20.8 on 2026-11-16). First configured 2026-10-21 over the serial console.
- Admin password: Infisical `/infrastructure/ceph_switch_admin_password`. Management address: `cluster.ceph_switch_mgmt_ip` in `network-data/local/host-bindings.yaml`.
- Management is the MGMT RJ45 (`ether1`) only, on a Pro-Max port with the `mgmt` profile (vlan10 access). It is not in the bridge. VLAN 21 never leaves the switch.

## Port map

| Ports | Use |
|---|---|
| `sfp28-1`, `sfp28-2` | `bond-ms01a` |
| `sfp28-3`, `sfp28-4` | `bond-ms01b` |
| `sfp28-5`, `sfp28-6` | `bond-ms01c` |
| `sfp28-16` | **TEMP** VLAN 21 interconnect to Pro-Agg p30 (`ceph` profile, ms-01a's old port), for the migration only (ADR 0057 amendment, revised 2026-11-16) |
| `sfp28-7` … `sfp28-15`, `qsfp28-*` | disabled (a fourth OSD host takes 7 + 8) |

Each bond is 802.3ad, layer-3-and-4 hash, LACP fast (1 s), MTU 9000. The bonds are access ports in `br-ceph` (PVID 21, untagged only, hardware-offloaded, no STP). **A bond passes nothing until the host side is an LACP bond too** — a node still on one untagged ConnectX port stays on the Pro-Agg until `proxmox_host` renders its ceph bond.

## Configuration

Applied after removing the default configuration at first login. `<mgmt address>`, `<vlan10 gateway>`, `<AdGuard VIP>` and `<syslog LB>` (services offset 66) are bindings.

```
/system identity set name=ceph-switch
/system clock set time-zone-name=America/Chicago
/interface list add name=MGMT
/interface list member add list=MGMT interface=ether1
/interface ethernet set [find where name~"^sfp28-[1-6]\$"] l2mtu=9216 mtu=9000
/interface bonding add name=bond-ms01a slaves=sfp28-1,sfp28-2 mode=802.3ad transmit-hash-policy=layer-3-and-4 lacp-rate=1sec mtu=9000
/interface bonding add name=bond-ms01b slaves=sfp28-3,sfp28-4 mode=802.3ad transmit-hash-policy=layer-3-and-4 lacp-rate=1sec mtu=9000
/interface bonding add name=bond-ms01c slaves=sfp28-5,sfp28-6 mode=802.3ad transmit-hash-policy=layer-3-and-4 lacp-rate=1sec mtu=9000
/interface bridge add name=br-ceph vlan-filtering=yes protocol-mode=none mtu=9000 comment="VLAN 21 only - never leaves this switch (ADR 0057)"
/interface bridge port add bridge=br-ceph interface=bond-ms01a pvid=21 frame-types=admit-only-untagged-and-priority-tagged
/interface bridge port add bridge=br-ceph interface=bond-ms01b pvid=21 frame-types=admit-only-untagged-and-priority-tagged
/interface bridge port add bridge=br-ceph interface=bond-ms01c pvid=21 frame-types=admit-only-untagged-and-priority-tagged
/interface bridge vlan add bridge=br-ceph vlan-ids=21 untagged=bond-ms01a,bond-ms01b,bond-ms01c
/interface ethernet set [find where name~"^sfp28-([7-9]|1[0-6])\$" or name~"^qsfp28"] disabled=yes
/ip address add address=<mgmt address>/24 interface=ether1 comment=mgmt-vlan10
/ip route add gateway=<vlan10 gateway>
/ip dns set servers=<AdGuard VIP>
/system ntp client set enabled=yes servers=<vlan10 gateway>,pool.ntp.org
/ip service set [find where name~"telnet|ftp|www|api"] disabled=yes
/ip service set [find where name~"ssh|winbox"] available-from=<internal /12>
/ip ssh set strong-crypto=yes
/tool mac-server set allowed-interface-list=none
/tool mac-server mac-winbox set allowed-interface-list=MGMT
/tool mac-server ping set enabled=no
/tool bandwidth-server set enabled=no
/ip neighbor discovery-settings set protocol=lldp
/system logging action add name=axosyslog target=remote remote=<syslog LB> remote-port=5514
/system logging add topics=info action=axosyslog
/system logging add topics=warning action=axosyslog
/system logging add topics=error action=axosyslog
# TEMP migration interconnect (remove: see Migration below)
/interface ethernet set sfp28-16 disabled=no l2mtu=9216 mtu=9000 auto-negotiation=no speed=25G-baseCR fec-mode=fec74
/interface bridge port add bridge=br-ceph interface=sfp28-16 pvid=21 frame-types=admit-only-untagged-and-priority-tagged comment=TEMP-interconnect
/interface bridge vlan set [find vlan-ids=21] untagged=bond-ms01a,bond-ms01b,bond-ms01c,sfp28-16
```

## Migration

VLAN 21 spans both switches through the `sfp28-16` interconnect until the last OSD leaves the Pro-Agg, so no node is cut off mid-move (ADR 0057 amendment).

1. Cable the interconnect: CRS518 `sfp28-16` to Pro-Agg p30. **Done 2026-11-16**, `link-ok` at 25Gbps. Pro-Agg p30 is set by hand in UniFi to 25G full duplex (no auto-negotiation), so `sfp28-16` is forced to match: `auto-negotiation=no speed=25G-baseCR fec-mode=fec74`. With auto-negotiation on, or with `fec91`, the link stays down. Both a Ubiquiti `DAC-SFP28-0.5M` and an FS `SFP-25G-PC02` (2 m) link with these settings.

**Any re-provision of the Pro-Agg drops all of p29–32** for 5–15 s (2026-11-16: one port-setting change in UniFi took ms-01b, ms-01c and msi down together), and the ports can come back at 10G. Plugging or unplugging a cable on p30 does not. So change a Pro-Agg setting, or run `make unifi-apply`, only at `HEALTH_OK` with every OSD up, and afterwards confirm `ethtool` reads `25000Mb/s` on every node still cabled there.
2. ms-01a rejoins the cluster on the island: fan header fitted, both ConnectX ports to `sfp28-1` and `sfp28-2`, `ceph_nic` a two-port list in `host-bindings.yaml` so `proxmox_host` renders the bond. Run the per-node checks below before it gets OSDs. **Done 2026-11-16**: both ports 25000Mb/s, both slaves active, jumbo ping to all three Pro-Agg nodes across the interconnect, ConnectX 97 °C settled idle and 100 °C peak under backfill (the card takes about 2 h after a cold boot to settle).
3. ms-01b and ms-01c give up their cards for the fan-header work (about a week at the shop) and keep running: while a card is away, that node's `ceph_nic` is `vmbr0.21`, the VLAN 21 leg on its 10G bond (the Pro-Agg `tf-trunk-all` ports already carry VLAN 21 tagged). Prove it on ms-01b with the card still seated before any card is pulled. Then per node, one at a time under `noout`, `HEALTH_OK` before the next: set `ceph_nic: "vmbr0.21"`, re-render the interfaces, confirm OSD heartbeats, shut down, pull the card (and swap the 10G DACs for the 2 m ones), boot. Both cards can be away at once. Add or remove no OSD while a node replicates over 10G. **Both nodes moved to the 10G leg 2026-11-17, cards still seated**: no OSD went down and none was restarted. Two things the re-render does not do for you: `make proxmox-hosts LIMIT=<node>` stops at the cluster step's whole-group assert, which is after the interfaces are applied, so the failure is expected; and `ifreload` leaves the old address on `nic4` beside the new one on `vmbr0.21`, with the route still on `nic4`, until `ip addr del <ceph address>/24 dev nic4`. Check with `ip route get <a peer's ceph address>`. msi followed the same day (its card goes to the shop in the same batch, operator choice 2026-11-17), so every node except ms-01a replicates over 10G until the cards return. `CephNicSpeedAbsent` fires for a node once its card is out; that is expected until the card returns.
4. As each card returns: shut the node down under `noout`, fit the card, both ports to its bond pair on the CRS518, `ceph_nic` to the two-port list, boot, re-render, run the per-node checks. The node never returns to its Pro-Agg SFP28 port.
5. msi's OSDs are drained (ADR 0056).
6. Remove the interconnect: pull the DAC, then `/interface bridge port remove [find interface=sfp28-16]`, `/interface bridge vlan set [find vlan-ids=21] untagged=bond-ms01a,bond-ms01b,bond-ms01c`, `/interface ethernet set sfp28-16 disabled=yes comment=""`, and delete the TEMP lines above.

## Checks

- After racking: `/system health print` shows `psu1-state` `ok`, then again under replication load for temperatures (ADR 0057 airflow note). PSU2 is not connected (operator choice 2026-11-16), so `psu2-state` reads `fail`; that is expected, not a fault.
- Upgrades: stay on the `long-term` channel. `/export` and `/system backup save` first and copy both off the switch, `/system package update install`, then `/system routerboard upgrade` and a second reboot. A reboot stops all replication once nodes depend on the switch, so set `noout` first. Afterwards re-check `sfp28-16` (forced speed and FEC), `/ip ssh print` and `/ip service print`.
- Per node at cutover: `/interface bonding monitor bond-ms01X` shows both slaves active, the host shows `ethtool <port>` `Speed: 25000Mb/s` on both ports, `ping -M do -s 8972` crosses VLAN 21 to a node still on the Pro-Agg, and the ConnectX temperature with both ports linked stays under the 105 °C warning.
- Serial console: 115200 8N1. Log in as `admin+ct` to skip the terminal-size probe.
