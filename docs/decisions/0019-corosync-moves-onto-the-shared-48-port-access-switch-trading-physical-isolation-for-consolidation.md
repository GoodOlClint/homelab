# ADR 0019 — Corosync moves onto the shared 48-port access switch, trading physical isolation for consolidation

- **Status:** Accepted
- **Date:** 2026-08-07
- **Deciders:** operator + agent
- **Context source:** docs/physical-buildout-plan.md · session 2026-08-07 rack-staging thread · supersedes [ADR 0008](0008-corosync-on-a-dedicated-switch-local-vlan-vlan-30-stays-infrastructure.md)

## Context

ADR 0008 put corosync VLANs 31/32 on a standalone UniFi Flex-2.5G mini switch, off-cabinet, specifically so corosync's fault domain never overlaps the general access/aggregation fabric — the ADR's own consequence: "Corosync survives an aggregation-switch or pfSense reboot; only a 2.5G-switch reboot blips it."

While staging the SRW15US rack build-out (hardware being bought now, while the cabinet is on the ground), the operator is buying a 48-port PoE access switch with built-in 2.5G ports to future-proof the rack — it replaces the separate USW-Pro-24-PoE and absorbs the Flex-2.5G's port capacity too, eliminating a discrete off-cabinet switch and giving real expansion headroom. Racking corosync's 2.5G ports on this switch instead of a dedicated unit reintroduces the coupling ADR 0008 was written to avoid: a reboot, firmware push, or re-adoption event on the 48-port switch — which now also carries PoE/access/camera/AP traffic and gets touched far more often than a set-and-forget dedicated switch — can once again jitter or fence a Ceph node, the same failure mode ADR 0008's rejected "corosync on VLAN 30" alternative described.

## Decision

Corosync VLANs 31/32 move onto the new 48-port PoE access switch. The Flex-2.5G is dropped from the build — no third switch. VLAN isolation stays exactly as ADR 0008 specified (31/32 switch-local, non-trunked, no gateway); only the physical switch they live on changes.

Operator accepted the reintroduced physical-switch coupling risk in exchange for one less physical switch to rack, wire, and power, and the 48-port switch's expansion capacity making a dedicated corosync switch unnecessary going forward.

## Rejected alternatives

- **Keep the dedicated Flex-2.5G (ADR 0008's model).** Preserves full physical isolation — corosync's only exposure stays "a 2.5G-switch reboot." Rejected because it needs a fourth off-cabinet switch alongside gear already being consolidated, and the operator judged the isolation less valuable than the simplification now that the 48-port switch has the port capacity anyway.

## Consequences

- `network-data/vlans.yaml`'s VLAN 31/32 definitions (`managed_by: [unifi]`, `bridge: null`, no gateway, `dhcp_enabled: false`) carry over unchanged — only which physical switch carries the tagged i226 ports changes.
- **Corosync's fault domain widens.** A reboot, firmware update, or re-adoption blip on the 48-port switch can now jitter/fence corosync rings — previously only a dedicated 2.5G-switch event could do that. Accept this consciously when scheduling switch firmware/config work post-migration; avoid touching the 48-port switch during any window where node fencing would be disruptive.
- `docs/physical-buildout-plan.md`'s rack elevation and off-cabinet gear list update to drop the Flex-2.5G and note the 48-port switch at RU14 carries corosync in addition to general access/PoE.
- `CLAUDE.md`'s "In flight" ADR list (line 7, "ADRs 0001–0009 + 0014") gains this ADR — see back-link below.
- WP2 (`proxmox_host` role) and the UniFi Terraform module (`modules/unifi-network/`, ADR 0005) target the 48-port switch's port profiles for VLAN 31/32 instead of a separate Flex-2.5G port profile — reconcile before WP5 UniFi apply.
