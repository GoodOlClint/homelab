# Split DNS — AdGuard Home DNS Rewrites

When on the home network, services should resolve directly to internal IPs, bypassing Cloudflare Tunnel.

## AdGuard DNS Rewrites

In AdGuard Home web UI → **DNS rewrites**, add:

| Domain | Internal IP | Service |
|--------|------------|---------|
| `auth.<domain>` | Docker VM services VLAN IP | Authentik |
| `tautulli.<domain>` | plex-services VM services VLAN IP | Tautulli |
| `requests.<domain>` | plex-services VM services VLAN IP | Jellyseerr |
| `grafana.<domain>` | Monitoring VM services VLAN IP | Grafana |
| `logs.<domain>` | Monitoring VM services VLAN IP | OpenObserve |
| `status.<domain>` | Monitoring VM services VLAN IP | Uptime Kuma |

## How It Works

- **Internal access:** DNS resolves to LAN IP → direct connection to service (no Cloudflare dependency)
- **External access:** DNS resolves to Cloudflare → Tunnel → Cloudflare Access → Authentik → service

## Break-Glass Access

These always work regardless of DNS, Cloudflare, or Authentik status:

- Direct SSH to any VM via management VLAN IP
- pfSense web GUI on LAN IP
- Direct container ports via services VLAN IP (e.g., `http://<vm-ip>:3000` for Grafana)
