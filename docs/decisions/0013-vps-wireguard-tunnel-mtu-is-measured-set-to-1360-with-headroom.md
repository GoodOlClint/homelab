# ADR 0013 — VPS WireGuard tunnel MTU is measured, set to 1360 with headroom

- **Status:** Proposed
- **Date:** 2026-07-27
- **Deciders:** operator + agent
- **Context source:** Plex-over-relay outage investigation, 2026-07 (PMTU measurement session)

## Context

Plex over the VPS relay was dead for a month: TLS handshakes completed and small packets flowed, but full-size packets were silently dropped (a 1164-byte payload SACKed while a 1328-byte payload was retransmitted three times and never ACKed, captured at the Plex VM). Hand-setting the VPS `wg0` to MTU 1280 fixed it instantly; the role still said 1400, so any redeploy re-broke it.

The tunnel's outer packets ride IPv6 (pfSense peers with the VPS over its GUA), so encapsulation costs **80 bytes** (40 IPv6 + 8 UDP + 32 WireGuard) — 20 more than the 60 an IPv4 endpoint would cost. This is the fact that makes the bug recur: every "WireGuard MTU 1420/1400" rule of thumb assumes an IPv4 outer.

Arithmetic alone predicted wrong. pfSense WAN (ix3) is MTU 1462 (reduced years ago for Cox flakiness, no record why), so inner ≤ 1462 − 80 = 1382 "should" work — yet 1380 failed in testing. Measured 2026-07-27 with DF-set probes:

- Raw ICMPv6 pfSense-WAN ↔ VPS passes at the full **1462** both directions — the WAN interface MTU is not the binding constraint.
- Real WireGuard-encapsulated UDP (DF-set inner pings through the tunnel): outer **1456 passes 20/20, outer 1458 drops 20/20**. Deterministic, sharp edge; something on the Cox/Vultr path treats big UDP differently from big ICMPv6.
- Measured ceiling: outer 1456 → max inner (tunnel MTU) **1376**.

## Decision

Set the tunnel MTU to **1360 on both ends** — `wg_mtu: 1360` in `ansible/roles/vps_wireguard/defaults/main.yml`, and 1360 on pfSense's `tun_wg1` (hand-managed per ADR 0005; both the tunnel-config MTU field and the interface override, which currently disagree at 1420 vs 1400 — set both to 1360).

Rationale: 1360 sits 16 bytes of headroom under the measured 1376 ceiling (outer 1440 vs 1456), absorbing small path shifts without re-entering blackhole territory, while recovering 80 bytes per packet (~6.5 % per-packet TCP goodput) over the always-safe 1280 floor. It stays ≥ 1280 so inner IPv6 (the ULA tunnel address) remains legal.

The nftables forward-chain MSS clamp (`tcp option maxseg size set rt mtu`) derives from the interface MTU, so it inherits this value automatically; TCP stays safe even while the pfSense side briefly disagrees.

MTU values are **measured, not computed**: any future change to the WAN MTU, the tunnel endpoint's address family, or the VPS provider re-runs the DF-probe sweep (documented in `docs/pfsense-wireguard-vps-peer.md`) rather than trusting `WAN − overhead` algebra.

## Rejected alternatives

- **1280 (IPv6 floor, the emergency hand-fix):** always works, but permanently forfeits 80 bytes/packet of goodput for headroom nobody measured a need for.
- **1376 (measured maximum):** zero headroom; a 2-byte path shift silently re-creates a month-long class of outage. The failure mode is silent blackholing, so headroom is cheap insurance.
- **1382 (WAN 1462 − 80, the computed value):** demonstrated wrong — 1380 already fails. This is the alternative the ADR exists to kill: do not trust the algebra.
- **Raising the pfSense WAN MTU to 1500 first:** untestable remotely — pf blocks unsolicited inbound probes on WAN, and pfSense cannot emit > 1462 without changing the hand-managed interface. Also moot for now: the measured UDP ceiling (1456) is *below* 1462, so the WAN MTU is not what binds. Left as an operator experiment; if WAN MTU changes, re-measure and revisit.
- **Relying on PMTUD instead of a conservative MTU:** the path filters ICMP "packet too big" somewhere upstream — that is precisely why the outage was silent. Not a viable mechanism on this path.

## Consequences

- Plex/Valheim relay throughput is bounded by a 1360-byte tunnel MTU (~5 % packetization overhead vs a native path). Accepted; correctness over peak throughput.
- pfSense's `tun_wg1` must be hand-set to 1360 (both fields) per ADR 0005 — documented in `docs/pfsense-wireguard-vps-peer.md`; until done, pfSense-originated UDP > 1360 inner can still blackhole (TCP is protected by the VPS MSS clamp).
- The measured ceiling (outer 1456) is a property of today's Cox/Vultr path. If the relay endpoint moves, the endpoint address family changes, or Cox re-provisions, the sweep must be re-run — the numbers do not transfer.
- An IPv6 outer endpoint costs 80 bytes, not 60. Any future tunnel with an IPv6 endpoint starts its MTU math from there.
