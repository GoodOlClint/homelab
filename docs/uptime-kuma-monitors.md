# Uptime Kuma — Recommended Monitors

Uptime Kuma runs on the monitoring VM at port 3001. Configure monitors via the web UI after deployment.

## Initial Setup

1. Navigate to `http://<monitoring-vm-ip>:3001`
2. Create an admin account on first visit

## Recommended Monitors

| Monitor | Type | Target | Interval |
|---------|------|--------|----------|
| VPS Public IP | Ping | VPS reserved IP | 60s |
| VPS WireGuard Tunnel | Ping | pfSense tunnel peer IP | 60s |
| Plex via VPS | HTTP(S) | `https://plex.clintflix.tv:32400/identity` | 60s |
| Valheim via VPS | TCP Port | VPS_IP:2456 | 120s |
| Plex (internal) | HTTP | `http://<plex-vm>:32400/web` | 60s |
| Tautulli | HTTP | `http://<plex-services-vm>:8181` | 60s |
| Jellyseerr | HTTP | `http://<plex-services-vm>:5055` | 60s |
| Grafana | HTTP | `http://<monitoring-vm>:3000` | 60s |
| OpenObserve | HTTP | `http://<monitoring-vm>:5080/healthz` | 60s |
| Prometheus | HTTP | `http://<monitoring-vm>:9090/-/healthy` | 60s |
| AdGuard DNS | DNS | Query `google.com` against AdGuard IP | 60s |
| Cloudflare Tunnel | HTTP | Tunneled service URL (e.g., `https://tautulli.<domain>`) | 120s |

## Notification Setup

Configure at least one notification channel (e.g., Pushover, Telegram, or email) to receive downtime alerts.
