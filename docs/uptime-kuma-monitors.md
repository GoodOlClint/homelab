# Uptime Kuma — internal reachability monitors

Uptime Kuma is the **internal** reachability lane ([ADR 0011](decisions/0011-two-alerting-lanes-uptime-kuma-for-reachability-alertmanager-for-metrics.md), amended 2026-08-24). It answers one question — "can I open a connection to this thing" — for services inside the network, plus ICMP to the VPS and the WireGuard tunnel peer. Anything metric-shaped (disk, memory, ingestion volume, certificate expiry, backup age) belongs to Prometheus + Alertmanager.

The outside-in view is UptimeRobot's job, from outside the network — see [uptimerobot-setup.md](uptimerobot-setup.md). That split is settled.

Kuma runs on the Talos cluster (`kubernetes/monitoring/`, ADR 0036) at `https://uptime-kuma.<service domain>`. **Its configuration is Ansible-managed**: every monitor and the notification channel are declared in [ansible/playbooks/uptime-kuma.yml](../ansible/playbooks/uptime-kuma.yml) and applied through the [`goodolclint.uptime_kuma`](https://github.com/GoodOlClint/ansible-collection-uptime_kuma) collection (`make uptime-kuma`; `CHECK=1` for check mode with diff). Targets derive from the inventory and `vlans.yaml`, so a guest re-home is a re-run, not a UI edit. The admin login is `goodolclint` with Infisical `/monitoring/uptime_kuma_admin_password`.

A monitor added in the UI is not deleted by the playbook (monitors are matched by name; nothing prunes), but it will not survive a rebuild either — add it to the playbook instead.

## Notification channel

One channel, shared with Alertmanager: **ntfy** (`ntfy (homelab alerts)`, type `ntfy`, server `https://ntfy.sh`), default + applied to every monitor (`notification_names` in `uptime_kuma_monitor_defaults`). The topic string is the credential and lives in Infisical at `/monitoring/alert_ntfy_topic`. Subscribe by opening that topic in the ntfy mobile app or at `https://ntfy.sh/<topic>`.

## Monitors

25 monitors — the authoritative list is the playbook. No monitor ignores TLS (ADR 0040 forbids it on Traefik-fronted apps; the ingress cert is Let's Encrypt since P5b). Per-monitor defaults: 60 s interval, 2 retries (1 for AxoSyslog, so the syslog path trips fast), 60 s retry interval, 16 s timeout, accepted status `200-299` — widened to `300-399` for services that redirect to a login page.

| Monitor | Type | Target |
|---------|------|--------|
| AdGuard — DNS resolution | DNS | `google.com` A via the AdGuard VIP |
| BIND9 — DNS resolution | DNS | `ns.<mgmt zone>` A via the BIND VIP |
| AdGuard — web UI | HTTP | AdGuard VIP `:3000` |
| Plex | HTTP | `https://plex.<media domain>:32400/identity` — the Let's Encrypt cert `plex_certificate` installs; Plex has secure connections *Required*, so plain HTTP from the network gets an empty reply |
| Jellyfin | HTTP | `https://jellyfin.<media domain>/health` through Traefik (Let's Encrypt `*.<media domain>`, ADR 0040 P5d); no via-VPS row, same reason as Plex |
| Tautulli / Jellyseerr / Sonarr / Radarr / Sabnzbd | HTTP | in-cluster `*.plex-services.svc.cluster.local` (ADR 0037) |
| Grafana / OpenObserve / Prometheus / Alertmanager | HTTP | `https://<name>.<service domain>` through Traefik (Let's Encrypt, verified) |
| AxoSyslog — syslog TCP 5514 | TCP port | syslog LB (`openobserve_listen_host`) |
| Infisical | HTTP | infisical `:8080` |
| Proxmox Backup Server | TCP port | pbs `:8007` (vlan30 since the re-home; self-signed cert, so no HTTP check until the per-host ACME lands) |
| UniFi controller | TCP port | unifi `:11443` |
| apt-cacher-ng — proxy TCP 3142 | TCP port | apt-cache `:3142` |
| Homepage | HTTP | in-cluster `homepage.homepage.svc.cluster.local` (the ingress host sits behind forward-auth since P5c) |
| authentik — internal realm | HTTP | `https://auth.<service domain>/-/health/ready/` through Traefik |
| authentik — external realm | HTTP | in-cluster `authentik-server.authentik-ext.svc.cluster.local/-/health/ready/` (the tunnel path is the operator's phone test until P5d adds a row) |
| VPS — public IP | Ping | `vps.<media domain>` |
| VPS — WireGuard tunnel peer | Ping | VPS tunnel address (`vps_wg_tunnel.tunnel_address`) |
| Cloudflare Tunnel — Tautulli | HTTP | `https://tautulli.<media domain>`, 120 s |
| Valheim — PlayFab lobby | JSON query | `valheim-status.games.svc.cluster.local:8081/status.json`, `online == true` (ADR 0038) |

### Deliberate omissions

- **UniFi is a TCP port check, not HTTP.** The controller must not be probed with credentials: the `monitoring_users` role targets the classic API and its `/status` gate now passes on port 11443, so authenticating against it risks locking the admin account.
- **No "Plex via VPS" or "Valheim via VPS" monitor.** Those are outside-in paths and belong to UptimeRobot. Empirically they do not work from inside the network anyway (the external hostname does not hairpin).
- **Valheim is monitored over HTTP, not on its game port.** The game port is UDP and answers no query — the A2S responder does not exist under crossplay, because `ZNet.OpenServer()` only creates the Steam game server on the Steamworks backend. What Kuma watches instead is the `valheim-status` sidecar's `status.json`, rewritten every 60 s from a PlayFab lobby query by server name.
- **A visible lobby is not a joinable server.** 2026-08-22: the lobby answered ONLINE all day while every join failed — the server's PlayFab Party network session was dead and the relay handshake never reached the server. A container restart rebuilt it. Kuma cannot see this; the server pod's liveness probe is the guard.
- **Kuma does not check status.json freshness.** A frozen `valheim-status` leaves a stale but valid file and Kuma stays green. That gap is covered by the server container's liveness probe, which requires the file's mtime to be under 3 minutes old and `online: true` (`kubernetes/games/app.yaml`).
- **No OpenObserve ingestion-volume check.** Reachability cannot see it — during the 2026-07 incident the port answered `200` for 24 days while ingesting nothing. That detection is `SyslogIngestionStalled`, evaluated by Prometheus.

## Rebuilding

Kuma keeps everything in `kuma.db` on the `uptime-kuma` ceph-rbd PVC (namespace `monitoring`). On a fresh instance: set `uptime_kuma_bootstrap_admin: true` for the first `make uptime-kuma` (the role's `uptime_kuma_setup` creates the admin from the Infisical password; a no-op once setup is done), then every later run converges the monitor set. History is not re-created — the PVC is what preserves it.
