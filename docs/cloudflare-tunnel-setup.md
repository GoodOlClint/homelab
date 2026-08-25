# Cloudflare Tunnel — Application Mapping

`cloudflared` runs in the `plex-services` namespace on the cluster (ADR 0037); routes are hand-set in the dashboard and target in-cluster Service DNS.

## Through Cloudflare Tunnel

These services are HTTP-based dashboards, within Cloudflare ToS:

| Subdomain | Target | Port | Notes |
|-----------|--------|------|-------|
| `auth.<media domain>` | `authentik-server.authentik-ext.svc.cluster.local` | 80 | external authentik realm (ADR 0040 P5c, [authentik-setup.md](authentik-setup.md)) |
| `tautulli.<domain>` | plex-services VM | 8181 | Plex analytics |
| `requests.<domain>` | plex-services VM | 5055 | Jellyseerr media requests |
| `grafana.<domain>` | Monitoring VM | 3000 | Dashboards |
| `logs.<domain>` | Monitoring VM | 5080 | OpenObserve log viewer |
| `status.<domain>` | Monitoring VM | 3001 | Uptime Kuma status page |

Configure these routes in the Cloudflare Zero Trust dashboard under **Networks > Tunnels > <tunnel-name> > Public Hostname**.

## NOT Through Cloudflare Tunnel

These use the VPS WireGuard relay instead:

| Service | Why Not Tunnel | Access Method |
|---------|---------------|---------------|
| Plex media streaming | ToS violation for media traffic | `plex.<media domain>:32400` via VPS relay |
| Valheim game server | UDP, not HTTP | VPS relay UDP 2456-2458 |
| Mobile WireGuard | UDP relay | VPS relay UDP 51820 |

## Access Control

All tunneled applications should be protected with Cloudflare Access policies that authenticate against Authentik (see [authentik-setup.md](authentik-setup.md)).
