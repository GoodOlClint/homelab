# pfSense WireGuard — VPS Tunnel Peer Setup

## Overview

This configures a WireGuard tunnel from pfSense to the Vultr VPS relay. pfSense initiates the connection outbound; the VPS never needs to know your home IP.

## Prerequisites

- pfSense WireGuard package installed (System > Package Manager)
- VPS deployed and running (`make vps-deploy`)
- VPS public key (from `secrets.sops.yml` or VPS `wg show wg0`)

## Tunnel Addressing

| Endpoint | Tunnel IP | Role |
|----------|-----------|------|
| pfSense | VPN transit gateway /24 | Gateway (initiates connection) |
| VPS | VPN transit peer /24 | Relay (listens on UDP 51821) |

## Step-by-Step Configuration

### 1. Create WireGuard Tunnel (VPN > WireGuard > Tunnels)

- **Description:** VPS-Relay
- **Listen Port:** (leave empty — pfSense initiates outbound)
- **Interface Keys:** Generate new keypair. Save the **public key** — you'll need it for the VPS config (`pfsense_wg_public_key` in secrets.sops.yml)
- **Interface Addresses:** VPN transit gateway /24

### 2. Add VPS Peer (VPN > WireGuard > Peers)

- **Tunnel:** VPS-Relay
- **Description:** Vultr VPS Dallas
- **Dynamic Endpoint:** unchecked
- **Endpoint:** VPS public endpoint (see secrets/vars)
- **Endpoint Port:** `51821`
- **Keep Alive:** `25` (seconds — maintains NAT mapping, enables VPS to learn pfSense endpoint)
- **Public Key:** VPS public key (from WireGuard keypair generated during Ansible provisioning)
- **Allowed IPs:** VPN transit subnet /24 (tunnel subnet only)
- **Pre-shared Key:** (optional, leave empty unless you want additional layer)

### 3. Assign WireGuard Interface (Interfaces > Assignments)

- Add the `tun_wg1` (or whatever the VPS tunnel interface is named) as a new interface
- **Description:** WG_VPS
- **IPv4 Configuration:** Static — VPN transit gateway /24
- **IPv4 Gateway:** None (point-to-point tunnel)
- Enable the interface

### 4. Firewall Rules (Firewall > Rules > WG_VPS)

Allow traffic from VPS tunnel to reach internal services:

| Action | Protocol | Source | Destination | Port | Description |
|--------|----------|--------|-------------|------|-------------|
| Pass | TCP | VPN transit subnet | Plex VM IP | 32400 | Plex via VPS |
| Pass | UDP | VPN transit subnet | Docker VM IP | 2456-2458 | Valheim via VPS |
| Pass | UDP | VPN transit subnet | WG_VPN address | 51820 | Mobile WG relay |
| Pass | Any | VPN transit subnet | VPN VLAN subnet | * | Mobile VPN subnet |

### 5. NAT Rules (if needed)

If Plex/Valheim are on different VLANs, ensure pfSense routes or NATs the traffic appropriately:

- Traffic arrives on WG_VPS interface destined for specific ports
- pfSense forwards to the actual service IPs on internal VLANs

## Tunnel MTU (measured — do not compute)

Decision and evidence: [ADR 0013](decisions/0013-vps-wireguard-tunnel-mtu-is-measured-set-to-1360-with-headroom.md).

The tunnel MTU is **1360 on both ends**. The VPS side is Ansible-managed (`wg_mtu` in `ansible/roles/vps_wireguard/defaults/main.yml`). The pfSense side is hand-managed (ADR 0005) and has **two** places that must agree — they historically did not (tunnel said 1420, interface said 1400):

1. **VPN > WireGuard > Tunnels > VPS-Relay**: set MTU to `1360`.
2. **Interfaces > WG_VPS (tun_wg1)**: set the MTU override to `1360`.

Why 1360: the peer endpoint is the VPS's **IPv6** address, so encapsulation costs 80 bytes (40 IPv6 + 8 UDP + 32 WireGuard) — 20 more than an IPv4 endpoint. Measured 2026-07-27: WireGuard UDP outer packets ≤ 1456 pass deterministically, ≥ 1458 drop 100% (below the WAN's 1462 — the drop is a path behavior specific to big UDP, not the interface MTU, and raw ICMPv6 at 1462 passes). Max safe inner = 1376; 1360 leaves 16 bytes headroom. Failures are silent blackholes (PMTUD is filtered upstream): TLS handshakes succeed, small packets flow, full-size segments vanish.

**Re-measure whenever** the WAN MTU, the endpoint address family, or the VPS provider/location changes. From the VPS (needs iputils ping), sweep DF-set pings through the tunnel and find the largest inner size that gets replies:

```sh
# inner = payload + 28; outer on the wire = inner + 80
for t in 1400 1380 1376 1360 1340 1320 1300 1280; do
  s=$((t-28))
  /bin/ping -4 -M do -c 5 -W 2 -s $s <pfsense-tunnel-ip> >/dev/null 2>&1 \
    && echo "inner=$t outer=$((t+80)) OK" || echo "inner=$t outer=$((t+80)) DROP"
done
```

Then set the tunnel MTU comfortably (≥ 16 bytes) below the measured maximum, on both ends.

## Verification

1. **Check tunnel status:** Status > WireGuard — peer should show "Latest Handshake" timestamp
2. **Ping test:** From pfSense Diagnostics > Ping, ping VPS tunnel IP
3. **Handshake timing:** Should update every ~25 seconds due to PersistentKeepalive

## Troubleshooting

- **No handshake:** Check that pfSense endpoint/port is correct, VPS firewall allows UDP 51821
- **Handshake but no traffic:** Check pfSense firewall rules on WG_VPS interface
- **Intermittent connectivity:** Verify PersistentKeepalive=25 is set on the pfSense peer
