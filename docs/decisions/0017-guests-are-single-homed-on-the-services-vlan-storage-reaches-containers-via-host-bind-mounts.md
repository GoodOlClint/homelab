# ADR 0017 — Guests are single-homed on the services VLAN; storage reaches containers via host bind mounts

- **Status:** Accepted
- **Date:** 2026-07-28
- **Deciders:** operator + agent (session 2026-07-28)
- **Context source:** docs/rebuild-as-routine-design.md · vm-configs.tf dual-homing · CLAUDE.md routing-policy trap

## Context

Every guest today is dual-homed: a VLAN 10 "management" leg (SSH/Ansible, `ansible_host`) plus a VLAN 40 services leg, and storage consumers add a VLAN 20 leg for their own NFS mounts. The intended benefit — clients can't reach the SSH/admin plane — is actually enforced by pfSense rules, not by the extra NIC; and since *every* guest sits on VLAN 10, a compromised guest is already L2-adjacent to every other guest's management leg, so the split provides near-zero east-west isolation. Meanwhile the costs recur constantly: the source-based `/32` routing-policy bug class (What Never To Do), dual IP/MAC/DNS identities per guest (`ansible_host` vs `service_ip`, cross-VLAN prefix translation, AdGuard cross-VLAN rewrites), and — new with the LXC fleet — no way to express policy routes in container `ip_config` at all. Separately, unprivileged LXCs cannot mount NFS themselves, so per-guest storage legs were never viable for the container fleet anyway.

## Decision

**In the post-MS-01 end state, guests are single-homed on the services VLAN (40).** The management VLAN 10 becomes a pure network plane — pfSense, UniFi controller, switch/AP management, AMT — carrying **zero guest legs and zero client-reachable services**. Admin access to guests (SSH, admin UIs) is enforced by pfSense port rules on VLAN 40 (allowed only from the network/operator plane) plus per-guest PVE firewall rules for east-west tightening. Ansible connects to the services-VLAN address; `vm_id` derives the guest IP on VLAN 40 directly.

**Storage reaches containers via host bind mounts, not guest NICs.** Each node mounts the NAS exports on its own VLAN 20 leg (MTU 9000, centralized `nfs_mount_options`, mounted identically on all nodes by the host role); containers get directory mount points with the `shared` flag so restart-migration keeps working. Guest disks live on Ceph, whose public/cluster networks (VLAN 20 / VLAN 21) never touch a guest NIC. A single fleet-wide media owner UID/GID convention (NAS ↔ host ↔ container PUID/PGID) replaces per-container idmap fiddling.

**Whole-fleet exceptions:** PBS keeps a VLAN 20 leg (a VM whose datastore is NFS on the NAS — VMs can't bind-mount host paths, and layering the PBS chunk store over virtiofs-over-NFS is fragile). That is the complete list.

**Fleet-relevant VLAN plan changes decided with this:** AdGuard + BIND stay on VLAN 40 (placing the one service every untrusted client must reach inside the network plane's L2 was rejected); the Ceph cluster VLAN renumbers **33 → 21** (adjacent to storage 20; free now because nothing is cabled — amends ADR 0014's numbering, not its substance); VLAN 140 (openclaw) is deleted and **squid retires with it** (its purpose was transparent interception of that staging VLAN); VLAN 50 (media) is deleted (unused by the fleet — Plex serves from 40); VLAN 1 (UniFi adoption) and the VPS tunnel subnet (91) get formalized as `vlans.yaml` entries.

## Rejected alternatives

- **Keep the per-guest management leg.** Its security value (blocking clients from admin ports) is one firewall rule either way, and with all guests on the same mgmt VLAN it never provided guest-to-guest isolation. The recurring costs (policy-routing bug class, dual identities, LXC route-delivery gap) all trace to it.
- **Per-guest storage legs with in-guest NFS clients.** Impossible for unprivileged LXCs (no mount capability), and for VMs it duplicates client tuning per guest while exposing the NAS's whole admin surface on L2 to every media consumer. A bind mount exposes one subtree and no network path at all.
- **AdGuard/BIND on the network VLAN 10.** Conceptually "network services", but it re-introduces guest workloads onto the cleared plane and opens port 53 from every untrusted VLAN into the L2 that holds pfSense and the switch UIs.
- **Apple TVs / media clients moved to a dedicated VLAN now.** Real but second-order security win, purchased with first-order AirPlay/HomeKit cross-VLAN friction. Deferred: revisit when Sonos goes wired (port-level isolation then lets VLAN 121 fold into IoT 120, the natural moment for a consolidated media-client VLAN).
- **Retiring pfSense-down SSH adjacency was weighed:** single-homing means mgmt→40 SSH transits the router, so a pfSense outage costs fleet SSH. Accepted — client→service already dies with pfSense, and break-glass is the PVE console on VLAN 30.

## Consequences

- **The `/32` routing-policy machinery becomes moot for single-homed guests** — one NIC, one gateway, no policy tables. The What-Never-To-Do entry stays as history for any future multi-homed exception.
- The WP4 fleet definitions get `vlans = ["vlan40"]` (PBS adds vlan20); the module's `management_vlan` concept repoints at the services VLAN so `vm_id` → services IP with no `ip_offset` duality. Inventory `ansible_host` becomes the services address; `service_ip` and the cross-VLAN prefix-translation facts collapse.
- AdGuard's `adguard_cross_vlan_rewrites` machinery and the dual-identity DNS records shrink to one A/AAAA record per service (ADR 0006 names, ULA per ADR 0010).
- The host role (WP2) gains the fleet NFS mounts (identical on all nodes) and the WP4 compose templates switch NFS named volumes to plain binds of the container mount path; the volume-auto-recreate machinery for mount-option changes retires with them.
- pfSense manual steps at cutover (ADR 0005): admin-port rules on VLAN 40 (source = network/operator plane), DHCP dual-resolver hand-out unchanged, VLAN 50/140 interface removal.
- Squid retirement: role/tag/`/squid` Infisical folder become dormant at cutover; lancache continues to cover game caching.
- CLAUDE.md's "SSH uses vlan10" convention and prefix-translation notes describe the live fleet until cutover; they are amended when WP4 lands (WP7).
- Client-side wireless/VLAN consolidation (SSID reduction, Sonos folding into IoT when wired, Apple TV placement) is explicitly out of scope here — tracked as future network work, not fleet IaC.
