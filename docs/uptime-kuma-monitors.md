# Uptime Kuma — internal reachability monitors

Uptime Kuma is the **internal** reachability lane ([ADR 0011](decisions/0011-two-alerting-lanes-uptime-kuma-for-reachability-alertmanager-for-metrics.md)). It answers one question — "can I open a connection to this thing" — for services inside the network, plus ICMP to the VPS and the WireGuard tunnel peer. Anything metric-shaped (disk, memory, ingestion volume, certificate expiry, backup age) belongs to Prometheus + Alertmanager instead, not here.

The outside-in view is UptimeRobot's job, from outside the network — see [uptimerobot-setup.md](uptimerobot-setup.md). That split is settled.

Kuma runs on the Talos cluster (`kubernetes/monitoring/`, ADR 0036) at `https://uptime-kuma.<domain>` and is configured through its web UI, hand-managed per the ADR-0005 precedent for UI-configured tools. **This document describes what currently exists, not what is recommended.**

## Notification channel

One channel, shared with Alertmanager: **ntfy** (`ntfy (homelab alerts)`, type `ntfy`, server `https://ntfy.sh`), set as default and applied to every monitor. The topic string is the credential and lives in Infisical at `/monitoring/alert_ntfy_topic` — it is not in this repo. Subscribe by opening that topic in the ntfy mobile app or at `https://ntfy.sh/<topic>`.

Verified working 2026-07-27: stopping `axosyslog` produced `AxoSyslog — syslog TCP 5514 Down [Uptime-Kuma]` on the topic within ~100 seconds, and starting it again produced the matching `Up` message within ~40 seconds.

## Monitors that exist

22 monitors. The original 18 were confirmed UP on 2026-07-27. Sonarr, Radarr and Sabnzbd were added in the UI at some point after that and were found live-but-unrecorded on 2026-08-10 — they are now back in the seeder's target list, because a rebuild driven by that list would otherwise have dropped them silently. Valheim — PlayFab lobby was seeded 2026-08-10 and confirmed UP on its first heartbeat (`JSON query passes (comparing playfab == playfab)`). apt-cacher-ng — proxy TCP 3142 was added to the seeder target list 2026-08-11 with the apt-cache VM (ADR 0021) and is pending its UI seed / first heartbeat.

Targets use services-VLAN addresses; the real values live in the gitignored `network-data/local/uptime-kuma-monitors.json` (this repo is public). **Adding a monitor in the UI without adding it here makes it invisible to a rebuild** — the drift above is the standing example.

| Monitor | Type | Target | Interval |
|---------|------|--------|----------|
| AdGuard — DNS resolution | DNS | `google.com` A via AdGuard | 60s |
| BIND9 — DNS resolution | DNS | `ns.<vlan>.<internal-zone>` A via BIND9 | 60s |
| AdGuard — web UI | HTTP | AdGuard `:3000` | 60s |
| Plex | HTTP | Plex `:32400/identity`, TLS ignored | 60s |
| Tautulli | HTTP | `tautulli.plex-services.svc.cluster.local:8181/status` (in-cluster, ADR 0037) | 60s |
| Jellyseerr | HTTP | `seerr.plex-services.svc.cluster.local:5055` (in-cluster, ADR 0037) | 60s |
| Grafana | HTTP | `https://grafana.<domain>`, TLS ignored (homelab-ca) | 60s |
| OpenObserve | HTTP | `https://openobserve.<domain>/healthz`, TLS ignored | 60s |
| Prometheus | HTTP | `https://prometheus.<domain>/-/healthy`, TLS ignored | 60s |
| Alertmanager | HTTP | `https://alertmanager.<domain>/-/healthy`, TLS ignored | 60s |
| AxoSyslog — syslog TCP 5514 | TCP port | syslog LB (services offset 66) `:5514` | 60s |
| Infisical | HTTP | infisical `:8080` | 60s |
| Proxmox Backup Server | HTTP | pbs `:8007`, TLS ignored | 60s |
| UniFi controller | TCP port | unifi `:11443` | 60s |
| apt-cacher-ng — proxy TCP 3142 | TCP port | apt-cache `:3142` | 60s |
| Homepage | HTTP | homepage `:3000` | 60s |
| VPS — public IP | Ping | VPS reserved IP | 60s |
| VPS — WireGuard tunnel peer | Ping | VPS tunnel address | 60s |
| Cloudflare Tunnel — Tautulli | HTTP | `https://tautulli.<public-domain>` | 120s |
| Sonarr | HTTP | `sonarr.plex-services.svc.cluster.local:8989/ping` (in-cluster, ADR 0037) | 60s |
| Radarr | HTTP | `radarr.plex-services.svc.cluster.local:7878/ping` (in-cluster, ADR 0037) | 60s |
| Sabnzbd | HTTP | `sabnzbd.plex-services.svc.cluster.local:8080/api?mode=version` (in-cluster, ADR 0037) | 60s |
| Valheim — PlayFab lobby | JSON query | docker `:8081/status.json`, `online == true` (the `valheim-status` sidecar, keyed on the PlayFab entity ID; re-pointed 2026-08-23) | 60s |

