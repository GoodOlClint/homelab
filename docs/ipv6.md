# IPv6

The scheme and its rationale are recorded in [ADR 0010](decisions/0010-per-vlan-ipv6-addressing-gua-tracks-the-vlan-id-ula-carries-stable-internal-services.md). This document is the operational half: what is configured on pfSense, how to reproduce it, and what to do when the ISP delegation changes. pfSense is hand-managed by [ADR 0005](decisions/0005-unifi-network-config-under-terraform-now-pfsense-iac-deferred.md), so nothing here is applied by Terraform or Ansible.

**This repo is public.** The delegated prefix is a geolocatable identifier and must never be committed. Concrete prefixes live in gitignored `network-data/vlans.yaml`; everything below is structural.

## Shape

Two address families run in parallel, each with one /64 per VLAN.

| | Source | Per-VLAN /64 | Used for |
|---|---|---|---|
| **GUA** | ISP prefix delegation on WAN (DHCPv6-PD), redistributed with `track6` | `<delegated>:<vlan_id_hex>::/64` | Internet-facing client traffic |
| **ULA** | `ipv6_prefix` in `network-data/vlans.yaml`, derived in Terraform | `<ula>:<vlan_id_hex>::/64` | Stable internal service addressing |

Both families use **prefix ID = VLAN ID in hex**, mirroring the IPv4 convention where the third octet is the VLAN ID. The ULA half is computed in [`terraform/modules/network/main.tf`](../terraform/modules/network/main.tf) — every VLAN gets one whether or not anything uses it. The GUA half is per-interface pfSense config and exists nowhere in IaC.

### How the ULA is actually routed

pfSense reaches the ULA /64 through an **IP alias Virtual IP** (`Firewall → Virtual IPs`, mode `ipalias`) holding `<ula>:<services_vlan_hex>::1/64` on the services interface — not through an address on the interface itself. That distinction matters when debugging: `Status → Interfaces` and the REST API's `status/interfaces` both report the interface as having no ULA, which makes it look like the prefix is unrouted when it is not. Check `Firewall → Virtual IPs` before concluding anything.

Only the VLAN hosting the resolver needs this VIP. Clients on every other VLAN reach the ULA through their default route, which is sufficient because pfSense is directly connected to that /64 via the alias.

### VLAN → prefix ID

| VLAN | ID | hex | GUA today |
|---|---|---|---|
| LAN (untagged) | — | `00` | yes |
| management | 10 | `0a` | **no — deliberate** |
| storage | 20 | `14` | no (L2 only) |
| infrastructure | 30 | `1e` | **no — deliberate** |
| corosync | 31 | `1f` | no |
| corosync_ring1 | 32 | `20` | no |
| services | 40 | `28` | yes |
| media | 50 | `32` | yes |
| vpn | 90 | `5a` | ULA only (WireGuard) |
| vps | 91 | `5b` | ULA only (WireGuard) |
| core | 100 | `64` | yes |
| work | 110 | `6e` | yes |
| iot | 120 | `78` | yes |
| sonos | 121 | `79` | yes |
| vivint | 122 | `7a` | yes |
| guest | 130 | `82` | yes |
| openclaw | 140 | `8c` | **no — deliberate** |

Management, infrastructure and openclaw are IPv4-only by decision — see ADR 0010. Do not "fix" them.

## pfSense configuration

**WAN** — *Interfaces → WAN*, IPv6 Configuration Type `DHCP6`, with prefix delegation requested. The delegation size must be large enough to cover the highest prefix ID in use (`8c` needs more than a /60).

**Each IPv6-enabled VLAN** — *Interfaces → \<VLAN\>*:
- IPv6 Configuration Type: `Track Interface`
- Track IPv6 Interface: `WAN`
- IPv6 Prefix ID: the VLAN ID **in hex** from the table above

The prefix ID field is hex and unlabelled as such — entering `40` for VLAN 40 silently lands you on `…:40::/64` instead of `…:28::/64`. This is the easiest thing to get wrong. The REST API does not report `track6_prefix_id_hex`, so the only reliable verification is reading the resulting address off an interface.

**Router advertisements** — *Services → Router Advertisement*, per VLAN:
- Mode: `Assisted` (RA flags show `managed, other stateful`; DHCPv6 supplies addresses)
- DNS server: the resolver's **ULA** address, not its GUA — this is what makes the resolver survive a prefix rotation
- Domain search list: the internal domain

**Filtering** — IP blocklists must exist for both families. See below.

## Verifying

From any dual-stack host on a VLAN that should have IPv6:

```sh
ip -6 addr show scope global          # expect a GUA in this VLAN's /64
ip -6 route show default              # expect: default via fe80::… proto ra
ping6 -c2 <resolver-ula>              # the RDNSS must actually answer
dig AAAA cloudflare.com @<resolver-ula>
```

Read the advertisement itself when something looks wrong — it is the authoritative statement of what clients are told:

```sh
sudo tcpdump -ni <iface> -vvv -c 1 'icmp6 and ip6[40] == 134'
```

Unsolicited RAs are infrequent; solicit one rather than waiting:

```sh
sudo python3 -c "
import socket,struct
s=socket.socket(socket.AF_INET6,socket.SOCK_RAW,58)
s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_MULTICAST_HOPS,255)
s.setsockopt(socket.SOL_SOCKET,25,b'<iface>\0')
s.sendto(struct.pack('!BBHI',133,0,0,0),('ff02::2',0))"
```

