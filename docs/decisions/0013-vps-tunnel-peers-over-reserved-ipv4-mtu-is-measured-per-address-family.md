# ADR 0013 — VPS tunnel peers over the reserved IPv4; MTU is measured per address family

- **Status:** Accepted
- **Date:** 2026-07-27
- **Deciders:** operator + agent
- **Context source:** Plex-over-relay outage investigation + VPS rebuild incident, 2026-07-27

## Context

Plex over the VPS relay was dead for a month: TLS handshakes completed and small packets flowed, but full-size packets silently vanished (a 1164-byte payload SACKed while a 1328-byte payload was retransmitted three times, never ACKed). Hand-setting the VPS `wg0` to MTU 1280 fixed it instantly; the role still said 1400, so any redeploy re-broke it. PMTUD is filtered somewhere upstream, so every failure in this class is a silent blackhole.

The tunnel then peered over the VPS's **IPv6** address. Measured 2026-07-27 with DF-set probes through the tunnel:

- IPv6 outer: WireGuard UDP ≤ **1456 outer passes 20/20; ≥ 1458 drops 20/20**. Deterministic. Raw ICMPv6 passes at the full 1462 both ways — the drop is a path behavior specific to big UDP over the Cox/Vultr **IPv6** path, and it sits *below* what the WAN MTU (1462) predicts. IPv6 encapsulation costs 80 bytes → max safe inner 1376.
- IPv4 outer (after switching the peer endpoint to the reserved IP): **no reachable ceiling — outers up to 1500 pass 3/3 at every size**. IPv4 encapsulation costs 60 bytes.

Separately, the same day's rebuild proved the IPv6 endpoint is operationally fragile: a Vultr rebuild changes the instance MAC and therefore its SLAAC IPv6, silently orphaning pfSense's configured endpoint. The reserved IPv4 survives rebuilds.

## Decision

- **The pfSense→VPS peer endpoint is the reserved IPv4, not the instance IPv6.** It is rebuild-stable and rides the measured-clean IPv4 path.
- **Tunnel MTU is 1400 on both ends** — `wg_mtu: 1400` in `ansible/roles/vps_wireguard/defaults/main.yml`, and 1400 on pfSense `tun_wg1` (both the tunnel-config MTU field, historically 1420, and the interface override — they must agree). 1400 gives outer 1460: it fits pfSense's 1462 WAN egress (1462 − 60 = 1402) and sits ~40 bytes under the demonstrated 1500-outer passage.
- **If the endpoint ever returns to IPv6, the MTU is 1360**, not 1400: measured inner ceiling 1376 (outer 1456) minus 16 bytes headroom. The 80-vs-60-byte encapsulation difference and the v6-only UDP drop are what made this outage recur.
- **MTU values are measured, not computed** — re-run the DF-probe sweep (procedure in `docs/pfsense-wireguard-vps-peer.md`) whenever the endpoint address family, WAN MTU, or VPS provider/location changes. `WAN − overhead` arithmetic predicted 1382 on the v6 path; 1380 already failed.

The nftables forward-chain MSS clamp (`tcp option maxseg size set rt mtu`) derives from the interface MTU and inherits any future value automatically.

## Rejected alternatives

- **Keep the IPv6 endpoint:** the v6 path silently drops WG UDP above outer 1456 (root cause of the month-long outage), costs 20 more bytes per packet, and the endpoint address dies on every rebuild. No offsetting benefit.
- **1360 on the current (IPv4) path:** conservative but forfeits 40 bytes/packet against a path with no measured ceiling; 1360 remains the recorded fallback for a v6 endpoint only.
- **1440 (eth0 1500 − 60):** passes VPS→pfSense today, but pfSense-originated packets above inner 1402 exceed its 1462 WAN egress, and zero headroom invites the silent-blackhole class back.
- **Relying on PMTUD:** ICMP "packet too big"/"fragmentation needed" is filtered on this path — that is precisely why the original failure was silent.
- **Raising the pfSense WAN MTU (1462 → 1500) first:** untestable without touching the hand-managed interface (pf blocks unsolicited inbound probes; pfSense can't emit > 1462), and no longer binding on the v4 path. Left as an operator experiment.

## Consequences

- pfSense side (hand-managed per ADR 0005): peer endpoint = reserved IPv4, peer public key must match the Infisical `/vps` keypair, tunnel-config MTU 1420 → 1400. Documented in `docs/pfsense-wireguard-vps-peer.md`.
- The VPS-side peer `AllowedIPs` must cover the internal supernets, not just the transit /24 — cryptokey routing silently drops LAN-sourced SSH/pings and breaks the VPS's own telegraf/rsyslog egress otherwise. Values live in gitignored `ansible/group_vars/local/all.yml` (public-repo scrub).
- A future rebuild keeps the endpoint valid (reserved IP) and the keypair valid (Infisical `/vps`); rotating keys must update Infisical, not just pfSense.
- The v6 measurement (outer ceiling 1456) documents a Cox/Vultr path property as of 2026-07-27; it does not transfer to other paths or dates.
