# ADR 0057 — Ceph replication moves to a dedicated MikroTik switch island with 2x25G LACP per node and VLAN 21 never leaves it

- **Status:** Proposed
- **Date:** 2026-09-15
- **Deciders:** operator + agent
- **Context source:** 2026-09-09 physical re-plan (council-tested) and the 2026-09-09 fabric-firmware fence · session 2026-09-15 · amends [ADR 0014](0014-ceph-cluster-network-rides-switched-25g-sfp28-ports-not-a-switchless-mesh.md)

## Context

ADR 0014 put each node's Ceph cluster-network link (VLAN 21) on one ConnectX 25G port cabled to one of the USW-Pro-Aggregation's four SFP28 ports. That has two limits. First, the Pro-Agg has only four SFP28 ports, which a third MS-01 plus a future fourth node, the mini-rack uplink and an all-flash NAS cannot share. Second, the Pro-Agg is the root of the UniFi fabric: a controller-driven firmware roll or STP reconvergence there (2026-09-09) stalls every VLAN on it, the Ceph replication link included.

Replication is the heaviest flow in the cluster, and every node has a second ConnectX port that is uncabled.

Verified 2026-09-11: `public_network` (mons, clients, CSI, cephfs) is VLAN 20, and `cluster_network` (VLAN 21) carries OSD↔OSD replication only.

## Decision

The Ceph cluster network moves to a dedicated **MikroTik CRS510-8XS-2XQ-IN** (8× SFP28, 2× QSFP28, half-depth 1U, RouterOS).

- Its data ports carry **VLAN 21 only**, `l2mtu` 9000, and **VLAN 21 never leaves the switch**. Its one link to the UniFi fabric is a **management uplink**: the MGMT RJ45 (or one port in its own bridge, isolated from the VLAN 21 bridge) on a vlan10 access port. VLAN 21 is never tagged on it and it is never bridged to the data ports.
- Each OSD host connects with **both ConnectX ports as an LACP (802.3ad) bond**, layer3+4 hash, MTU 9000, with the static VLAN 21 address on the bond.
- The switch is powered from the compute UPS with both PSU inputs connected, never through PoE from a fabric switch.
- The QSFP28 ports stay dark.

VLAN 20 (Ceph public) stays on the Pro-Agg, unchanged.

## Rejected alternatives

- **Stay on the Pro-Agg SFP28 ports (ADR 0014 as-is):** port-starved at three MS-01s plus growth, and it keeps replication inside the fabric's firmware/STP failure domain. Superseded.
- **A data uplink carrying VLAN 21 into the fabric:** it puts replication back inside the fabric's STP and firmware failure domain; the management uplink is the only allowed link. Rejected.
- **A second UniFi 25G switch uplinked into the fabric:** adoption and controller-driven firmware bring the same shared failure domain back. Rejected.
- **MikroTik CRS518:** over budget, 8 ports left unused, full-depth front-to-rear airflow in a cabinet with no rear access. Rejected.
- **Moving `public_network` onto the island as well:** it would put every Ceph client (Talos CSI legs, worklab) on the island and require an uplink. The island protects replication only, by design.
- **The switchless FRR mesh:** already rejected in ADR 0014; it does not extend to a fourth node.

## Consequences

- One flow sees at most 25G; the bond adds capacity and link redundancy, not a 50G stream. That fits Ceph: replication is many OSD↔OSD connections (one per peer pair, many PGs), so layer3+4 hashing spreads them across both links. `balance-rr` is rejected because a switch hashes per flow on egress, so striping past the first hop gains nothing and adds TCP reordering. A single DAC or port failure keeps replication up at 25G.
- The island is a single switch with no redundant partner. Its failure marks OSDs down and blocks replication until it is back. It does not fence anything and does not touch mons or clients (VLAN 20). Accepted, with no second switch planned.
- `proxmox_host` renders a bond for the ceph link (`ceph_nic` becomes a list), and `host-bindings.yaml` gains the second port per node. The RouterOS config is hand-managed and recorded in a runbook doc, like pfSense (ADR 0005), until a RouterOS provider is chosen.
- The UniFi `terraform/unifi` module drops VLAN 21 and the SFP28 access profile from the Pro-Agg, and those ports are freed: two for msi's 2×25G bond (ADR 0056), one for the mini-rack uplink, one for the future NAS. That leaves the Pro-Agg with no spare SFP28.
- Cutover is one node at a time under `noout`: cable both ports to the CRS510, re-render the interfaces, confirm OSD heartbeats on the bond, then take down the Pro-Agg port.
- A 25G port for the future all-flash NAS stays on the Pro-Agg (VLAN 20). Putting it on the island's QSFP28 would break "VLAN 21 only" and needs its own decision.
