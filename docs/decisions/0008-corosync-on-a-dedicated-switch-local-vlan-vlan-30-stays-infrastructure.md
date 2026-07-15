# ADR 0008 — Corosync on dedicated switch-local VLANs; VLAN 30 stays Infrastructure

- **Status:** Proposed
- **Date:** 2026-07-15
- **Deciders:** operator + agent
- **Context source:** ~/okf/brainstorm/ms01-cluster-network.md · docs/ms01-cluster-iac-plan.md (WP1/WP2) · session 2026-07-15 network-design thread

## Context

The MS-01 network design gave each node a dedicated 2.5G control-plane wire for corosync (i226-V), off the X710 data bond — correctly isolating corosync from storage/VM bursts, its worst enemy. But it placed corosync ring0 on **VLAN 30 (Infrastructure)** — the VLAN that already carries the Proxmox host web UIs and UniFi switch management — and, to free VLAN 30 for corosync, moved the host web UI to VLAN 40 (Services).

Corosync's failure mode is latency/jitter, not bandwidth: a jitter spike past the token timeout fences a node (and with HA, restarts its guests). A dedicated *wire* protects against heavy traffic, but sharing a *broadcast domain* with the management fabric still exposes corosync to STP topology changes, switch reboots, and re-adoption blips — and that fabric is precisely what this migration actively reconfigures (adopting the new aggregation switch, rewriting UniFi port profiles). The operator also noted VLAN 30's intended meaning is infrastructure maintenance, not corosync.

## Decision

Corosync gets its **own** dedicated, switch-local VLANs, and **VLAN 30 stays Infrastructure**:

- **VLAN 31 (Corosync ring0)** — tagged on the i226-V ports.
- **VLAN 32 (Corosync ring1)** — tagged on the i226-LM ports, alongside AMT (knet's second ring needs a distinct subnet).
- Both are **UniFi-only L2 islands on the 2.5G switch**: no gateway, no pfSense interface, no DHCP, and **not trunked on the switch uplink** — so corosync traffic never leaves the 2.5G switch. Nodes use static `172.16.31.x` / `172.16.32.x`, no gateway.
- **VLAN 30 remains Infrastructure** — host web UI / PVE API / mgmt + UniFi switch mgmt. The web UI does **not** move to VLAN 40; the i226-V provides the untagged VLAN-30 install/mgmt bootstrap IP, and VLAN 30 is carried tagged on the bond for redundancy.
- AMT (VLAN 10) and VLAN 30 **are** trunked on the 2.5G switch uplink so they stay reachable; only the corosync VLANs are intentionally stranded.

## Rejected alternatives

- **Corosync on VLAN 30 (ride Infrastructure).** Works in steady state — the dedicated i226-V wire shields it from storage/VM traffic — but shares a broadcast domain with switch mgmt + host UIs, the exact fabric churned during this migration; a re-adoption or STP event can false-fence a node. Also overloads VLAN 30's meaning and forces the web UI onto VLAN 40.
- **No dedicated corosync VLAN (untagged on the mgmt VLAN).** Same broadcast-domain exposure, no isolation, for no saving.
- **Route the corosync VLAN (trunk it upstream / give it a gateway).** Needless L3 exposure; corosync is L2-local to three ports — keeping it switch-local also means an aggregation-switch or pfSense reboot can't touch quorum.

## Consequences

- `network-data/vlans.yaml` gains VLAN 31 (`corosync`) + VLAN 32 (`corosync_ring1`): `managed_by: [unifi]`, `bridge: null` (not SDN VNETs), no gateway, `dhcp_enabled: false`.
- **2.5G switch config:** corosync VLANs tagged on the i226 ports and **excluded from the uplink**; AMT (VLAN 10) + mgmt (VLAN 30) trunked upstream. One uniform 2.5G port profile still works (native 30 + tagged 10/31/32).
- WP2 (`proxmox_host` role) brings up the tagged VLAN 31/32 sub-interfaces and points corosync ring0/ring1 at them; ring0 stays the isolated primary on i226-V.
- `install_nic_mac` targets the **i226-V** (VLAN 30 native install), not the i226-LM.
- **Revises the earlier "web UI → VLAN 40" note.** Host mgmt stays on VLAN 30, so the keepalived VIP + Terraform/Ansible endpoint (ADR-0001 placed them on VLAN 40) should move to VLAN 30 to sit with host mgmt, and `terraform/hosts/` should provision a host VLAN 30 interface on the bond rather than VLAN 40 — a follow-up to reconcile before the cluster bring-up (WP2/WP3).
- Corosync survives an aggregation-switch or pfSense reboot; only a 2.5G-switch reboot blips it.
