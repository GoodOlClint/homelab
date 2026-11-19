# ADR 0064 — The CI cluster nodes sit on a dedicated ci-runner VLAN filtered at pfSense

- **Status:** Proposed
- **Date:** 2026-11-19
- **Deciders:** operator + Claude
- **Context source:** brownfield gate for [ADR 0062](0062-arc-moves-off-the-services-cluster-onto-a-dedicated-two-node-ci-cluster-with-the-github-app-key-kept-from-job-nodes.md); plan in [docs/ci-cluster-plan.md](../ci-cluster-plan.md)

## Context

ADR 0062 requires that test guests cannot reach the job node. Traffic inside one VLAN never passes pfSense, so putting the job node on the `ci` VLAN beside the guests it creates leaves it reachable. Terraform here manages no Proxmox firewall, security group or ipset.

## Decision

Both CI cluster nodes sit on a new `ci-runner` VLAN. pfSense, hand-managed as for every VLAN, is the filter. Allowed out of the VLAN: DNS, the internet (GitHub and image registries), the Proxmox API port on the hypervisor VLAN, and the `ci` VLAN. Everything else internal is blocked. Nothing from the `ci` VLAN is allowed in. The operator workstation reaches the Talos and Kubernetes API ports on the VLAN. The existing allow from the `ci` VLAN to `talos-cp-a` is deleted at cutover.

## Rejected alternatives

- **The existing `ci` VLAN with the Proxmox per-NIC firewall** — no new VLAN, but it adds Proxmox firewall management to Terraform, a new subsystem to build and test for one guest.
- **Job node on a new VLAN, protected node on the hypervisor VLAN** — stronger separation of the key-holding node, at the cost of two rule sets and a pinhole from the job VLAN into the hypervisor VLAN.

## Consequences

- Operator hand steps: the VLAN in `vlans.yaml`, the pfSense interface and rules, the switch trunks, and the SDN VNET.
- The job node and the protected node share a layer-2 segment. The protected node exposes only the Talos and Kubernetes API ports, both of which need client certificates.
- BIND must answer the new subnet for the `ci.<service domain>` zone so jobs can resolve their test guests.
- `docs/pfsense-ci-vlan.md` gains the new rule table and loses the `talos-cp-a` rule.
