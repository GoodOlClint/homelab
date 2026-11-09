---
paths:
  - "ansible/roles/adguard/**"
  - "ansible/roles/bind9/**"
  - "ansible/roles/dns_config/**"
  - "ansible/roles/pfsense/**"
  - "ansible/roles/rsyslog_client/**"
  - "ansible/roles/vps_*/**"
  - "ansible/playbooks/vps.yml"
  - "ansible/playbooks/pfsense.yml"
  - "ansible/playbooks/dns-records.yml"
  - "ansible/playbooks/update-dns.yml"
  - "ansible/tasks/dns_records.yml"
  - "terraform/vultr-vps.tf"
  - "terraform/cloudflare-dns.tf"
  - "terraform/modules/network/**"
  - "kubernetes/external-dns/**"
  - "kubernetes/monitoring/**"
  - "docs/pfsense-*.md"
---

# DNS, network and the VPS relay

Loaded when a matching path is read or edited. The repo-wide rules are in `CLAUDE.md`; the incident behind each rule is in [docs/LESSONS.md](docs/LESSONS.md) under the same heading.

## Canonical pipelines

**Ingress policy — PLANNED, not built ([plan](docs/ingress-policy-plan.md), ADRs 0044–0046):** exposure becomes a declared `mode` per service in `terraform/ingress.tf` — `none` | `tunnel` | `vps` | `direct`, with `tls = traefik|self` as a **separate** axis. The mode drives **only the public DNS record** (ADR 0044). `tls = self` gets a **new sibling** of `cert_client` — Let's Encrypt + `dns-cloudflare`. Ingress VPSs become **plural** (`for_each` over `vps_instances`), justified **by trust boundary, never by a port collision**; SNI routing rides **the VPS, never pfSense** (ADR 0045). The internal authentik realm is **published as a federation upstream** so the operator keeps one identity; Case testers live in the external realm and never in an admin group; **MFA enforced on `authentik Admins`/`pfsense-admins`** (ADR 0046). The dangerous WP is the VPS `for_each` refactor (a reindex destroys the live relay — `moved` blocks + a 0-change plan are the gate).

**DNS** is split-horizon behind AdGuard and must never see a public resolver ahead of it (ADR 0012): `vlans.yaml` `dns_servers` is AdGuard-first, and `dns_config` deploys durable systemd-networkd drop-ins — not resolvectl and not netplan overrides (netplan merges nameserver lists and cannot remove entries). **Containers** get their resolver list from Terraform (`containers.tf`: the VIP only, plus the public failover on `resolver = true` guests, ADR 0029). **AdGuard is an LXC pair** (VMIDs 251/252) behind a keepalived VIP; never rebuild both instances at once. **BIND is the same shape** (`dns1`/`dns2`, VMIDs 218/219, VIP = `dns_server.bind_ipv4`): zone files live under `/var/lib/bind` on the primary, DDNS to the VIP is forwarded to the primary; keepalived is `ansible/tasks/keepalived.yml`.

**AdGuard query log** ships to OpenObserve stream `adguard_querylog`: rsyslog `imfile` tails `querylog.json` (`/etc/rsyslog.d/40-adguard-querylog.conf`) → its own axosyslog channel, pinned by `scripts/test_axosyslog_routing.py`. Local retention is `adguard_querylog_interval: 168h` (converged through the API; the config template is initial-only); long history lives only in OpenObserve.

**IPv6** is per-VLAN: GUA `track6` (prefix ID = VLAN ID) + Terraform ULA (ADR 0010, [docs/ipv6.md](docs/ipv6.md)). Management, infrastructure and openclaw VLANs are IPv4-only — do not "fix" them. A static `ipv6_offset` must never imply `accept_ra: false` (RA is the only default route).

**VPS relay tunnel** peers over the reserved IPv4; MTU is measured, not computed (ADR 0013): `wg_mtu` 1400 (IPv4 endpoint), 1360 for IPv6. pfSense `tun_wg1` must match in BOTH the tunnel config and the interface override, and the peer key must match Infisical `/vps` ([docs/pfsense-wireguard-vps-peer.md](docs/pfsense-wireguard-vps-peer.md)).

