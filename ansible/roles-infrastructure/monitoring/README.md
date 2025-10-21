# Homelab Monitoring Infrastructure

## Overview

This monitoring stack provides comprehensive visibility into your homelab infrastructure using:

- **OpenObserve**: Centralized metrics and logs storage with Prometheus-compatible API
- **Grafana**: Visualization and dashboards
- **Prometheus**: Metrics collection and alerting
- **Blackbox Exporter**: Endpoint monitoring (HTTP, DNS, ICMP)
- **Speedtest Exporter**: Network bandwidth monitoring
- **Telegraf**: Agent deployed on all VMs for system metrics collection

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        OpenObserve VM                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐         │
│  │  OpenObserve │  │   Grafana    │  │  Prometheus  │         │
│  │   :5080      │  │    :3000     │  │    :9090     │         │
│  └──────┬───────┘  └──────────────┘  └──────┬───────┘         │
│         │                                     │                 │
│         │          ┌──────────────┐          │                 │
│         └──────────┤  Blackbox    ├──────────┘                 │
│                    │  Exporter    │                             │
│                    │    :9115     │                             │
│                    └──────────────┘                             │
│                                                                  │
│         ┌──────────────┐  ┌──────────────┐                    │
│         │  Speedtest   │  │     Node     │                    │
│         │  Exporter    │  │   Exporter   │                    │
│         │    :9798     │  │    :9100     │                    │
│         └──────────────┘  └──────────────┘                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ Metrics Push (Telegraf)
                              │
    ┌─────────────────────────┴─────────────────────────┐
    │                                                     │
┌───┴────┐  ┌──────────┐  ┌──────┐  ┌────────┐  ┌──────┐
│  DNS   │  │ AdGuard  │  │ Plex │  │ Docker │  │ ...  │
│ :9273  │  │  :9273   │  │:9273 │  │ :9273  │  │:9273 │
└────────┘  └──────────┘  └──────┘  └────────┘  └──────┘
  Telegraf    Telegraf    Telegraf   Telegraf   Telegraf
```

## Services

### OpenObserve (Port 5080)
- Centralized metrics and logs storage
- Prometheus-compatible remote write endpoint
- Web UI for querying logs and metrics
- Access: `http://openobserve.core.goodolclint.internal:5080`

### Grafana (Port 3000)
- Visualization and dashboards
- Pre-configured with OpenObserve datasource
- Access: `http://openobserve.core.goodolclint.internal:3000`
- Default credentials: `admin / Gr4f@n@M0n1t0r`

### Prometheus (Port 9090)
- Metrics collection from exporters
- Remote write to OpenObserve for long-term storage
- Access: `http://openobserve.core.goodolclint.internal:9090`

### Blackbox Exporter (Port 9115)
- HTTP/HTTPS endpoint monitoring
- DNS resolution monitoring across all zones
- ICMP ping monitoring to key infrastructure
- TCP port checks

### Speedtest Exporter (Port 9798)
- Automated network speed tests (runs every 30 minutes)
- Upload/Download bandwidth metrics
- Ping and jitter measurements

### Node Exporter (Port 9100)
- System metrics for the OpenObserve host
- CPU, memory, disk, network statistics

## Metrics Collection

### Telegraf Agents
Deployed on all VMs to collect:
- **System Metrics**: CPU, memory, disk, network
- **Docker Metrics**: Container stats (on Docker hosts)
- **DNS Metrics**: Query performance (on DNS host)
- **NFS Metrics**: Mount statistics (on Plex/Docker hosts)
- **Process Metrics**: Running processes and states
- **Network Metrics**: Interface statistics, netstat

All metrics are pushed to OpenObserve via Prometheus remote write.

### Blackbox Monitoring
Automatically monitors:

#### DNS Resolution
- All DNS zones (core, storage, vpn, work, iot, sonos, guest)
- External DNS (8.8.8.8, 1.1.1.1)

#### HTTP Endpoints
- AdGuard web UI
- OpenObserve health endpoint
- Grafana API health
- Plex web interface

#### ICMP Ping
- All infrastructure VMs
- External connectivity (Google, Cloudflare)

## Accessing the Stack

1. **Grafana Dashboard**: http://openobserve.core.goodolclint.internal:3000
   - Username: `admin`
   - Password: `Gr4f@n@M0n1t0r`

2. **OpenObserve**: http://openobserve.core.goodolclint.internal:5080
   - Email: `goodolclint@gmail.com`
   - Password: `kR15714n`

3. **Prometheus**: http://openobserve.core.goodolclint.internal:9090

## Deployment

Deploy the monitoring stack:

```bash
# Apply infrastructure changes
make terraform-infra

# Update inventory
make inventory

# Deploy monitoring
make ansible-infra
```

## Monitoring Capabilities

### What's Monitored