Defaults for every monitor: 2 retries (1 for AxoSyslog, so the syslog path trips fast), 60s retry interval, 16s timeout, accepted status `200-299` — widened to `300-399` for services that redirect to a login page.

### Deliberate omissions

- **UniFi is a TCP port check, not HTTP.** The controller must not be probed with credentials: the `monitoring_users` role targets the classic API and its `/status` gate now passes on port 11443, so authenticating against it risks locking the admin account.
- **No "Plex via VPS" or "Valheim via VPS" monitor.** Those are outside-in paths and belong to UptimeRobot. Empirically they do not work from inside the network anyway (the external hostname does not hairpin).
- **Valheim is monitored over HTTP, not on its game port.** The game port is UDP and answers no query — the A2S responder does not exist under crossplay, because `ZNet.OpenServer()` only creates the Steam game server on the Steamworks backend. What Kuma watches instead is the container's own `status.json`, published on `:8080` and rewritten every 10s by `valheim-status` from a PlayFab lobby query. The monitor asserts `platform == playfab`: on a failed query the status file carries only `error` and a timestamp, so the field is absent and Kuma's JSON query fails (a null or undefined query result is an error in Kuma, which is also why `error == null` cannot be the test — null is the *healthy* value there). This proves the game server is registered with PlayFab; it does not prove a player can traverse the VPS relay to reach it.
- **A visible lobby is not a joinable server.** 2026-08-22: the lobby answered ONLINE all day (`valheim-playfab-status.mjs --code`) while every join failed — the server's PlayFab *Party network* session from the 08:03 UTC start was dead, and the relay handshake never reached the server (no `PlayFab listen socket child connected` line, `Connections 0` for 10 h). A container restart rebuilt the Party network and a player joined 30 s later. Tell-tale at the bad start: `registered with join code` immediately followed by `Created new join code` (two codes in 3 s); the healthy start shows one. No external probe can exercise the relay; the lobby monitor proves registration only.
- **Kuma does not check status.json freshness.** A frozen `valheim-status` leaves a stale but valid file and Kuma stays green. That gap is covered by the container's own healthcheck, which also requires the file's mtime to be under 2 minutes old (`roles/docker/templates/docker-compose.yml.j2`).
- **No OpenObserve ingestion-volume check.** Reachability cannot see it — during the 2026-07 incident the port answered `200` for 24 days while ingesting nothing. That detection is `SyslogIngestionStalled` in `alert.rules.yml.j2`, evaluated by Prometheus.

## Rebuilding

Kuma keeps everything in `kuma.db` on the `uptime-kuma` ceph-rbd PVC (namespace `monitoring`, mounted at `/app/data`). Nothing in `kubernetes/monitoring/` creates monitors; the 2026-08-23 move carried the database over from LXC 203 (`make monitoring-migrate`) and repointed the five self-monitors above with SQL, the seeder's own mechanism.

To reseed a fresh Kuma (after creating the admin account through the UI on first visit):

```bash
kubectl -n monitoring scale deploy/uptime-kuma --replicas=0
REGISTRY=registry.<domain> envsubst < kubernetes/monitoring/migrate.yaml | kubectl apply -f -   # a throwaway pod mounting the PVC
kubectl -n monitoring cp scripts/seed_uptime_kuma.py migrate:/seed.py
kubectl -n monitoring cp network-data/local/uptime-kuma-monitors.json migrate:/targets.json
kubectl -n monitoring exec migrate -- env KUMA_DB=/uptime-kuma/data/kuma.db python3 /seed.py /targets.json "<ntfy-topic>"
kubectl -n monitoring delete pod migrate && kubectl -n monitoring scale deploy/uptime-kuma --replicas=1
sudo docker restart uptime-kuma      # Kuma loads monitors from the DB at boot
```

The script is idempotent — monitors and the channel are matched by name and skipped if already present. Start from `network-data/uptime-kuma-monitors.example.json` and fill in real addresses.
