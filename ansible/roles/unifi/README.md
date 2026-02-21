# UniFi Controller Ansible Role

Installs and configures the UniFi Network Controller with automated backup and restore capabilities.

## Features

- ✅ Installs UniFi Controller (Network Application)
- ✅ Configures MongoDB database
- ✅ Automated daily backups with retention
- ✅ Manual backup and restore scripts
- ✅ Firewall configuration (UFW)
- ✅ Customizable JVM memory settings
- ✅ Systemd service management

## Requirements

- Ubuntu 22.04 or 24.04
- Ansible 2.9+
- 4GB RAM minimum (8GB recommended for large deployments)

## Role Variables

See `defaults/main.yml` for all available variables. Key variables:

```yaml
# Memory settings (MB)
unifi_xms: 1024  # Initial heap
unifi_xmx: 2048  # Maximum heap

# Backup settings
unifi_backup_enabled: true
unifi_backup_dir: "/var/backups/unifi"
unifi_backup_retention_days: 30
unifi_backup_schedule: "0 2 * * *"  # Daily at 2 AM

# Network ports
unifi_https_port: 8443
unifi_http_port: 8080
```

## Usage

### Install UniFi Controller

```yaml
- hosts: unifi
  become: true
  roles:
    - unifi
```

### Manual Backup

SSH into the server and run:
```bash
sudo /usr/local/bin/backup-unifi
```

Backups are stored in `/var/backups/unifi/unifi-backup-YYYYMMDD_HHMMSS.unf`

### Restore from Backup

```bash
# List available backups
ls -lh /var/backups/unifi/

# Restore
sudo /usr/local/bin/restore-unifi /var/backups/unifi/unifi-backup-20260216_020000.unf
```

## First-Time Setup

After installation, access the UniFi Controller at:

```
https://<server-ip>:8443
```

Complete the setup wizard to:
1. Create admin account
2. Name your controller
3. Configure network settings
4. Adopt your UniFi devices

## Ports

The following ports are opened in the firewall:

- **8443/tcp** - Controller GUI/API (HTTPS)
- **8080/tcp** - Device communication
- **3478/udp** - STUN
- **10001/udp** - Device discovery

## Backup Details

**What's backed up:**
- MongoDB databases (unifi, unifi_stat)
- Site configurations
- System properties

**Backup schedule:**
- Automatic daily backups at 2 AM
- Old backups cleaned up after 30 days

**Manual operations:**
```bash
# Backup
sudo /usr/local/bin/backup-unifi

# Restore
sudo /usr/local/bin/restore-unifi <backup-file>

# List backups
ls -lh /var/backups/unifi/
```

## Troubleshooting

**Check service status:**
```bash
sudo systemctl status unifi
sudo systemctl status mongod
```

**View logs:**
```bash
sudo journalctl -u unifi -f
tail -f /var/log/unifi/server.log
```

**Restart services:**
```bash
sudo systemctl restart unifi
sudo systemctl restart mongod
```

## License

MIT
