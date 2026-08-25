# ADR 0029 — AdGuard is an LXC pair behind a keepalived VIP; container resolv.conf is Terraform-owned, AdGuard-only except on the resolver CTs

- **Status:** Accepted
- **Amended:** ADR 0040 (P5a, 2026-08-25) removed the rewrite variables and `make adguard-rewrite`; AdGuard now forwards the flat service zone to BIND and answers no internal name itself.
- **Date:** 2026-08-21
- **Deciders:** operator + agent
- **Context source:** Day 3+ greenfield-replace session (ADR 0028 runbook, third guest) · plan doc WP4 "OPEN (ADR 0012 gap on containers)" · W6 findings 11/13

## Context

AdGuard is the fleet resolver and the operator's workstation resolver, so it cannot be swapped by stop-then-build (ADR 0028 Consequences: stopping 102 broke `terraform init` mid-rebuild). ADR 0003 already decided DNS gets availability by redundancy — two AdGuard LXCs on different nodes — but left the client-facing address open ("hand out both resolver IPs"), and the end-state design parks the web-UI admin password as an unrecorded secret.

Separately, ADR 0012 closed resolver poisoning for VMs with networkd drop-ins, and that mechanism does not exist for containers: PVE rewrites a container's `/etc/resolv.conf` from the CT `nameserver` setting on every start (measured, W6), so anything Ansible writes is reboot-transient, and `containers.tf` handed every CT the full `dns_servers` list including the public failover. With most of WP4's fleet on LXC this reinstated the poisoning. The AdGuard CTs themselves must apt-install keepalived and download AdGuardHome before any AdGuard answers, so an AdGuard-only list deadlocks their first build.

Measured while building (2026-08-21, Ubuntu 26.04 template, PVE 9.2): an unprivileged CT without `nesting` leaves `eth0` DOWN with no address (systemd 259's networkd needs it — PVE prints the warning at create); a static CT IPv6 address makes PVE write `IPv6AcceptRA=false`, which strands the guest with no v6 default route (the docs/ipv6.md "resolver stranded in its own /64" trap); keepalived 2.3 in an unprivileged CT enters MASTER and holds a v4 VIP plus a v6 address in `virtual_ipaddress_excluded` without extra capabilities.

## Decision

1. **AdGuard is `adguard1` (ms-01a) + `adguard2` (ms-01b), unprivileged LXCs, single Services leg, `ha = false`, VMIDs 251/252.** ADR 0028's old+100 rule yields one VMID (202) for a pair and 203 collides with openobserve+100; the pair takes VMID = 200 + its `ip_offset` instead. The numbered-instance convention puts both in the `adguard` inventory group, so `hosts: adguard` and `make build adguard` (now `group-targets`) cover the pair.
2. **Clients see one address: the VIP** — `vlans.yaml` `dns_server.dns_ipv4`/`dns_ipv6`, i.e. the address the restored 102 already held and pfSense DHCP/RA already hand out. keepalived in both CTs, unicast peers from the `adguard` group, track script = `dig` of a locally-rewritten name against `127.0.0.1` (so an upstream outage does not flap the VIP between two equally-affected instances), v6 VIP in `virtual_ipaddress_excluded`. No pfSense change: a VIP equal to the old resolver address keeps ADR 0005's hand-managed half untouched. Instance IPv6 is SLAAC; only the VIP is a static ULA.
3. **Container `resolv.conf` is Terraform's, per guest:** `containers.tf` emits `[dns_servers[0]]` (AdGuard-first by ADR 0012, so element 0 is the VIP) for every CT, and the full list with the public failover only for guests flagged `resolver = true`. This is the durable control point ADR 0012 wanted and amends it for containers; `dns_config` stays VM-only.
4. **Admin credentials are IaC:** `adguard_username`/`adguard_password` are generated into Infisical `/homepage` (the folder the homepage widget already reads them from) before the config template renders, and the initial-only `AdGuardHome.yaml` carries the bcrypt hash. Both instances deploy identically; there is no config sync. `make adguard-pause MINUTES=n` POSTs `/control/protection` on every instance for the "turn blocking off for a moment" need.
5. **Module default `nesting = true`** — the Ubuntu 26.04 template does not bring up networking without it.

## Rejected alternatives

- **Hand out both instance IPs via DHCP/RA (ADR 0003's wording).** Clients fail over by timeout (seconds per lookup while one instance is down), the Mac's `scutil` ordering is not controllable, and every pfSense DHCP scope + RA needs a hand edit. A VIP moves in ~1 s with no client change.
- **adguardhome-sync between the instances.** A third moving part for config the role already renders identically; the one thing it would carry (ad-hoc UI edits) is the initial-only-template trap CLAUDE.md already warns about. `make adguard-pause` covers the operator's actual use.
- **AdGuard-only nameserver for every CT, including the resolvers.** Deadlocks the first build: the resolver CT needs DNS to fetch keepalived and AdGuardHome before AdGuard exists (ADR 0012's own rejected alternative, now at the CT layer).
- **Drop the public failover fleet-wide / two-phase build that narrows the CT nameserver after DNS is up.** The first breaks VM cloud-init bootstrap ADR 0012 preserved; the second makes every CT build a two-apply dance for a list Terraform can set correctly the first time.
- **Ansible-written `/etc/resolv.conf` or resolved drop-ins in the CT.** Reboot-transient — PVE rewrites the file at every start (measured).
- **Static instance ULAs beside the VIP.** PVE writes `IPv6AcceptRA=false` for a static CT v6 address, stranding v6 with no default route; the instances need RA, and nothing addresses them by their own ULA.
- **VMIDs 202/203.** 203 = openobserve's old+100 slot.
- **A privileged CT for keepalived.** Not needed — VRRP works unprivileged (measured).

## Consequences

- `vm_configurations` gains `resolver` (bool) and `nesting` defaults to `true`; `containers.tf` `dns {}` is per-guest. Every future CT lands AdGuard-only with no Ansible step — the ADR 0012 gap on containers is closed.
- Inventory emits `ansible_user: root` for LXC guests (W6 finding 13); VMs are unchanged.
- The restored 102 is stopped (`onboot 0`), never destroyed, per ADR 0028; the scratch 202 is destroyed (no state worth keeping). `backup_jobs` still lists old VMIDs — re-authored once a few replacements exist.
- Rebuilding one instance (`make rebuild adguard1`) is a zero-outage operation: the partner holds the VIP. Rebuilding both at once is not — don't.
- A password rotation in Infisical does not reach a running instance (initial-only template, same trap as the rewrites); it lands on the next rebuild of each instance.
- Homepage's AdGuard widget points at the VIP, not an instance; its stats show whichever instance holds the VIP.
- `dns_config`'s LXC guard stays; the plan-doc WP4 "OPEN" item is closed by this ADR. ADR 0012 is amended (container mechanism), not superseded.
- BIND follows as the next pair (separate kickoff) and will reuse the same keepalived tasks pattern — lift it into a shared task file then, not before.
