# ADR 0030 — Three management planes: vlan10 out-of-band, vlan30 hypervisor (PDM, PBS, apt-cache, pxe), vlan40 services

- **Status:** Accepted
- **Date:** 2026-08-22
- **Deciders:** operator + agent
- **Context source:** migration-remaining review session 2026-08-22 ([docs/migration-remaining-2026-08-22.md](../migration-remaining-2026-08-22.md))

## Context

[ADR 0017](0017-guests-are-single-homed-on-the-services-vlan-storage-reaches-containers-via-host-bind-mounts.md) made VLAN 10 "the network plane — zero guests, zero client-reachable services". Since then unifi 200 was greenfield-replaced on `.10.10` (its inform address and DHCP option 43 are baked into every adopted device), the JetKVMs live there, and three new control-surface services need a home: MeshCentral (AMT console, decided 2026-08-17 so it is not laptop-local), the Portainer server (already in the homepage stack but never reachable — no DNS record, no agents), and Proxmox Datacenter Manager. Each of these *manages* other planes and must not be reachable *from* the planes it manages.

Intel AMT cannot 802.1Q-tag (AMT 6.0+ dropped `VLANTag`); it always rides the native VLAN of the install NIC's switch port, which is VLAN 30 today.

## Decision

Three planes, each with an explicit ingress policy:

- **VLAN 10 (mgmt) = out-of-band plane. Ingress only from the operator's management devices.** JetKVMs, AMT, UniFi, switch/AP management, and one **`control` VM (MeshCentral + Portainer server)**. Guests here initiate outbound to what they manage (MeshCentral → AMT, Portainer → agents); nothing on VLAN 30 or 40 initiates toward VLAN 10.
- **VLAN 30 (infrastructure) = hypervisor plane.** Nodes, the keepalived VIP, and the guests that exist to run or bootstrap the hypervisors: **PDM** (human pane; consumes the PVE API, is never in the IaC/API path — Terraform, Ansible and CI all talk to the VIP), **PBS** (keeps its vlan20 NAS leg), **apt-cache**, **pxe** (already serves the VLAN 30 install link). Ingress from VLAN 10 and from named guest rules only: `40 → 30:8007` (every guest's `pbs_client`), mcp and the CI runner to `:8006` ([ADR 0032](0032-ci-runners-are-ephemeral-and-build-their-own-guests-inside-a-pve-pool-on-an-isolated-vlan-and-the-mac-studio-is-a-separate-trust-tier.md)).
- **VLAN 40 (services) = client-reachable plane.** The Talos cluster ([ADR 0031](0031-a-three-node-talos-kubernetes-cluster-becomes-the-services-plane-and-the-bootstrap-tier-stays-on-proxmox.md)) plus the Proxmox-resident guests clients must reach directly: adguard/dns pairs (resolver VIPs), plex, infisical, the LLM VM, the games host. Nothing management-shaped lives here.
- **The node install/AMT port moves to native VLAN 10 with the host's mgmt address tagged 30**, so AMT lands on the out-of-band plane without tagging (AMT cannot tag). The answer-file install link and `terraform/hosts/` still never touch the API-carrying interface.
- Portainer: the server moves out of the homepage stack onto the `control` VM; every docker host runs a `portainer_agent`; `portainer.<zone>` gets its BIND record from the inventory (ADR 0006).

This amends ADR 0017's "zero guests on VLAN 10" and "every guest on VLAN 40" to the plane rules above; single-homing (one leg per guest, PBS's vlan20 leg excepted) is unchanged.

## Rejected alternatives

- **MeshCentral/Portainer on the services VLAN** — puts a console that reaches AMT/KVM/all docker sockets on the same plane as the services it controls; a compromised service guest could reach it.
- **Keep AMT on VLAN 30** — works with one firewall rule, but leaves out-of-band console access on the hypervisor plane, which is exactly the plane that should not be reachable when a node is being recovered.
- **PDM on VLAN 10** — it is hypervisor management, not out-of-band; placing it beside the nodes keeps all PVE-API consumers on one plane.
- **PBS on VLAN 10** — every guest's `pbs_client` and every node's vzdump would need ingress into the out-of-band plane, defeating its one rule.
- **Fold MeshCentral into docker 204** — one fewer guest, but places an out-of-band console on a games host on VLAN 40.
- **PDM as the IaC endpoint instead of the keepalived VIP** — PDM is a human pane; it is not a PVE API proxy. The VIP stays the Terraform/Ansible endpoint (ADR 0008).

## Consequences

- New `control` VM (vlan10, class S): MeshCentral + Portainer server, role `control`. PDM VM on vlan30, role `pdm`, Debian 13 pinned image per the ADR 0025 pattern.
- PBS, apt-cache and pxe re-home to vlan30 via `make rebuild` with `vlans` changed (PBS's LUN datastore survives — `--reuse-datastore`; `make backup-finalize` re-points the cluster entry). The pending apt-cache/pxe greenfield-replaces happen once, directly onto vlan30.
- New `portainer_agent` role applied to every docker host; homepage role drops the Portainer service and Caddy route (the TODO in `homepage/tasks/main.yml` closes).
- `vlans.yaml` / pfSense: vlan10 ingress policy; `10 → 30:16993/16995` is not needed once AMT is on 10. Node switch ports: native 10 + tagged 30 — a `terraform/unifi/` profile change plus a host `interfaces` change done one node at a time, never over the API-carrying link (ADR 0002).
- The host mgmt re-home is a per-node maintenance action (mgmt address on `vmbr0.30` instead of untagged); sequence it with the Secure Boot conversion so each node is touched once.
- CLAUDE.md: amend the ADR 0017 summary line and the "dual-homed" note.
