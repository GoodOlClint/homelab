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

## Endpoint, keys, and AllowedIPs (hard-won 2026-07-27)

- **Peer endpoint on pfSense = the VPS reserved IPv4** (see `terraform output vps_reserved_ip`), port 51821. Never the instance IPv6: a rebuild changes the instance MAC and therefore its SLAAC address, silently orphaning the endpoint — and the IPv6 path drops large WireGuard UDP (see MTU section).
- **Peer public key on pfSense must match the Infisical `/vps` keypair** (`vps_wg_public_key`). Rebuilds always redeploy the Infisical private key; if keys are ever rotated, update Infisical *and* pfSense together, or the next rebuild resurrects the old key and handshakes fail silently.
- **VPS-side peer AllowedIPs must cover the internal supernets** (IPv4 /12 + the ULA /48), not just the transit /24. Cryptokey routing silently drops LAN-sourced SSH/pings to the VPS and breaks its telegraf/rsyslog egress otherwise. Real values live in gitignored `ansible/group_vars/local/all.yml` (`vps_wg_tunnel.peer_allowed_ips`).

## Tunnel MTU (measured — do not compute)

Decision and evidence: [ADR 0013](decisions/0013-vps-tunnel-peers-over-reserved-ipv4-mtu-is-measured-per-address-family.md).

With the IPv4 endpoint the tunnel MTU is **1400 on both ends**. The VPS side is Ansible-managed (`wg_mtu` in `ansible/roles/vps_wireguard/defaults/main.yml`). The pfSense side is hand-managed (ADR 0005) and has **two** places that must agree — they historically did not (tunnel said 1420, interface said 1400):

1. **VPN > WireGuard > Tunnels > VPS-Relay**: set MTU to `1400`.
2. **Interfaces > WG_VPS (tun_wg1)**: MTU override `1400`.

Measured 2026-07-27: over the IPv4 endpoint (60 bytes encapsulation), WireGuard UDP outers pass at every size up to 1500 — 1400 inner (outer 1460) has ~40 bytes of demonstrated headroom and fits pfSense's 1462 WAN egress. Over the old **IPv6** endpoint (80 bytes encapsulation), outers ≥ 1458 dropped 100% while ≤ 1456 passed — **if the endpoint ever returns to IPv6, use 1360, not 1400** (measured inner ceiling 1376, minus headroom). Failures in this class are silent blackholes (PMTUD is filtered upstream): TLS handshakes succeed, small packets flow, full-size segments vanish.

**Re-measure whenever** the WAN MTU, the endpoint address family, or the VPS provider/location changes. From the VPS (needs iputils ping), sweep DF-set pings through the tunnel and find the largest inner size that gets replies:

```sh
# inner = payload + 28; outer on the wire = inner + 60 (IPv4 endpoint) or + 80 (IPv6)
for t in 1440 1420 1400 1380 1376 1360 1340 1320 1300 1280; do
  s=$((t-28))
  /bin/ping -4 -M do -c 5 -W 2 -s $s <pfsense-tunnel-ip> >/dev/null 2>&1 \
    && echo "inner=$t OK" || echo "inner=$t DROP"
done
```

Probing above the current tunnel MTU requires temporarily raising it (`ip link set wg0 mtu <n>`, live-only); set it back afterwards.

Then set the tunnel MTU comfortably (≥ 16 bytes) below the measured maximum, on both ends.

## Verification

1. **Check tunnel status:** Status > WireGuard — peer should show "Latest Handshake" timestamp
2. **Ping test:** From pfSense Diagnostics > Ping, ping VPS tunnel IP
3. **Handshake timing:** Should update every ~25 seconds due to PersistentKeepalive

## Troubleshooting

- **No handshake:** Check that pfSense endpoint/port is correct, VPS firewall allows UDP 51821
- **Handshake but no traffic:** Check pfSense firewall rules on WG_VPS interface
- **Intermittent connectivity:** Verify PersistentKeepalive=25 is set on the pfSense peer
