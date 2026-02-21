# Monitoring & Observability Stack Review

## Current State Summary

Your monitoring stack is architecturally solid. You have a well-integrated collection
pipeline (Telegraf + rsyslog on every host), a central metrics engine (Prometheus),
long-term storage (OpenObserve), syslog aggregation (AxoSyslog), and 8 provisioned
Grafana dashboards covering systems, DNS, Docker, Proxmox, PBS, Synology, and UniFi.

What follows are the gaps, ranked by impact.

---

## Critical Gaps

### 1. No Alerting (Alertmanager + Alert Rules)

**This is the single largest gap.** Prometheus has no `rule_files` configured, no
Alertmanager container in the compose stack, and no notification channels. A full
infrastructure outage would go unnoticed until someone checks Grafana manually.

**What to add:**
- Alertmanager container in the monitoring docker-compose
- Prometheus alert rules file with thresholds for:
  - Host down (ICMP/node-exporter unreachable)
  - High CPU/memory/disk usage
  - Service endpoint down (blackbox HTTP probe failures)
  - DNS resolution failures
  - Backup job failures (PBS)
  - Container restarts / unhealthy containers
  - NFS mount failures
  - Speedtest degradation
- Notification routing to email, Slack, Discord, or a webhook of your choice
- A Grafana "Alerts Overview" dashboard

**Suggested alert rules (starter set):**

| Alert | Condition | Severity |
|-------|-----------|----------|
| HostDown | `up == 0` for 2m | critical |
| HighCPU | `cpu_usage > 90%` for 5m | warning |
| HighMemory | `mem_used_percent > 90%` for 5m | warning |
| DiskAlmostFull | `disk_used_percent > 85%` for 5m | warning |
| DiskFull | `disk_used_percent > 95%` for 1m | critical |
| ServiceDown | `probe_success == 0` for 3m | critical |
| DNSFailure | `probe_success{job="blackbox-dns"} == 0` for 2m | critical |
| BackupStale | PBS last backup > 36h | warning |
| HighPacketLoss | `ping_percent_packet_loss > 10%` for 5m | warning |
| ContainerUnhealthy | Container health check failing for 3m | warning |
| NFS Mount Failure | NFS operations errors for 2m | critical |
| SpeedtestDegraded | Download < 50% of baseline for 1h | warning |

### 2. No Certificate Expiry Monitoring

You have HTTPS endpoints (Proxmox, PBS, UniFi, Plex) but the Blackbox Exporter only
checks `http_2xx` -- it doesn't monitor TLS certificate expiration. A single
`tls_connect` module in blackbox.yml + a Prometheus scrape job would catch expiring
certs 30 days out.

### 3. No pfSense / Firewall Monitoring

Your pfSense firewall is configured via Ansible but has zero metrics collection.
pfSense exposes metrics through:
- **SNMP** (already have snmp-exporter, just need pfSense targets)
- **pfSense Telegraf package** (native plugin available in pfSense)
- A dedicated pfSense Prometheus exporter

This is a blind spot for your most critical network device.

---

## Significant Gaps

### 4. No Uptime/Status Page (Uptime Kuma)

