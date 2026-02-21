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

## Verification

1. **Check tunnel status:** Status > WireGuard — peer should show "Latest Handshake" timestamp
2. **Ping test:** From pfSense Diagnostics > Ping, ping VPS tunnel IP
3. **Handshake timing:** Should update every ~25 seconds due to PersistentKeepalive

## Troubleshooting

- **No handshake:** Check that pfSense endpoint/port is correct, VPS firewall allows UDP 51821
- **Handshake but no traffic:** Check pfSense firewall rules on WG_VPS interface
- **Intermittent connectivity:** Verify PersistentKeepalive=25 is set on the pfSense peer