1. **System Health**
   - CPU usage across all VMs
   - Memory utilization
   - Disk space and I/O
   - Network bandwidth

2. **Network Performance**
   - Internet upload/download speeds
   - Ping latency to external sites
   - Inter-VM connectivity

3. **DNS Resolution**
   - Query performance per zone
   - Resolution success rates
   - DNS server availability

4. **Service Availability**
   - HTTP endpoint health checks
   - Container status (Docker hosts)
   - Process monitoring

5. **Storage**
   - NFS mount performance
   - Disk usage trends
   - I/O wait times

### Alerting (Future Enhancement)

Prometheus supports alerting rules that can be configured to:
- Alert on high CPU/memory usage
- Notify when services are down
- Warn about low disk space
- Detect network issues

## Maintenance

### Viewing Logs
All container logs:
```bash
ssh openobserve
cd /opt/monitoring
docker-compose logs -f
```

### Restarting Services
```bash
ssh openobserve
cd /opt/monitoring
docker-compose restart
```

### Updating the Stack
```bash
ssh openobserve
cd /opt/monitoring
docker-compose pull
docker-compose up -d
```

## Troubleshooting

### Telegraf Not Sending Metrics
Check Telegraf status on any VM:
```bash
systemctl status telegraf
journalctl -u telegraf -f
```

### OpenObserve Not Receiving Data
Check OpenObserve logs:
```bash
docker logs openobserve
```

### Grafana Cannot Connect to OpenObserve
1. Verify OpenObserve is running: `docker ps | grep openobserve`
2. Check network connectivity: `docker exec grafana ping openobserve`
3. Verify datasource configuration in Grafana UI

## Performance Tuning

### Adjust Scrape Intervals
Edit `/opt/monitoring/prometheus/prometheus.yml`:
```yaml
global:
  scrape_interval: 30s  # Increase for less load
```

### Reduce Speedtest Frequency
Edit `/opt/monitoring/prometheus/prometheus.yml`:
```yaml
- job_name: 'speedtest'
  scrape_interval: 60m  # Change from 30m to 60m
```

### OpenObserve Retention
Edit `/opt/monitoring/openobserve/.env`:
```
ZO_COMPACT_INTERVAL=7200  # Compact data every 2 hours
```

## Security Considerations

- Grafana admin password should be changed from default
- OpenObserve credentials should be stored in Ansible Vault
- Consider implementing network policies to restrict access
- Enable HTTPS for production deployments

## Future Enhancements

- [ ] Configure Prometheus alerting rules
- [ ] Add AlertManager for notification routing
- [ ] Create custom Grafana dashboards
- [ ] Implement log shipping from all VMs
- [ ] Add SNMP monitoring for network equipment
- [ ] Set up automated backups of Grafana dashboards
- [ ] Implement metrics retention policies

## New Infrastructure Monitoring

### Proxmox VE Exporter
- **Dashboard ID**: 10347 (Proxmox via Prometheus PVE Exporter)
- Metrics: Host resources, VM/LXC status, storage pools, cluster status
- Access: http://openobserve-ip:9221/metrics

### Synology NAS (via SNMP Exporter)
- **Dashboard ID**: 14284 (Synology NAS Details)
- Metrics: Disk health, RAID status, volumes, system resources
- SNMP Exporter: http://openobserve-ip:9116/metrics

### UniFi Network (via UniFi Poller)
- **Dashboard ID**: 11315 (Client Insights) & 11311 (Network Sites)
- Metrics: Client counts, bandwidth, AP performance, switch ports
- Access: http://openobserve-ip:9130/metrics

## Importing Dashboards

1. Login to Grafana (http://openobserve-ip:3000)
2. Go to Dashboards → New → Import
3. Enter Dashboard ID from grafana.com
4. Select "Prometheus" as datasource
5. Click Import

## Required Variables

Add to `group_vars/all.yml`:
```yaml
# Proxmox Monitoring
proxmox_user: "monitoring@pve"
proxmox_password: "your-password"
proxmox_host: "172.16.100.10"

# Synology NAS
synology_host: "172.16.20.10"
synology_snmp_community: "public"

# UniFi Controller  
unifi_controller_url: "https://172.16.100.1:8443"
unifi_user: "monitoring"
unifi_password: "your-password"
```

## Setup Steps

1. Create Proxmox monitoring user:
   ```bash
   pveum user add monitoring@pve
   pveum passwd monitoring@pve
   pveum aclmod / -user monitoring@pve -role PVEAuditor
   ```

2. Enable SNMP on Synology:
   - Control Panel → Terminal & SNMP → SNMP tab
   - Enable SNMPv1, SNMPv2c service
   - Set community name (use in vars)

3. Create UniFi monitoring user:
   - Settings → Admins → Add Admin
   - Role: Read Only
   - Use credentials in vars

