# pfSense — CI VLAN rules (ADR 0032 / 0034, hand-managed per ADR 0005)

The `CI` interface (VLAN 60) carries the nested PVE guests the runners build. Apply these on **Firewall → Rules → CI**, top to bottom (first match wins):

| # | Action | Proto | Source | Destination | Port | Why |
|---|---|---|---|---|---|---|
| 1 | Pass | TCP/UDP | CI net | CI address (this firewall's VLAN 60 address) | 53 | the split resolver below — the supernet block would otherwise eat it |
| 2 | Pass | TCP/UDP | CI net | `<BIND VIP>` (`dns_server.bind_ipv4`) | 53 | guest self-registration (`nsupdate` with `ci-update-key`) and explicit ci-zone lookups; BIND's per-zone ACL answers CI sources for the ci zone only |
| 3 | Block | any | CI net | This Firewall (self) | * | no pfSense GUI or SSH on any of its addresses |
| 4 | Block | any | CI net | `<internal supernet>` (the `/12` in `vlans.yaml`) | * | CI guests never reach the fleet, the nodes, or the workstation |
| 5 | Pass | any | CI net | any | * | internet (Debian/Proxmox repos, GitHub) |

## CIControl rules (VLAN 61, the CI cluster nodes, ADR 0064)

The `CIControl` interface carries the two CI cluster nodes. Apply on **Firewall → Rules → CIControl**, top to bottom (first match wins):

| # | Action | Proto | Source | Destination | Port | Why |
|---|---|---|---|---|---|---|
| 1 | Pass | TCP/UDP | CIControl net | CIControl address | 53 | the split resolver below (DHCP DNS for the nodes) |
| 2 | Pass | TCP/UDP | CIControl net | `<BIND VIP>` (`dns_server.bind_ipv4`) | 53 | jobs register test-guest names in the `ci` zone with `ci-update-key` |
| 3 | Pass | TCP | CIControl net | Infrastructure net (VLAN 30) | 8006 | the Proxmox API, for jobs and their guests in pool `ci` |
| 4 | Pass | any | CIControl net | CI net (VLAN 60) | * | jobs reach the guests they build; replies ride state |
| 5 | Block | any | CIControl net | This Firewall (self) | * | no pfSense GUI or SSH from job nodes |
| 6 | Block | any | CIControl net | `<internal supernet>` (the `/12`) | * | nothing else internal |
| 7 | Pass | any | CIControl net | any | * | internet: GitHub, image registries, Talos discovery, NTP |

Nothing inbound is added: the CI VLAN's supernet block already stops CI guests reaching these nodes, and the operator workstation on Core reaches the Talos (50000) and Kubernetes (6443) API ports through Core's existing pass rules. The resolver needs `CIControl` in its Network Interfaces and an Allow entry for the CIControl subnet in its Access Lists, as for CI below. Jobs reach the Proxmox API by its fleet name, which the resolver does not know, so it also carries a **Domain Override** for that one name, `pve.<service domain>` → `<BIND VIP>`. Only that name: the job node learns no other fleet address.

## CI split resolver (DHCP DNS for the sandbox)

CI guests take everything from DHCP, and their resolver must answer both `ci.<service domain>` (the BIND child zone) and public names. BIND cannot be that resolver — it is authoritative-only (no recursion), and its per-zone ACL denies CI sources on every other zone — so pfSense carries a split resolver scoped to this VLAN:

- **Services → DNS Resolver**: enable, **Network Interfaces = CI + Localhost only** (never All — fleet clients must keep resolving through AdGuard, ADR 0012), **Domain Override**: `ci.<service domain>` → `<BIND VIP>`. Interface selection alone does NOT stop other VLANs: unbound binds the CI *address*, any VLAN that routes to it reaches the socket, and pfSense auto-adds `allow` ACLs for every local network (verified 2026-08-31: a core-VLAN dig was answered). Close it with **Advanced Settings → "Disable automatically-added access control entries"** plus **Access Lists**: Allow `<CI subnet>` and Allow `127.0.0.0/8` only. Proof: `dig @<CI gateway> debian.org` from a fleet VLAN returns REFUSED; from a CI guest it answers.
- **System → General Setup**: keep *DNS Resolution Behavior* = use remote servers, so the firewall's OWN lookups stay on the configured servers — enabling the resolver must not re-route pfSense's own resolution (the 2026-08-28 NXDOMAIN incident class, [docs/pfsense-acme.md](pfsense-acme.md)).
- **DHCP scope (CI)**: DNS server = the CI interface address (VLAN 60 gateway), **not** the BIND VIP — guests pointed straight at BIND get REFUSED on every public name.

pfSense's forwarded ci-zone queries reach BIND from its own services-VLAN address, which BIND's CI ACL does not match — no interaction.

With DDNS enabled on the CI scope, **one writer per name**: dhcpd guards each registration with a DHCID TXT and silently refuses any name whose TXT does not match, so a name touched by both dhcpd and `nsupdate` wedges until the stale pair is deleted by hand (the same two-writer fight as the fleet zone's PTRs). DHCP DDNS owns `<hostname>.ci.<domain>` for leased guests (TTL = half the scope's lease time — keep the lease short so registrations stay ~30s, and records are auto-removed at expiry); the `ci-update-key` is only for non-lease names (service aliases, ACME challenge TXTs, pipeline-invented records).

Notes:
- Rules 1–2 must sit **above** the supernet block (rule 4). The PSProxmoxVE answer server, NFS and iSCSI run on a storage VM inside pool `ci`, so CI guests need no pinhole to any runner.
- No inbound rule into CI is required: the runners on CIControl initiate to the nested guests (CIControl rule 4) and pf state handles the replies.
- Reaper: the `ci-reaper` tree on the services cluster destroys pool-`ci` guests older than 6 h with its own identity; nothing on pfSense is involved.
