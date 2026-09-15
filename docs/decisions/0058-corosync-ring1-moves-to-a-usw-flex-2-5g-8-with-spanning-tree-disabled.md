# ADR 0058 — Corosync ring1 moves to a USW-Flex-2.5G-8 with spanning tree disabled

- **Status:** Proposed
- **Date:** 2026-09-15
- **Deciders:** operator + agent
- **Context source:** the 2026-09-09 fleet-wide HA fence (Pro-Aggregation auto-firmware reboot) · 2026-09-09 physical re-plan · session 2026-09-15 · amends [ADR 0019](0019-corosync-moves-onto-the-shared-48-port-access-switch-trading-physical-isolation-for-consolidation.md)

## Context

ADR 0019 moved both corosync rings onto the shared UniFi fabric: ring0 on VLAN 31 on the USW-Pro-Max-48, and ring1 on VLAN 32 (a dedicated NIC, or msi's bond). On 2026-09-09 a scheduled firmware update rebooted the Pro-Aggregation, the fabric root. STP reconvergence stalled every VLAN past corosync's token timeout, and both watchdog-armed nodes fenced. Both rings were downstream of the same STP root, so the second ring gave no independence. VLAN separation held; the shared control plane was the fault.

Auto-firmware on the fabric is now verified off (2026-09-12), but a manual roll or topology change can cause the same stall. The operator already owns a fanless USW-Flex-2.5G-8.

## Decision

Ring1 moves onto the **USW-Flex-2.5G-8**. Each cluster member (ms-01a/b/c and msi, ADR 0056) connects one 2.5G port **untagged on VLAN 32**, using the existing `corosync_ring1` access profile.

- The Flex is **adopted with device-level Spanning Tree disabled** and `stp_port_mode = false` on the ring1 profile. Auto-update stays off.
- Its uplink is **one vlan10 access port, used for management only**; VLAN 32 is never carried on it. That way a fabric reconvergence cannot touch ring1 traffic.
- It is **DC-powered from the compute UPS**, never PoE from a fabric switch.
- Ring0 stays on VLAN 31 on the Pro-Max-48. Ring numbering is unchanged.
- The corosync token rises to **5000 ms**.

msi has one onboard copper port (I225-V, which carries mgmt and ring0), so msi's ring1 moves off the bond sub-interface (`vmbr0.32`) onto an **Intel i226-class PCIe card in PCI_E3**, freed when the 25G card moves to the M.2 riser (ADR 0056), not onto a USB NIC. Until that card is fitted, msi keeps ring1 on `vmbr0.32`. That is acceptable only while msi's LRM holds no HA services (idle, verified 2026-09-15): a node with no active HA services has no armed watchdog and cannot fence.

## Rejected alternatives

- **Keep both rings on the fabric (ADR 0019 as-is):** 2026-09-09 showed the rings share one STP failure domain. Rejected.
- **A fully unmanaged ring1 switch:** no telemetry and no port state in the controller. Adoption with STP off keeps visibility without joining the STP domain. Rejected.
- **Run ring1 over the CRS510 island (ADR 0057):** it would put cluster membership in the same failure domain as replication and break the island's "VLAN 21 only" rule. Rejected.
- **Renumber the rings so that ring0 is the isolated one:** it rewrites `corosync.conf` for no functional gain. Rejected.
- **Token 10000 ms:** it slows detection of a genuinely dead node for HA. 5000 ms covers switch reboots and is still well under the watchdog timeout. Rejected.

## Consequences

- STP is off on the Flex, so a patching loop on it would broadcast-storm ring1. No cable ever connects two Flex ports, and VLAN 32 never leaves the Flex. Ring0 survives a ring1 storm.
- `unifi-ports.yaml` / `terraform/unifi` gains the Flex device, its ring1 ports and its STP setting; the old ring1 overrides on the Pro-Agg trunk and Pro-Max come out.
- The corosync link change is one node at a time (`pvecm` link update via the `proxmox_host` cluster tasks). Quorum is verified after each node, with HA parked for the change window.
- The Flex has 8 ports: 4 cluster members plus a node 4, the vlan10 uplink, and 2 spare.
