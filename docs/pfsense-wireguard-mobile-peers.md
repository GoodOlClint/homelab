# pfSense WireGuard — Mobile Peer Setup

## Overview

Mobile devices connect to the VPS public endpoint on port 51820. The VPS relays these opaque UDP packets through the WireGuard tunnel to pfSense, which terminates the mobile VPN sessions. The VPS never decrypts mobile traffic.

## Architecture

```
Mobile Device → VPS public endpoint:51820 → [VPS nftables DNAT] →
  WireGuard tunnel → pfSense:51820 → VPN VLAN
```

## pfSense Mobile WireGuard Instance

This is a **separate** WireGuard instance from the VPS tunnel.

### 1. Create Mobile Tunnel (VPN > WireGuard > Tunnels)

- **Description:** Mobile-VPN
- **Listen Port:** `51820`
- **Interface Keys:** Generate keypair (different from VPS tunnel)
- **Interface Addresses:** VPN VLAN gateway /24 (gateway for mobile peers)

### 2. Add Mobile Peers

For each mobile device, add a peer:

- **Tunnel:** Mobile-VPN
- **Description:** iPhone / iPad / Laptop / etc.
- **Endpoint:** (leave empty — mobile devices connect to us)
- **Public Key:** Generated on the mobile device
- **Allowed IPs:** Unique /32 on the VPN VLAN per peer
- **Pre-shared Key:** (recommended for additional security)

### 3. Assign Interface

- Add `tun_wg0` (mobile tunnel) as interface **WG_VPN**
- **IPv4:** Static — VPN VLAN gateway /24
- Enable interface

### 4. Firewall Rules (Firewall > Rules > WG_VPN)

| Action | Protocol | Source | Destination | Port | Description |
|--------|----------|--------|-------------|------|-------------|
| Pass | Any | VPN VLAN subnet | LAN subnets | * | Full tunnel access |
| Pass | TCP/UDP | VPN VLAN subnet | any | 53 | DNS |
| Pass | Any | VPN VLAN subnet | any | * | Internet access (if full tunnel) |

## Mobile Device Configuration

### WireGuard Client Config (iOS/Android/macOS/Windows)

```ini
[Interface]
PrivateKey = <device_private_key>
Address = <unique VPN VLAN IP>/32
DNS = <internal DNS server on services VLAN>

[Peer]
PublicKey = <pfsense_mobile_tunnel_public_key>
Endpoint = <VPS public endpoint>:51820
AllowedIPs = 0.0.0.0/0        # Full tunnel (all traffic through VPN)
# AllowedIPs = <internal CIDR>  # Split tunnel (only homelab traffic)
PersistentKeepalive = 25
```

### Key Points

- **Endpoint:** Always the VPS public endpoint on port 51820 — the VPS relay
- **DNS:** Internal DNS server on services VLAN (AdGuard) — routed through the tunnel
- **AllowedIPs:** `0.0.0.0/0` for full tunnel, or internal CIDR for split tunnel
- **PersistentKeepalive:** 25 seconds maintains connectivity through NAT

## Verification

1. Connect mobile device to cellular (not home WiFi)
2. Enable WireGuard on the device
3. Check pfSense Status > WireGuard — mobile peer should show handshake
4. Browse to AdGuard dashboard (services VLAN) — should be accessible
5. Check public IP — should show VPS IP (if full tunnel) or home IP (if split tunnel passes internet traffic to VPS)

## Adding New Peers

1. Generate keypair on the mobile device (WireGuard app > Add Tunnel > Generate)
2. Add peer in pfSense with the device's public key and a unique VPN VLAN IP
3. Configure the device with the pfSense mobile tunnel public key
4. Endpoint: VPS public endpoint on port 51820