**VPS seedbox (2026-09-21):** the relay VPS seeds archive.org bundles via `transmission-daemon` (`vps_seedbox` role); `vps_seedbox_torrents` in the role defaults is the record (24 GB disk, check `df` before a big bundle). Settings that must converge are daemon flags in `/etc/conf.d/transmission-daemon` (the daemon rewrites `settings.json` on every stop). The web UI at `<tunnel address>:9091` is LAN-only with no auth; peer port 51413 is open in `nft_input_rules` and the Vultr firewall (`seedbox_*` rules, in `VPS_TF_TARGETS`). Removing a torrent is by hand (`transmission-remote <tunnel address>:9091 -t <id> --remove-and-delete`) plus dropping the line — the role does not prune. **archive.org `_archive.torrent` files go stale silently** (the piece holding changed files can never verify from the webseed, and transmission logs nothing): mark the files sharing the bad piece unwanted (`transmission-remote … -t <id> -G <ids>`), else `curl` from `https://archive.org/download/<item>/<file>` into `downloads/<item>/` and `-v` verify. The unwanted marks live only in transmission's resume file.

Landing dates, measurements and "found en route" notes for each pipeline: [docs/LESSONS.md](docs/LESSONS.md), same headings.

## What Never To Do

- **The AdGuard config template is `when: not _adguard_config.stat.exists` — "initial only"** — AdGuardHome rewrites its own YAML at runtime, so editing `adguardhome.yaml.j2` affects fresh VMs only. On a running host edit the live config (stop service → edit → start) or use the AdGuard API (`/control/dns_config`), and verify the edit survived a service restart.
- **Never enable netconsole without also raising `console_loglevel`** — netconsole is a *console* driver, so it only transmits what passes console-level filtering, and the PVE default `kernel.printk` console level 1–3 drops the KERN_ERR (3) NVMe/`EXT4-fs error` messages. Set **`kernel.printk = 5 4 1 7`** via an `/etc/sysctl.d/` drop-in alongside the module. Verify with `<3>`/`<4>`/`<5>`-prefixed `/dev/kmsg` writes: the first two must arrive, the third must not
- **Never assume an RFC 3164 sender's clock agrees with the collector's timezone** — RFC 3164 timestamps carry no zone, so syslog-ng interprets them as *receiver-local* and a UTC device lands every message in the future, where `end_time=now` queries silently exclude it. Fix at the source (`/etc/TZ` + `TZ=` on the syslogd process), and widen the query window into the **future** before blaming the network.
- **Never point a device's ordinary syslog at the netconsole port (5515)** — 5515 is deliberately parser-free and dumps straight into the `netconsole` stream, while on 5514 `syslog-parser()` parses unframed printk as RFC 3164 and eats the first token. Ordinary syslog belongs on 5514; keep UniFi's two destinations (`unifi_setting.syslog.netconsole_*` vs `.ip`/`.port`) separate.
- **Never expect netconsole to carry a hostname, and never reach for `userdata` to add one** — netconsole's wire format has no hostname field, so the `netconsole` stream's `host` is the *source IP*, and with `extended=0` (the default) configfs `userdata` is silently dropped. Names belong at the collector: `use-dns(yes)` on the `s_netconsole` source once PTR zones exist
- **Never leave syslog-ng's default `max-connections(10)` on a fleet-wide syslog source** — each Docker daemon holds one TCP connection per logging container, so the fleet blows past 10 and every new sender is rejected with ingestion silently stalling
- **Never use `iif`/`oif` in nftables rules for interfaces created after boot (wg0)** — they resolve interface indexes at ruleset load, so the whole ruleset fails to load when the interface doesn't exist yet, leaving the box unfiltered. Use `iifname`/`oifname`
- **Never synchronously restart WireGuard over the tunnel it carries** — the service task dies between `down` and `up` when its own SSH session severs, and the box is unreachable (VPS sshd binds tunnel IPs only). The `vps_wireguard` restart handler is `async: 60 / poll: 0` fire-and-forget; keep it that way.
- **Never trust computed tunnel MTU arithmetic — measure with DF-set probes** — an IPv6 tunnel endpoint costs 80 bytes of encapsulation, not IPv4's 60, and the IPv6 relay path drops WG UDP outers ≥ 1458 even though raw ICMPv6 passes at 1462. The procedure is in docs/pfsense-wireguard-vps-peer.md.
- **Never debug a dead VPS tunnel past the pf state table** — after a VPS rebuild pfSense can keep sending handshake initiations into a stale inbound `if-bound`/`reply-to` UDP state for `:51821`, which its own keepalives refresh forever while nothing is logged. `pfctl -k <vps_ip>` brings the tunnel up in seconds.
- **Never peer WireGuard against the VPS instance IPv6, and never set narrow AllowedIPs** — the SLAAC address dies on every rebuild (new MAC), and AllowedIPs narrower than the internal supernets makes cryptokey routing silently drop LAN-sourced SSH/pings while breaking VPS-originated telegraf/rsyslog (ADR 0013)
- **Never assume a VM-shaped network task works in an LXC** — `dns_config`'s drop-in targets `10-netplan-<iface>`, which netplan emits **only on VMs**, and `netplan apply` *hard-fails* in a container, so it is guarded with `when: ansible_virtualization_type != 'lxc'`. A container's `/etc/resolv.conf` is a static file PVE writes from `dns { servers = var.dns_servers }`, so **skipping is not solving**
- **Never let a role write DNS config and defer the apply to a handler** — handlers run at end-of-play while every task in between depends on DNS, so one bad resolver latches: the next run dies at the first network-touching task and never reaches the handler. Apply in-role, gated on a `/run` pending-marker rather than on this run's file changes; recovery needs a hand-run `netplan apply`
- **Never start a VIP's keepalived while the guest it replaces still holds the address** — keepalived does no conflict detection. Stage with the `adguard` role's `adguard_vip_state: stopped`, stop the old copy, then `systemctl start keepalived` on every instance **from the workstation** (the nodes have no SSH key into the CTs)
- **Never put a BIND primary's zone files under `/etc/bind`** — Ubuntu's AppArmor profile grants named `/etc/bind/** r` only, so every RFC 2136 update fails with `journal open failed` (`.jnl: create: permission denied`) while queries keep answering. Dynamic zones belong in `/var/lib/bind` (`rw` in the profile); chowning `/etc/bind` to `bind` does nothing against AppArmor
- **Never probe a name in the flat service zone before its record exists and then trust the next answer** — AdGuard caches the NXDOMAIN for the zone's negative TTL (`cache_ttl_max: 0` = no cap), and macOS's resolver does the same on the client, so a name created seconds later stays "missing" on that path. AdGuard's `POST /control/cache_clear` on both instances is the fix for a stuck client; the Mac needs `dscacheutil -flushcache`
- **Never assume pfSense can resolve a fleet name — "DNS Server Override" sends its own lookups to the ISP** — *Allow DNS server list to be overridden by DHCP/PPP on WAN* prepends the WAN-supplied resolvers, so every internal name returns NXDOMAIN (curl error **6** `COULDNT_RESOLVE_HOST` — not a TLS or settings fault). pfSense also self-registers its own hostname over DDNS, so it must NOT be added to `make dns-records`. Runbook: [docs/pfsense-acme.md](docs/pfsense-acme.md)
- **Never create a static record for a host that DHCP already registers — pfSense DDNS is enabled per scope, and two writers fight over the PTR** — **DDNS registers on lease grant/renewal, not when the scope is enabled**, so a name missing from a DDNS-enabled scope usually means the device has not renewed its lease yet. `dns_records.yml` covers inventory hosts, VIPs and MetalLB addresses only. A cached NXDOMAIN clears with `POST /control/cache_clear` on each AdGuard (port 3000) plus `dscacheutil -flushcache` on the Mac
- **Never let a WAN outage reach AdGuard's worker pool** — AdGuard Home has one `max_goroutines` semaphore for every query, internal zones included, and dnsproxy holds a failing public upstream for `upstream_timeout` twice over, so dead public lookups starve BIND-bound names. The `adguard` role holds `adguard_upstream_timeout_s: 3` and `adguard_max_goroutines: 3000`; do not put BIND in front of AdGuard
- **Never let Plex's `LanNetworksBandwidth` cover the VPS tunnel subnet** — the relay masquerades every remote viewer behind the tunnel address, so a LAN range covering it makes every relayed client *local* and `WanPerStreamMaxUploadRate` never applies. The `plex` role converges `plex_prefs` with `plex_lan_networks` = the fleet VLAN /24s; raise `WanPerStreamMaxUploadRate` by adding it to `plex_prefs`, not in the UI
- **Never tighten the VLAN 30 firewall without keeping services→nodes TCP 9100 and services→pdm/pxe/worklab telegraf and node_exporter ports open, or move those scrapes** — worklab, pdm and pxe have only a VLAN 30 address (worklab 9100, pdm/pxe telegraf 9273), so a named-guest-rules-only VLAN 30 silently blinds the disk and temperature alerts for them
