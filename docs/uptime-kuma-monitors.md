# Uptime Kuma — internal reachability monitors

Uptime Kuma is the **internal** reachability lane ([ADR 0011](decisions/0011-two-alerting-lanes-uptime-kuma-for-reachability-alertmanager-for-metrics.md)). It answers one question — "can I open a connection to this thing" — for services inside the network, plus ICMP to the VPS and the WireGuard tunnel peer. Anything metric-shaped (disk, memory, ingestion volume, certificate expiry, backup age) belongs to Prometheus + Alertmanager instead, not here.

The outside-in view is UptimeRobot's job, from outside the network — see [uptimerobot-setup.md](uptimerobot-setup.md). That split is settled.

Kuma runs on the monitoring VM at port 3001 and is configured through its web UI, hand-managed per the ADR-0005 precedent for UI-configured tools. **This document describes what currently exists, not what is recommended.**

## Notification channel

One channel, shared with Alertmanager: **ntfy** (`ntfy (homelab alerts)`, type `ntfy`, server `https://ntfy.sh`), set as default and applied to every monitor. The topic string is the credential and lives in Infisical at `/monitoring/alert_ntfy_topic` — it is not in this repo. Subscribe by opening that topic in the ntfy mobile app or at `https://ntfy.sh/<topic>`.

Verified working 2026-07-27: stopping `axosyslog` produced `AxoSyslog — syslog TCP 5514 Down [Uptime-Kuma]` on the topic within ~100 seconds, and starting it again produced the matching `Up` message within ~40 seconds.

## Monitors that exist

All 18 were confirmed UP on 2026-07-27. Targets use services-VLAN addresses; the real values live in the gitignored `network-data/local/uptime-kuma-monitors.json` (this repo is public).

| Monitor | Type | Target | Interval |
|---------|------|--------|----------|
| AdGuard — DNS resolution | DNS | `google.com` A via AdGuard | 60s |
| BIND9 — DNS resolution | DNS | `ns.<vlan>.<internal-zone>` A via BIND9 | 60s |
| AdGuard — web UI | HTTP | AdGuard `:3000` | 60s |
| Plex | HTTP | Plex `:32400/identity`, TLS ignored | 60s |
| Tautulli | HTTP | plex-services `:8181` | 60s |
| Jellyseerr | HTTP | plex-services `:5055` | 60s |
| Grafana | HTTP | monitoring `:3000` | 60s |
| OpenObserve | HTTP | monitoring `:5080/healthz` | 60s |
| Prometheus | HTTP | monitoring `:9090/-/healthy` | 60s |
| Alertmanager | HTTP | monitoring `:9093/-/healthy` | 60s |
| AxoSyslog — syslog TCP 5514 | TCP port | monitoring `:5514` | 60s |
| Infisical | HTTP | infisical `:8080` | 60s |
| Proxmox Backup Server | HTTP | pbs `:8007`, TLS ignored | 60s |
| UniFi controller | TCP port | unifi `:11443` | 60s |
| Homepage | HTTP | homepage `:3000` | 60s |
| VPS — public IP | Ping | VPS reserved IP | 60s |
| VPS — WireGuard tunnel peer | Ping | VPS tunnel address | 60s |
| Cloudflare Tunnel — Tautulli | HTTP | `https://tautulli.<public-domain>` | 120s |

Defaults for every monitor: 2 retries (1 for AxoSyslog, so the syslog path trips fast), 60s retry interval, 16s timeout, accepted status `200-299` — widened to `300-399` for services that redirect to a login page.

### Deliberate omissions

- **UniFi is a TCP port check, not HTTP.** The controller must not be probed with credentials: the `monitoring_users` role targets the classic API and its `/status` gate now passes on port 11443, so authenticating against it risks locking the admin account.
- **No "Plex via VPS" or "Valheim via VPS" monitor.** Those are outside-in paths and belong to UptimeRobot. Empirically they do not work from inside the network anyway (the external hostname does not hairpin), and Valheim is UDP, so the TCP port check an earlier draft of this document recommended could never have passed.
- **No OpenObserve ingestion-volume check.** Reachability cannot see it — during the 2026-07 incident the port answered `200` for 24 days while ingesting nothing. That detection is `SyslogIngestionStalled` in `alert.rules.yml.j2`, evaluated by Prometheus.

## Rebuilding

Kuma keeps everything in `/var/lib/uptime-kuma/kuma.db` on the monitoring VM. **That path must be in the backup set** — the Ansible role creates the directory but no monitor configuration.

To reseed a fresh Kuma (after creating the admin account through the UI on first visit):

```bash
scp scripts/seed_uptime_kuma.py network-data/local/uptime-kuma-monitors.json <monitoring-vm>:/tmp/
ssh <monitoring-vm>
sudo python3 /tmp/seed_uptime_kuma.py /tmp/uptime-kuma-monitors.json "<ntfy-topic>"
sudo docker restart uptime-kuma      # Kuma loads monitors from the DB at boot
```

The script is idempotent — monitors and the channel are matched by name and skipped if already present. Start from `network-data/uptime-kuma-monitors.example.json` and fill in real addresses.
