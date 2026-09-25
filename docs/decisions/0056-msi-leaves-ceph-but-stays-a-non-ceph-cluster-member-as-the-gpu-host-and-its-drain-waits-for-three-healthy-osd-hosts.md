# ADR 0056 — msi leaves Ceph but stays a non-Ceph cluster member as the GPU host, and its drain waits for three healthy OSD hosts

- **Status:** Proposed
- **Date:** 2026-09-15
- **Deciders:** operator + agent
- **Context source:** 2026-09-09 physical re-plan (council-tested) · session 2026-09-15: ms-01c hardware and a second Arc Pro B70 ordered, the ms-01a core-8 segfault test, the msi PCIe survey · NIC layout amended 2026-09-25 (M2_4 found free; the ConnectX-4 Lx stays)

## Context

msi (MPG Z690 Carbon, i9-14900K, 128 GB non-ECC at 2DPC) is the odd node out: a desktop platform with a history of resets and memory-training limits. It holds two Ceph OSDs, and it is also the only node with the PCIe lanes for the inference cards: VM 240 `llm` (ADR 0051) and VM 242 `mcp` (ADR 0052) already live there. The 2026-09-09 plan replaced it with an MS-01 and removed it from the cluster (`pvecm delnode`). Since then the operator has ordered a second B70 for msi, which makes msi a long-lived GPU host instead of a retiring box.

The PCIe survey (2026-09-15) found all three full-length slots in use. PCI_E1 (CPU Gen5, split x8/x8) holds B70 #1. PCI_E2 (CPU Gen5 x8) holds the 82599ES 10G bond, a Gen2 card. PCI_E3 (chipset Gen3 x4) holds the ConnectX-4 Lx, whose port 0 is the Ceph cluster network.

On the same day, ms-01a showed segfaults concentrated on one CPU core (core 8, from 2026-09-09) and has CPUs 4/5 offlined as a test. A warranty claim would take ms-01a out for weeks. Ceph runs `size=3` across hosts, so it needs three OSD hosts to keep three copies.

## Decision

msi leaves Ceph and stays a Proxmox cluster member with no OSDs, no mon and no Ceph cluster-network leg. It is the GPU host for `llm`, `mcp` and future AI-plane VMs, and it remains a **Ceph client**: its guests' disks stay on `ceph-rbd`, so it keeps its VLAN 20 (Ceph public) leg: on the 10G bond until the drain, then on the 2×25G bond. It needs no VLAN 21 leg and no port on the CRS518 (ADR 0057). Running OSDs again later is a new decision, not a re-enable.

Its network becomes one **2×25G LACP bond behind `vmbr0`**, carrying every VLAN the 10G bond carries today (Ceph public, services, guest VLANs) into **two Pro-Aggregation SFP28 ports** freed by ADR 0057. The 82599ES and its two 10G Pro-Agg ports are removed.

- **25G:** the **ConnectX-4 Lx already in PCI_E3** (chipset Gen3 x4, measured `Width x4 (downgraded)`) becomes the 2×25G bond. The slot caps it at ~31 Gb/s combined, about twice what a Ceph client whose LLM weights sit on local disk pulls. Until the drain, its port 0 keeps carrying VLAN 21 as today; after the drain both ports are re-cabled to the Pro-Agg as the bond.
- **Ring1 NIC (ADR 0058):** an **Intel I226-V M.2 card (B+M key, 2242)** in **M2_4** (root port `00:1d.0`, chipset Gen3 x4, supports 2242/2260/2280), empty today, so it does not wait for the drain. The chip must be Intel (`igc`), not Realtek RTL8125 (`r8169` ASPM link-drop history on Proxmox). The card's ribbon cable exits under the board's M.2 shield, so M2_4 runs with the shield off if it pinches the cable; the i226 needs no heatsink.
- **B70 #2:** PCI_E2, which gives both cards a CPU Gen5 x8 link. The 82599ES leaves PCI_E2 and is banked.

