# UptimeRobot — External Monitoring Setup

Free-tier external monitoring to detect when the entire home network or VPS is down (complements internal Uptime Kuma).

## Account Setup

1. Create a free account at [uptimerobot.com](https://uptimerobot.com)
2. Install the UptimeRobot mobile app for push notifications

## Monitors

### 1. ICMP Ping — VPS Public IP

- **Type:** Ping
- **Target:** VPS reserved IP (from `terraform output vps_public_ip`)
- **Interval:** 5 minutes
- **Alert contacts:** Mobile push

### 2. HTTP Check — Plex via VPS

- **Type:** HTTP
- **URL:** `http://<VPS_IP>:32400/identity`
- **Interval:** 5 minutes
- **Alert contacts:** Mobile push

Returns XML if the full path works: VPS → WireGuard → pfSense → Plex.

### 3. Heartbeat — Home Network

- **Type:** Heartbeat
- **Interval:** 60 seconds (expects a ping every 60s)
- **Alert contacts:** Mobile push

After creating the heartbeat monitor, copy the heartbeat URL and add it to `secrets.sops.yml` as `uptimerobot_heartbeat_url`. The monitoring VM will curl this URL every minute via cron. If UptimeRobot stops receiving pings, the home network is down.

Cron job (deployed automatically by the monitoring role):
```
* * * * * curl -fsS --max-time 10 https://heartbeat.uptimerobot.com/XXXXX > /dev/null 2>&1
```
