# ADR 0010 — Per-VLAN IPv6: GUA tracks the VLAN ID, ULA carries stable internal services

- **Status:** Accepted
- **Date:** 2026-07-27
- **Deciders:** operator (interview 2026-07-27)
- **Context source:** live audit of pfSense, Terraform, and the VM fleet (session 2026-07-27)

## Context

IPv6 was configured by hand against an ISP that publishes no deployment guide, and the resulting scheme existed only on the wire — no ADR, no doc, no mention in `CLAUDE.md`. That made it impossible to tell intent from drift: three VLANs have no IPv6 at all, the Terraform module derives a per-VLAN ULA that almost nothing uses, and `network-data/vlans.yaml` carries a `ipv6_prefix` whose relationship to the ISP-delegated prefix is unstated.

An audit established that the deployed scheme is in fact coherent and already per-VLAN on both address families, mirroring the IPv4 convention. The gaps are documentation, one address-family asymmetry in filtering, and one regression that had been silently degrading every IPv6 client on the network.

That regression: the VM module suppressed `accept_ra` on any interface carrying a static IPv6 offset. Router advertisement is the only source of an IPv6 default route here, so the single VM configured that way — the DNS server — was stranded inside its own /64. It could not reach IPv6 upstreams and could not reply to clients on other VLANs. Because pfSense advertises that host's ULA as the RDNSS for the whole network, every IPv6-capable client was pointed at a resolver that could not answer it, and fell back to IPv4 only after a timeout. IPv6-only devices (Thread/Matter) had no fallback at all.

## Decision

The addressing scheme is recorded as intentional and becomes the documented convention:

- **GUA — one /64 per VLAN, prefix ID = VLAN ID.** Every IPv6-enabled interface takes `track6` from the WAN's delegated prefix with the prefix ID set to the VLAN ID in hex, so VLAN 40 lands on `<delegated>:<...>28::/64`. This mirrors the IPv4 third-octet-equals-VLAN-ID convention.
- **ULA — one /64 per VLAN, derived in Terraform.** `modules/network` computes `<ula-prefix>:<vlan_id_hex>::/64` for every VLAN. The ULA is the addressing for services that need an address independent of the ISP delegation.
- **The DNS server is the one host with a static IPv6 address**, on the ULA, advertised to the fleet as RDNSS. Every other host takes its GUA from DHCPv6/SLAAC. A ULA address survives an ISP prefix rotation; a GUA does not, and the resolver is the one address whose churn would break the whole network at once.
- **MGMT (10), INFRASTRUCTURE (30) and OPENCLAW (140) are deliberately IPv4-only.** These are internal planes; a globally routable address on the management network buys nothing and widens exposure. Their absence from the v6 fabric is intent, not drift.
- **A static IPv6 offset never implies "do not accept RA".** The two are orthogonal: the offset fixes the address, the RA supplies the default route. Suppressing RA on a statically-addressed interface strands it.
- **The pfSense side stays hand-managed and documented in `docs/ipv6.md`**, per ADR 0005. Prefix delegation, `track6` prefix IDs, RA/RDNSS/DNSSL and the IP blocklists are firewall configuration, and pfSense IaC remains deferred.
- **IP-level blocklists must be symmetric across address families.** A v4-only blocklist is bypassable over v6 by any client that resolves a AAAA.

The literal delegated prefix is a geolocatable identifier and **must not appear in a tracked file** — this repo is public. Documentation describes the scheme structurally; concrete values live in gitignored `network-data/`.

## Rejected alternatives

- **Drop the ULA and run GUA only** — simpler, one address family, but every internal address including the resolver churns when the ISP rotates the delegation. The resolver address is exactly the one that must not move.
- **Give the resolver a static GUA instead of a ULA** — reachable and simpler to explain, but reintroduces the prefix-rotation failure and puts a routable address on the one host every client depends on.
- **Remove the resolver's IPv6 listener and serve DNS over IPv4 only** — considered because DNS transport is independent of the record families returned, so dual-stack clients would be unaffected. Rejected: pfSense advertises an RDNSS, so removing the listener points every client at a dead resolver, and IPv6-only Thread/Matter devices have no IPv4 path at all.
- **Extend IPv6 to all VLANs for uniformity** — uniformity is not a goal that outranks keeping the management plane off the global routing table.
- **Bring the pfSense IPv6 config under Terraform** — already rejected in ADR 0005 and not reopened here.

## Consequences

- The VM module now accepts RA on every IPv6-enabled interface unless IPv6 is explicitly disabled. Only one VM was affected; no other VM sets a static IPv6 offset.
- Because the module's cloud-init network data is under `lifecycle.ignore_changes`, the Terraform fix reaches existing VMs only on rebuild. The running host was corrected in place; any VM that later adopts a static IPv6 offset gets the correct behaviour from first boot.
- The delegated prefix becomes load-bearing undocumented state. `docs/ipv6.md` carries the rotation runbook; if the ISP changes the delegation, every GUA /64 moves and the `track6` prefix IDs must be re-verified.
- Enabling IPv6 blocklists increases the filtering table size and adds a second auto-generated alias and rule.
- Adding IPv6 to an excluded VLAN later is a deliberate reversal of this ADR, not a config tweak.
