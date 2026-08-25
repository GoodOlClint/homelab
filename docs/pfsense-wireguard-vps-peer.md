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
| Pass | TCP | VPN transit subnet | Traefik LB IP (services offset 65, ADR 0040 P5d) | 443 | Jellyfin via VPS |
| Pass | UDP | VPN transit subnet | Valheim LB IP (services offset 67, ADR 0038) | 2456-2458 | Valheim via VPS |
| Pass | UDP | VPN transit subnet | WG_VPN address | 51820 | Mobile WG relay |
| Pass | Any | VPN transit subnet | VPN VLAN subnet | * | Mobile VPN subnet |

### 5. NAT Rules (if needed)

**Valheim needs a port forward, not just a pass rule** — Firewall › NAT › Port Forward on WG_VPS: UDP, destination *WG_VPS address* 2456–2458, redirect target = the Valheim MetalLB address (services offset 67), redirect ports 2456–2458, associated filter rule. This forward was found **absent** on 2026-08-24 (config.xml had no entry for 2456 since the cutover; players had been joining through the PlayFab relay only) and was re-added by hand as part of P4d. Verify from the workstation with `ssh ansible@<pfsense> grep -c 2456 /conf/config.xml` (non-zero). The VPS side (`vps_nftables` DNAT to the pfSense tunnel IP) does not change when the target moves.

**Jellyfin (ADR 0040 P5d) is the same shape as Valheim** — Firewall › NAT › Port Forward on WG_VPS: TCP, destination *WG_VPS address* 443, redirect target = the Traefik MetalLB address (services offset 65), redirect port 443, associated filter rule. The VPS side (`vps_nftables` DNAT 443 → the pfSense tunnel IP, Vultr firewall rule `jellyfin`/`jellyfin_v6`) is Ansible/Terraform-owned; this row is the hand step. Verify with `ssh ansible@<pfsense> grep -c '<local-port>443</local-port>' /conf/config.xml` (non-zero), then from the VPS `curl -sI --resolve jellyfin.<media domain>:443:<VPS reserved IPv4> https://jellyfin.<media domain>/health` = 200 with no `cf-ray`.

If Plex/Valheim are on different VLANs, ensure pfSense routes or NATs the traffic appropriately:

- Traffic arrives on WG_VPS interface destined for specific ports
- pfSense forwards to the actual service IPs on internal VLANs

## Endpoint, keys, and AllowedIPs (hard-won 2026-07-27)

- **Peer endpoint on pfSense = the VPS reserved IPv4** (see `terraform output vps_reserved_ip`), port 51821. Never the instance IPv6: a rebuild changes the instance MAC and therefore its SLAAC address, silently orphaning the endpoint — and the IPv6 path drops large WireGuard UDP (see MTU section).
- **Peer public key on pfSense must match the Infisical `/vps` keypair** (`vps_wg_public_key`). Rebuilds always redeploy the Infisical private key; if keys are ever rotated, update Infisical *and* pfSense together, or the next rebuild resurrects the old key and handshakes fail silently.
- **VPS-side peer AllowedIPs must cover the internal supernets** (IPv4 /12 + the ULA /48), not just the transit /24. Cryptokey routing silently drops LAN-sourced SSH/pings to the VPS and breaks its telegraf/rsyslog egress otherwise. Real values live in gitignored `ansible/group_vars/local/all.yml` (`vps_wg_tunnel.peer_allowed_ips`).

## Tunnel dead after a VPS rebuild: kill the stale pf state (2026-08-22)

Symptom: `make vps-rebuild` fails at "Wait for WireGuard handshake"; on pfSense `wg show tun_wg1` shows the sent counter climbing but no handshake, a WAN packet capture on UDP 51821 shows **zero packets leaving**, and the firewall log shows no blocks. Keys, endpoint, routes and the VPS side are all correct.

Cause: while the old VPS was alive its keepalives created an inbound `if-bound` + `reply-to` pf state for `pfsense:51821 <-> vps:51821` under the WAN pass rule. pfSense's own outbound initiations share that 4-tuple, so they ride the stale state instead of creating a new one — and refresh it every keepalive, so it never expires. After the instance behind the reserved IP is replaced the state silently eats every packet.

Fix (root on pfSense): `pfctl -ss | grep 51821` to see it, then `pfctl -k 216.128.142.97; pfctl -k 0.0.0.0/0 -k 216.128.142.97`. The handshake lands within one keepalive. Then `make vps-close-ssh`.

### Peers that "randomly" die at a reboot: the kernel peer table vs `config.xml` (2026-08-22)

The WireGuard package loads `config.xml` into `if_wg` only on *Apply* and at boot. A peer edited and applied keeps working from the kernel table even after `config.xml` is written with older keys — right up to the next reboot, which reloads the file and kills every peer whose key moved in between. Seen 2026-08-22: between Jul 30 and Aug 18 the iPhone peer reverted to its pre-reinstall key and the VPS peer to an older key while other sections kept advancing (an older copy of the WireGuard section written back — stale edit form or a Packages-area restore; the window had rotated out of the 30-revision history, so the trigger is unconfirmed). Both kept working from the kernel until the 26.07 reboot. Signature: several peers fail together at a reboot, `wg show tun_wg0 dump` holds keys the clients no longer have, and the revision log (`/cf/conf/backup/*.xml`, `<revision>` block, readable unprivileged) shows no WireGuard edits. Fix: re-enter each client's current public key and **Apply Changes** (saving alone does not touch the kernel — verify with `wg show`). Keep a dated config export off-box (`~/Downloads/config-pfSense.*.xml` was what proved the revert) and raise Diagnostics → Backup & Restore → *Backup Count* above the default 30 so the history outlives a quiet month. Diagnostic split that got here: WAN packet capture, `pfctl -vsr` counters on the `:51820` rule, `sockstat -l` for port ownership, then `if_wg` silence = key mismatch.

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
