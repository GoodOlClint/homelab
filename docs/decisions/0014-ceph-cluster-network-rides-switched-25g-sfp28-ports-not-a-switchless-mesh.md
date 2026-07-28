# ADR 0014 — Ceph cluster network rides switched 25G SFP28 ports, not a switchless mesh

- **Status:** Accepted
- **Date:** 2026-07-27
- **Deciders:** operator + agent
- **Context source:** operator decision during WP2 implementation; amends the plan's "25G switchless mesh" storage row

## Context

The migration plan locked "25G switchless mesh (CX-4 Lx + DACs)" for the Ceph cluster network: each node's two ConnectX ports DAC'd to its two peers in a triangle, routed with FRR OpenFabric over per-node /32 loopbacks. That design predates the switch purchase — it existed to avoid buying 25G switch ports. The USW-Pro-Aggregation now in hand has 4× SFP28 25G ports, which covers three nodes with one spare, removing the mesh's whole reason to exist.

The mesh carried real costs: FRR + OpenFabric as an extra routed control plane on every node, triangle cabling that cannot extend past 3 nodes, and a topology the switch-managed UniFi fabric (WP5) can't see or configure.

## Decision

Each node's Ceph cluster-network link is **one ConnectX 25G port cabled to an SFP28 port on the aggregation switch**, as an **access/native port on a dedicated unrouted VLAN 33 ("Ceph"), MTU 9000, static IPs** (`<prefix>.33.<node-octet>`). No FRR, no OpenFabric, no loopbacks. The second ConnectX port stays uncabled as a spare.

The ADR-0009 network split is unchanged: Ceph **public** network stays on the 10G storage VLAN 20 (client access for non-25G nodes such as worklab); the **cluster** network (OSD replication) is this switched 25G VLAN, both set at `pveceph init`.

## Rejected alternatives

- **Switchless FRR OpenFabric mesh (the original plan):** only made sense when the switch had no 25G ports. Costs an extra routing daemon per node, unextendable triangle cabling, and invisibility to the UniFi fabric — all for ports we now own. Rejected the day the Pro-Aggregation's 4× SFP28 arrived.
- **LACP both ConnectX ports to the switch:** would consume all 4 SFP28 ports for 3 nodes (no spare, no 4th-node headroom) for bandwidth Ceph on this cluster can't use (pve's Gen3 x4 slot caps ~31.5 Gbps anyway). Single link + spare port wins.
- **Keep replication on the 10G fabric (no 25G at all):** the cards are in hand and rebalance/recovery traffic is exactly what should stay off the VLAN that carries NAS/media I/O.

## Consequences

- WP2's `proxmox_host` role drops FRR entirely; the ceph link is one static stanza in the interfaces drop-in. VLAN 33 joins `vlans.yaml` as an unrouted, UniFi-only entry (same pattern as corosync 31/32, ADR-0008).
- WP5's UniFi module gains the Ceph VLAN + an SFP28 access-port profile (native VLAN 33, jumbo) for the three node ports — the whole Ceph network becomes IaC-visible.
- Cabling: 3× SFP28 DAC node→switch (not the 3-edge triangle); a 4th 25G node needs only the spare port.
- A single 25G link (and the switch itself) is now in the Ceph cluster-network failure path; acceptable — cluster-network loss degrades replication, it doesn't take down client I/O, and the spare ConnectX port is the repair path.
- The plan's hardware row ("switchless mesh, DACs node-to-node") and terraform/hosts comments referencing "the FRR mesh (WP2)" are amended in the same change.
