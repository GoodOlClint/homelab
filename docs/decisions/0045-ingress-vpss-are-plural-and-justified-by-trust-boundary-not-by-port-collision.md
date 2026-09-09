# ADR 0045 — Ingress VPSs are plural and justified by trust boundary not by port collision

- **Status:** Proposed
- **Date:** 2026-08-29
- **Deciders:** operator + agent
- **Context source:** generalizes [ADR 0013](0013-vps-tunnel-peers-over-reserved-ipv4-mtu-is-measured-per-address-family.md) (the single relay, measured MTU) · consumed by [ADR 0044](0044-a-declared-ingress-mode-per-service-drives-the-public-dns-record-and-nothing-else.md) `mode = vps` · pfSense stays hand-managed per ADR 0005 · plan: [docs/ingress-policy-plan.md](../ingress-policy-plan.md)

## Context

One Vultr instance relays every inbound service: Plex, Jellyfin, Valheim and mobile WireGuard, DNAT'd over a single WireGuard tunnel to pfSense. `WG_VPS:443` is already claimed by Traefik.

That becomes a hard constraint once a guest terminates its own TLS (ADR 0044, `tls = "self"`). One public IP, one port, N hostnames, N certificates — a second own-TLS backend cannot have `:443` on that path. The Case Project guests are exactly that shape.

The first proposal was HAProxy SNI passthrough **on pfSense**. It was rejected on review: it puts a new load-bearing component on a hand-managed appliance with no API in this repo, and one with existing scar tissue around MTU overrides in two places and stale `if-bound` pf states.

An objection was raised against every proxy-based option — that proxying costs the real client IP — and was **disproved by reading the ruleset**. `vps_nftables` ends with `oifname wg0 masquerade`: every relayed connection is already SNAT'd, so backends have always seen the tunnel address rather than the visitor. Per-source rate limiting still works because the meter runs in the `forward` chain, ahead of postrouting. Client IP is not a differentiator between any of these options.

## Decision

1. **The VPS role becomes plural.** `for_each` over a `vps_instances` map replaces the singular `vultr_instance.vps` / `vultr_reserved_ip.vps` / `vultr_firewall_group.vps`; `ansible/inventory/vps.yaml` becomes a group; `vps_wg_tunnel` becomes a map keyed by instance; the WireGuard private key becomes one Infisical entry per instance. The Ansible roles need no change — they are already parameterized.
2. **A second reserved IP is how the `:443` collision is solved.** Its own address means its own `:443`. pfSense stays a dumb pass-through and gains no new component.
3. **The governing rule: a new ingress VPS is justified by a trust boundary, not by a port collision.** Small N — `media` (the existing relay) and `case` — never one per service.
4. **Where several own-TLS backends do share one VPS, the SNI-routing TCP proxy runs on that VPS.** It is Ansible-managed like the rest of the role and needs no hand step. SNI routing never goes on pfSense.
5. **The existing relay keeps its name and reserved IP.** The media path is not rebuilt as part of this work; the refactor's acceptance bar is a zero-change plan.
6. **`make vps-deploy` / `vps-rebuild` / `vps-ansible` gain a `VPS=<name>` selector**, defaulting to all.

## Rejected alternatives

- **HAProxy SNI passthrough on pfSense.** A new load-bearing package on an appliance with no API, hand-managed per ADR 0005, removed by every pfSense upgrade (the NUT and ACME precedents), on the path carrying all inbound traffic.
- **Distinct ports per own-TLS backend** (`:8443`, `:9443`). Zero new components, but corporate and hotel networks routinely block non-standard ports — which defeats the remote-testing case this exists to serve.
- **One VPS per exposed service.** Linear recurring cost and, worse, a linear pfSense hand-step burden. Rule 3 exists to prevent this.
- **Terminating TLS at the VPS** rather than passing SNI through. Would put private keys on a rented box outside the trust boundary, for no gain.

## Consequences

- **~$6/month per additional VPS**, recurring. Rule 3 is the cost control; without it the pattern drifts.
- **Each new VPS is a pfSense hand step**: WireGuard peer, interface assignment, MTU override in *both* the tunnel config and the interface override, firewall and NAT rules. This is the dominant cost and does not go away.
- **MTU must be measured on each new path, never copied.** ADR 0013 is explicit that the number is measured per address family; a second tunnel to a different region is a different path, and the failure mode is a silent blackhole.
- **Trust-boundary isolation is gained**: abuse complaints, blacklisting or a DDoS against the Case edge leave the media path untouched, and `make vps-rebuild` on one edge no longer takes down Plex, Jellyfin and mobile WireGuard together.
- **The `for_each` refactor is the dangerous step, not the exposure.** Reindexing existing resources would destroy and recreate the live relay; `moved` blocks and a zero-change plan are the gate, and the `will be destroyed` list must be read before any apply.
- N× hardening and patching surface, and one tunnel subnet to allocate per instance.
