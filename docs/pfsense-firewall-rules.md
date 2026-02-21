# pfSense Firewall Rules — VPS Relay Traffic

## Overview

These rules allow traffic arriving from the VPS WireGuard tunnel to reach internal services. The VPS forwards Plex, Valheim, and mobile WireGuard traffic through the tunnel.

## Interfaces

| Interface | Address | Purpose |
|-----------|---------|---------|
| WG_VPS | VPN transit subnet gateway /24 | VPS relay tunnel |
| WG_VPN | VPN VLAN gateway /24 | Mobile VPN peers |

## WG_VPS Interface Rules

Traffic from the VPS relay tunnel to internal services:

| # | Action | Proto | Source | Dest | Port | Description |
|---|--------|-------|--------|------|------|-------------|
| 1 | Pass | TCP | VPN transit subnet | Plex VM (media VLAN) | 32400 | Plex streaming via VPS |
| 2 | Pass | UDP | VPN transit subnet | Docker VM (services VLAN) | 2456-2458 | Valheim via VPS |
| 3 | Pass | UDP | VPN transit subnet | WG_VPN address | 51820 | Mobile WG relay |
| 4 | Pass | Any | VPN transit subnet | VPN VLAN subnet | * | VPS→Mobile VPN subnet |
| 5 | Block | Any | any | any | * | Default deny |

## WG_VPN Interface Rules

Traffic from mobile VPN peers to internal network:

| # | Action | Proto | Source | Dest | Port | Description |
|---|--------|-------|--------|------|------|-------------|
| 1 | Pass | TCP/UDP | VPN VLAN subnet | AdGuard on services VLAN | 53 | DNS (AdGuard) |
| 2 | Pass | Any | VPN VLAN subnet | All internal subnets | * | Access homelab subnets |
| 3 | Pass | Any | VPN VLAN subnet | any | * | Internet (full tunnel) |
| 4 | Block | Any | any | any | * | Default deny |

## NAT / Port Forward Rules

If services aren't directly routable from the tunnel, add port forwards:

| Interface | Proto | Dest Port | Redirect Target | Redirect Port | Description |
|-----------|-------|-----------|-----------------|---------------|-------------|
| WG_VPS | TCP | 32400 | Plex VM IP | 32400 | Plex via relay |
| WG_VPS | UDP | 2456-2458 | Docker VM IP | 2456-2458 | Valheim via relay |

## Traffic Flow

### Plex (TCP 32400)
```
Internet → VPS:32400 → [nftables DNAT → pfSense tunnel peer:32400] →
  WireGuard tunnel → pfSense WG_VPS → NAT/route → Plex VM:32400
```

### Valheim (UDP 2456-2458)
```
Internet → VPS:2456 → [nftables DNAT → pfSense tunnel peer:2456] →
  WireGuard tunnel → pfSense WG_VPS → NAT/route → Docker VM:2456
```

### Mobile WireGuard (UDP 51820)
```
Mobile → VPS:51820 → [nftables DNAT → pfSense tunnel peer:51820] →
  WireGuard tunnel → pfSense WG_VPN:51820 → terminates VPN session
```

## Notes

- The VPS relay is transparent — it DNATs and forwards, never decrypts
- pfSense terminates both the VPS tunnel (WG_VPS) and mobile sessions (WG_VPN)
- Mobile traffic is double-encrypted: mobile↔pfSense WireGuard inside pfSense↔VPS WireGuard
- All rules should be as specific as possible — avoid "pass any any"