msi's OSDs are drained only when ms-01c is a healthy Ceph host **and** ms-01a is either cleared by the core-8 test or back from warranty. There are always three OSD hosts during the drain. The second B70 waits for that.

Drain order: ms-01c joins with all three OSDs first (one rebalance), then `ceph osd set noout`, `ceph osd out` msi's OSDs one at a time to `HEALTH_OK`, destroy them, and remove msi's mon/mgr if present.

## Rejected alternatives

- **`pvecm delnode msi` and a standalone PVE host (the 2026-09-09 plan):** it fully isolates a GPU fault from corosync. But `llm`/`mcp` would lose migration and PDM/cluster-API management, and would need a second provider endpoint and cert SAN like worklab. msi's resets are root-caused (PSU ECO switch), and a non-Ceph member cannot take replicas down with it. Rejected.
- **Drain msi as soon as ms-01c is healthy:** faster to the second B70, but a warranty trip for ms-01a would leave Ceph on two OSD hosts with no third copy for its whole duration. Rejected by the operator.
- **A Gen4 dual-SFP28 card (ConnectX-6 Lx class) on an M.2 riser, with the i226 in PCI_E3 (this ADR's original 2026-09-15 layout):** the full ~50 Gb/s, at about $200 plus a riser, and it waited for the drain to free an M.2 slot. Superseded 2026-09-25: M2_4 turned out to be free, which removed the "ring1 has no slot" objection to keeping the ConnectX, and ~31 Gb/s is ample for a Ceph client. It stays the upgrade path if msi ever pulls bulk data from Ceph above that, using a freed Gen4 M.2 slot.
- **ConnectX-4 Lx on the M.2 riser:** it gains nothing, because the card is Gen3 and any x4 slot holds it at ~31 Gb/s. Rejected.
- **The ring1 NIC in the Wi-Fi E-key slot:** it works (the AX210 is a PCIe card, not CNVi), but that socket sits under the rear I/O shroud and M2_4 is easier to reach. Kept as the fallback if M2_4 is ever needed for storage.
- **The 82599ES moved to PCI_E3 as the host bond:** a Gen2 x8 card in a x4 slot runs at ~14–16 Gb/s, half of what the ConnectX gives there. Rejected.
- **Keep the 10G bond for guests beside a 25G transfer link:** two bonds, two switch-port sets and two bridge models for one host. Folding everything into the 2×25G bond is simpler and faster. Rejected.
- **ConnectX in PCI_E2 (Gen3 x8) with B70 #2 in PCI_E3:** it trades GPU link width for NIC width. Rejected.
- **B70 #2 in PCI_E3 (chipset Gen3 x4):** it works for layer-split and one-model-per-card, but it throttles load time and rules out tensor parallelism, while PCI_E2 is freed by removing a Gen2 card. Rejected.

## Consequences

- The cluster has four corosync votes (three MS-01s + msi), quorum 3. Losing msi and one MS-01 at the same time loses quorum. Accepted: msi no longer carries replicas, and a 4-vote cluster tolerates one node down like the current three.
- msi needs a ring1 port on the Flex (ADR 0058) like every other member.
- Purchases: an Intel I226-V M.2 card (B+M key, 2242) and two SFP28 DACs. No 25G card or riser.
- `host-bindings.yaml` for msi: bond members move from nic1/nic2 (82599ES) to the ConnectX-4 Lx ports, a ring1 NIC (the M2_4 i226) is added, `ceph_nic` and `osd_disks` are removed, and `terraform/hosts` and the UniFi port map follow. The Pro-Agg ports freed by the 82599ES DACs are recorded in the port map.
- msi's power budget changes: two B70s plus a 253 W CPU is near the EVGA 850 G5's limit. A PSU upgrade (1000–1200 W) or enforced CPU/GPU power caps is a prerequisite for installing B70 #2.
- msi's 2× 990 PRO 2 TB are freed for a future node 4. msi's memory-tuning experiments (4800 at 1.1 V) become possible once it holds no replicas.
- ADR 0051's "240 stays a VM until msi leaves Ceph, then an LXC is revisited" becomes due after the drain.
