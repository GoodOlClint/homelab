# ADR 0005 — UniFi network config under Terraform now, pfSense IaC deferred

- **Status:** Proposed
- **Date:** 2026-07-10
- **Deciders:** operator (interview 2026-07-10)
- **Context source:** docs/ms01-cluster-iac-plan.md · ~/okf/brainstorm/ms01-cluster-network.md (switch port budget)

## Context

The UniFi fabric has never been in IaC — the physical layer only exists as a live-controller capture in the operator's OKF notes. The cluster migration replaces the aggregation switch, and the new switch needs greenfield config on day 0: VLANs, port profiles, LACP aggregation for the node bonds and the NAS LAG, jumbo on the storage VLAN. The repo already loads the `ubiquiti-community/unifi` Terraform provider (discovery only today). The same "managed from the beginning" argument that applies to the MS-01 hosts applies here: the greenfield moment for the new switch never comes back. The operator also wants pfSense under IaC eventually.

## Decision

The new aggregation switch is configured through Terraform from first adoption — no hand-provisioned config. A new `modules/unifi-network/` (main project, provider already present) manages: networks/VLANs sourced from the gitignored `network-data/vlans.yaml` (bindings stay out of git), port profiles (trunks for node bonds, NAS LAG, corosync access ports), port overrides/aggregation for the specific switch ports, and jumbo MTU on the storage VLAN. Port-to-device assignments live in a gitignored bindings file alongside `vlans.yaml`. **pfSense IaC is deferred** to a post-migration phase: firewall rules, DHCP resolver options, and WireGuard config stay hand-managed (documented in `docs/`) for this migration; the deferred work is recorded in the plan's future-work section.

## Rejected alternatives

- **Hand-configure the switch, import into Terraform later** — import chores reliably slip; drift accumulates from day one; the whole point of the migration is ending hand-managed infrastructure.
- **pfSense IaC in the same migration** — no greenfield moment forcing it (the pfSense box isn't being replaced), the migration is already multi-day, and the ecosystem choice (pfsensible Ansible collection vs a REST-API Terraform provider requiring the pfSense-API package) deserves its own evaluation.
- **Config in the UniFi controller as source of truth, exported to docs** — that is the status quo the operator explicitly wants away from.

## Consequences

- Day-0 sequencing gains a step: adopt the new switch → `terraform apply` the UniFi module → then cable nodes. Adds hours to the hardware day; accepted.
- The UniFi provider becomes load-bearing (was discovery-only); its auth (controller admin credential) joins the bootstrap secrets.
- Existing switches/ports (Pro-24, Flex) are NOT retroactively imported in this migration — only the new switch and migration-touched ports; full-fabric adoption is future work with pfSense.
- pfSense DHCP change for the redundant-DNS decision (ADR 0003 — handing out both resolver IPs) is a documented manual step this round.
