# pfSense — CI VLAN rules (ADR 0032 / 0034, hand-managed per ADR 0005)

The `CI` interface (VLAN 60) exists with DHCP enabled and public DNS, but as of 2026-08-23 it carries **no firewall rules**, so every nested PVE guest the runners build is isolated from everything — including the runner that serves its answer file. Apply these on **Firewall → Rules → CI**, top to bottom (first match wins):

| # | Action | Proto | Source | Destination | Port | Why |
|---|---|---|---|---|---|---|
| 1 | Pass | TCP/UDP | CI net | `<services prefix>.61` (talos-cp-a) | 8000, 111, 2049, 3260 | answer server (8000), NFS (111/2049), iSCSI (3260) — the PSProxmoxVE storage containers run `--net=host` on the runner node |
| 2 | Pass | TCP/UDP | CI net | CI address (this firewall's VLAN 60 address) | 53 | the split resolver below — the supernet block would otherwise eat it |
| 3 | Pass | TCP/UDP | CI net | `<BIND VIP>` (`dns_server.bind_ipv4`) | 53 | guest self-registration (`nsupdate` with `ci-update-key`) and explicit ci-zone lookups; BIND's per-zone ACL answers CI sources for the ci zone only |
| 4 | Block | any | CI net | `<internal supernet>` (the `/12` in `vlans.yaml`) | * | CI guests never reach the fleet, the nodes, or the workstation |
| 5 | Pass | any | CI net | any | * | internet (Debian/Proxmox repos, GitHub) |

## CI split resolver (DHCP DNS for the sandbox)

CI guests take everything from DHCP, and their resolver must answer both `ci.<service domain>` (the BIND child zone) and public names. BIND cannot be that resolver — it is authoritative-only (no recursion), and its per-zone ACL denies CI sources on every other zone — so pfSense carries a split resolver scoped to this VLAN:

- **Services → DNS Resolver**: enable, **Network Interfaces = CI + Localhost only** (never All — fleet clients must keep resolving through AdGuard, ADR 0012), **Domain Override**: `ci.<service domain>` → `<BIND VIP>`. Interface selection alone does NOT stop other VLANs: unbound binds the CI *address*, any VLAN that routes to it reaches the socket, and pfSense auto-adds `allow` ACLs for every local network (verified 2026-08-31: a core-VLAN dig was answered). Close it with **Advanced Settings → "Disable automatically-added access control entries"** plus **Access Lists**: Allow `<CI subnet>` and Allow `127.0.0.0/8` only. Proof: `dig @<CI gateway> debian.org` from a fleet VLAN returns REFUSED; from a CI guest it answers.
- **System → General Setup**: keep *DNS Resolution Behavior* = use remote servers, so the firewall's OWN lookups stay on the configured servers — enabling the resolver must not re-route pfSense's own resolution (the 2026-08-28 NXDOMAIN incident class, [docs/pfsense-acme.md](pfsense-acme.md)).
- **DHCP scope (CI)**: DNS server = the CI interface address (VLAN 60 gateway), **not** the BIND VIP — guests pointed straight at BIND get REFUSED on every public name.

pfSense's forwarded ci-zone queries reach BIND from its own services-VLAN address, which BIND's CI ACL does not match — no interaction.

With DDNS enabled on the CI scope, **one writer per name**: dhcpd guards each registration with a DHCID TXT and silently refuses any name whose TXT does not match, so a name touched by both dhcpd and `nsupdate` wedges until the stale pair is deleted by hand (the same two-writer fight as the fleet zone's PTRs). DHCP DDNS owns `<hostname>.ci.<domain>` for leased guests (TTL = half the scope's lease time — keep the lease short so registrations stay ~30s, and records are auto-removed at expiry); the `ci-update-key` is only for non-lease names (service aliases, ACME challenge TXTs, pipeline-invented records).

Notes:
- Rules 1–3 must sit **above** the supernet block (rule 4). If the ARC scale set is ever re-pinned to another node (`kubernetes/arc/values-common.yaml` `nodeSelector`), update rule 1's destination.
- The Services VLAN already has a catch-all pass, so the runner → CI, runner → vlan30:8006 and runner → internet legs in ADR 0032 need no new rules.
- No inbound rule from any other VLAN into CI is required: the runner initiates to the nested guests (API :8006, SSH) and pf state handles the replies.
- Reaper: a CronJob in `arc-runners` (`kubernetes/arc/reaper.yaml`) destroys pool-`ci` guests older than 6 h; nothing on pfSense is involved.