Check `prefix info` (the on-link /64), `rdnss` (must be the resolver's ULA) and `dnssl` (internal domain).

## pfBlockerNG DNSBL does not apply here

pfBlockerNG's DNSBL integrates with pfSense's Unbound resolver. **Unbound is not enabled on this firewall** — it does not appear in `Status → Services` at all — and no client resolves through pfSense regardless: DHCP and RA both point clients at AdGuard, which forwards to public resolvers with split-horizon overrides to BIND for internal zones.

So DNSBL cannot function here, whatever its settings say. If it is enabled it will log `DNSBL disabled: IPv6 VIP not on interface Loopback` and `pfb_dnsbl` will show `enabled=True running=False`. Adding the IPv6 loopback VIP "fixes" the message and changes nothing — it completes plumbing that is not connected to anything.

**Leave DNSBL disabled.** DNS-level blocking belongs to AdGuard, where it already runs and is address-family agnostic by nature. Only the IP-level lists below are pfBlockerNG's job on this network.

## Enabling IPv6 blocklists

pfBlockerNG shipped IPv4 feeds only, which leaves IP-level blocking bypassable over IPv6 by any client that resolves a AAAA. This matters less than it first appears: AdGuard already blocks by domain on both families, so the residual gap is direct-to-IP traffic that never does a lookup — malware C2, mainly, which is what the IPv4 feeds already target. The IPv6 feed selection is sparse; expect roughly two usable feeds, not a mirror of the IPv4 set.

Feeds are added per category, not from an IPv4/IPv6 settings page:

1. **`Firewall → pfBlockerNG → Feeds` → IPv6 Category → `+`** — the `+` on a feed row adds it to a group, creating the group on first use. The IPv6 group here is named `PRI1_6`.
2. **Adding a feed this way leaves it disabled in _two_ separate places.** Both must be changed under `Firewall → pfBlockerNG → IP → IPv6`, and neither is obvious from the other's page:
   - the group's **Action**, which defaults to disabled — set it to **`Deny Outbound`** to match the IPv4 posture (clients are blocked from reaching listed addresses)
   - the feed's own **State**, reachable only by clicking **Edit** on the feed row — set it to **`On`**

   Setting one without the other produces exactly the same symptom as doing nothing: the group saves, the config looks correct on the summary page, and no alias is ever built.
3. Add the ULA and delegated prefixes to the suppression list so internal traffic is never blocked. This matters more on IPv6 than IPv4 — the GUA space is ISP-assigned and can legitimately overlap a feed's range, which RFC1918 never does.
4. Run `Update → Reload → All` and wait for it to finish.

### Verifying it actually built

Saving the group is not the same as building it. pfBlockerNG only creates the alias and its auto-rule as a product of a successful feed **download**, so confirm the artifacts rather than the settings page:

- alias **`pfB_PRI1_6_v6`** exists alongside `pfB_PRI1_v4` — the name is `pfB_` + group name + `_v6`, so the group `PRI1_6` yields the doubled-looking `PRI1_6_v6`
- a `reject` rule with `ipprotocol` = `inet6` targeting it, on the same interface set as the IPv4 rule

Known-good end state: `pfB_PRI1_6_v6` on 16 interfaces, matching `pfB_PRI1_v4`. The IPv6 category is sparse — a single feed (`Myip_BL6_v6`) is the realistic result, against six on IPv4.

If a Force Reload logs `No changes to Firewall rules, skipping Filter Reload` and no alias appeared, nothing was downloaded — the group is empty or its feeds are `Off`. That is a group-contents problem, not a reload problem, and re-running the update will not fix it. Note also that pfBlockerNG skips a feed that downloads zero entries, so a dead or empty upstream URL yields no alias with no obvious error.

The REST API cannot verify this fully: it exposes no package config, and urltable aliases return `address: []` regardless of contents. It can confirm the alias and rule exist and are wired to the right interfaces; the download count in the pfBlockerNG log is the only evidence the list is non-empty.

### Interface coverage

pfBlockerNG's auto-rule is generated only for the interfaces selected in its firewall-rule settings. This defaulted to `lan` alone, meaning every other VLAN had no IP blocklist filtering on either family. Confirm the rule count matches the number of VLANs you intend to filter — a single `lan` rule is the tell. Leave the deliberately IPv4-only VLANs (management, infrastructure, openclaw) out of it.

Expect the filtering table to grow and a second alias plus rule to appear.

## When the ISP rotates the delegated prefix

Every GUA /64 moves at once. ULA addressing, and therefore the resolver, is unaffected — which is the whole reason the resolver sits on a ULA.

1. Confirm the new delegation on WAN (*Status → Interfaces*).
2. Verify each VLAN's `track6` address re-derived onto the new prefix with its prefix ID intact — the IDs are config and should not move, but confirm rather than assume.
3. Re-check any firewall rule or alias that names a literal GUA.
4. Update the concrete values in gitignored `network-data/`. Nothing in git needs to change.

## Failure modes seen

**Resolver stranded in its own /64.** A VM with a static IPv6 offset had `accept_ra` suppressed, so it had an address but no default route. It could not reach IPv6 upstreams and could not reply to clients on other VLANs, while pfSense kept advertising it as the RDNSS. Symptom: `dnsproxy … network is unreachable` on the resolver, and every IPv6-capable client on the network eating a DNS timeout before falling back to IPv4. IPv6-only devices had no fallback. Fixed in the VM module; a static offset no longer implies "no RA". Because cloud-init network data is under `lifecycle.ignore_changes`, a rebuild is what applies the module fix to an existing VM.

**A/AAAA both empty from a resolver test.** Means the hostname is wrong, not that IPv6 is broken. Check against the real zone before concluding anything.