Blackbox Exporter probes endpoints but provides no historical uptime tracking,
incident history, or status page. [Uptime Kuma](https://github.com/louislam/uptime_kuma)
is a lightweight, self-hosted status monitor that would complement your existing
blackbox probes with:
- Historical uptime percentages
- Response time graphs
- Maintenance windows
- Notification integrations (email, Slack, Discord, Telegram, etc.)
- A status page you can share with household members

**Where to deploy:** Docker VM alongside your other containers. Single container,
SQLite-backed, minimal resources (~256MB RAM).

### 5. Application-Level Metrics Are Missing

Your media stack (Sonarr, Radarr, Plex, etc.) and other services are only monitored
via basic HTTP health checks. You're missing application-specific metrics:

| Service | Available Metrics Source | What You'd Gain |
|---------|------------------------|-----------------|
| **Plex** | [Tautulli Exporter](https://github.com/nwalke/tautulli_exporter) or Tautulli API | Active streams, transcoding sessions, library sizes |
| **AdGuard Home** | [AdGuard Exporter](https://github.com/ebrianne/adguard-exporter) | Query volume, blocked %, top clients, DNS latency |
| **Sonarr/Radarr** | [Exportarr](https://github.com/onedr0p/exportarr) | Queue sizes, missing episodes, download activity |
| **SABnzbd** | [SABnzbd Exporter](https://github.com/msroest/sabnzbd_exporter) | Download speed, queue depth, disk space |

**Exportarr** is particularly valuable -- it's a single exporter binary that supports
Sonarr, Radarr, Lidarr, Readarr, Prowlarr, and Bazarr via their APIs. One container
per *arr instance, minimal config.

### 6. No Container-Level Metrics (cAdvisor)

Telegraf's Docker plugin provides basic container stats, but
[cAdvisor](https://github.com/google/cadvisor) provides much richer per-container
metrics:
- Per-container CPU throttling, memory pressure, OOM events
- Container filesystem I/O
- Network I/O per container
- Container start/stop events

**Where to deploy:** One cAdvisor instance on each Docker host (openobserve, docker,
plex-services). Each scrapes the local Docker socket and exposes `/metrics` for
Prometheus.

### 7. Log Pipeline Needs Enrichment

Your log pipeline works end-to-end (rsyslog -> AxoSyslog -> OpenObserve), but it's
forwarding raw syslog without any:
- **Structured parsing** -- application logs from Docker containers aren't parsed
  into structured fields
- **Log-level filtering** -- everything goes to the same stream regardless of severity
- **Log-based alerting** -- no rules to alert on error spikes or specific patterns
- **Container log collection** -- Docker container stdout/stderr logs are not captured
  by rsyslog (only host syslog is forwarded)

**Options to improve:**
- **Promtail + Loki** (Grafana-native): Promtail collects Docker logs and host logs,
  ships to Loki. Loki integrates natively with Grafana for querying/alerting. This is
  the most natural fit with your existing Grafana setup.
- **Vector** (Datadog's agent): More powerful than Promtail, can replace both rsyslog
  and Telegraf in one agent. Supports transforms, filtering, and routing.
- **Enhance AxoSyslog**: Add parsing filters and log routing rules to your existing
  AxoSyslog config. Lowest effort, but less flexible than Loki.

### 8. No Grafana Dashboard for Logs

Even though OpenObserve stores your syslog data, there's no Grafana dashboard for
log analytics (error rates over time, top error sources, log volume by host). Adding
an OpenObserve logs datasource in Grafana and a basic "Log Overview" dashboard would
close this gap.

---

## Nice-to-Have Improvements

### 9. NVIDIA GPU Monitoring

You have NVIDIA GPU passthrough on the docker and plex VMs but no GPU metrics
collection. The [NVIDIA DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter) or
[nvidia-gpu-exporter](https://github.com/utkuozdemir/nvidia_gpu_exporter) can expose:
- GPU utilization, memory usage, temperature
- Encoder/decoder utilization (valuable for Plex transcoding)
- Power consumption
- Clock speeds and throttling events

### 10. Synthetic Monitoring / Smoke Tests

Beyond simple HTTP 2xx checks, consider adding synthetic checks that exercise actual
functionality:
- DNS resolution for specific internal domains (not just "can resolve google.com")
- Plex API health (`/status/sessions`)
- AdGuard filtering test (query a known-blocked domain, verify NXDOMAIN)
- VPN tunnel connectivity check

### 11. Backup Verification Dashboard

You have PBS metrics via the exporter, and OpenObserve dashboards for PBS backup/storage,
but no consolidated view that answers "are all my backups current and healthy?" at a
glance. A single-pane dashboard showing last backup time per VM, verification status,
and storage consumption would be valuable.

### 12. Network Flow Monitoring

With your extensive VLAN setup, flow monitoring (NetFlow/sFlow/IPFIX) would provide
visibility into inter-VLAN traffic patterns, bandwidth hogs, and unusual traffic.
pfSense can export NetFlow data to a collector like
[ntopng](https://www.ntopng.org/) or [Elastiflow](https://www.elastiflow.com/).

---

## Suggested Implementation Priority

**Phase 1 -- Alerting (do this first):**
1. Add Alertmanager to docker-compose
2. Create Prometheus alert rules
3. Configure a notification channel (email/Slack/Discord)
4. Add TLS certificate expiry monitoring
5. Add an Alerts Overview dashboard in Grafana

**Phase 2 -- Visibility gaps:**
6. Deploy Uptime Kuma on the docker VM
7. Add Exportarr for Sonarr/Radarr/Lidarr/Readarr/Prowlarr
8. Add AdGuard Exporter
9. Add pfSense monitoring (SNMP or Telegraf package)
10. Add NVIDIA GPU exporter on plex + docker VMs

**Phase 3 -- Log maturity:**
11. Deploy Promtail + Loki (or enhance AxoSyslog parsing)
12. Collect Docker container logs (not just host syslog)
13. Create a Log Overview dashboard in Grafana
14. Add log-based alerting rules

**Phase 4 -- Polish:**
15. Deploy cAdvisor on Docker hosts
16. Add synthetic monitoring checks
17. Create a consolidated backup verification dashboard
18. Explore network flow monitoring
