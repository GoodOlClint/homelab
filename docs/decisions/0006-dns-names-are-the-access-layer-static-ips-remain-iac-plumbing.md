# ADR 0006 — DNS names are the access layer, static IPs remain IaC plumbing

- **Status:** Proposed
- **Date:** 2026-07-10
- **Deciders:** operator (interview 2026-07-10)
- **Context source:** docs/ms01-cluster-iac-plan.md · operator: "the primary reason for static IPs was having to access everything via IP"

## Context

Historically everything is reached by IP because internal DNS coverage is partial — BIND9 holds internal zones and AdGuard carries hand-curated rewrites for a handful of VMs, but most guests never get a name. Static IPs became the access mechanism, not just the plumbing. The migration doubles the fleet's moving parts (three nodes, a VIP, ~20 guests, redundant DNS per ADR 0003), which makes IP-based access untenable and name-based access finally reliable.

## Decision

Every guest, node, and the cluster VIP gets a DNS record **generated from the IaC inventory** — the BIND zone files are templated from the Terraform-generated inventory plus the node/VIP list, so a guest cannot exist without a name. AdGuard forwards the internal zones to BIND (both instances, per ADR 0003). Names are the canonical way humans and services address the homelab: homepage links, monitoring targets, inter-service URLs, and docs use names. Static IPs stay exactly as they are in the IaC layer: `ansible_host` remains an IP (Ansible must work while DNS is being rebuilt), Terraform keeps `vm_id → static IP`, and bootstrap never depends on the DNS it deploys.

## Rejected alternatives

- **DHCP + dynamic DNS as the access story** — reintroduces the lease-churn fragility ADR 0003 rejected, and makes DNS a dependency of addressing instead of a product of it.
- **Keep hand-curated AdGuard rewrites per service** — the current model; doesn't scale past a handful of names and silently drifts (the hyphen/underscore rewrite bug already bit once).
- **Names in Ansible inventory (`ansible_host: <fqdn>`)** — circular dependency: config management would need the DNS it manages; kept IP-based deliberately.

## Consequences

- The `dns` role gains zone-generation from inventory; records appear/disappear with `make apply` — no manual zone edits for guests. AdGuard's parameterized rewrite machinery shrinks to genuinely special cases.
- Service configs (homepage, monitoring, inter-service URLs) migrate from IPs to names during WP4 rebuilds.
- Name-based access makes TLS warnings the next irritation — drives ADR 0007 (certs for all hosts).
- Public-repo discipline (WP6) extends to generated-zone tooling: zone data derives from gitignored bindings; templates stay abstract.
