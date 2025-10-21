# Monitoring Users Role

This role provisions monitoring users and access for:
- **Proxmox VE**: Creates monitoring@pve user with PVEAuditor role
- **UniFi Controller**: Creates read-only admin user for metrics collection
- **Synology NAS**: Enables and configures SNMP service

## Requirements

### Ansible Collections
```bash
# No additional collections required - uses built-in modules
```

### System Access
- SSH access to Proxmox host (for pveum commands)
- Admin credentials for UniFi Controller API
- Admin credentials for Synology DSM (optional SSH access)
- `snmpwalk` utility on Ansible controller (for testing)

## Variables

### Required Variables (in group_vars/all.yml)
```yaml
# Proxmox configuration
proxmox_host: "172.16.100.10"
proxmox_user: "monitoring@pve"
proxmox_password: "{{ vault_proxmox_password }}"

# UniFi Controller configuration
unifi_controller_url: "https://172.16.100.1:8443"
unifi_admin_user: "admin"  # Existing admin for API calls
unifi_admin_password: "{{ vault_unifi_admin_password }}"
unifi_user: "monitoring"  # New monitoring user to create
unifi_password: "{{ vault_unifi_monitoring_password }}"
unifi_site: "default"

# Synology NAS configuration
synology_host: "172.16.20.10"
synology_admin_user: "admin"
synology_admin_password: "{{ vault_synology_admin_password }}"
synology_snmp_community: "{{ vault_synology_snmp_community }}"
```

### Optional Variables (in role defaults)
```yaml
# Proxmox
proxmox_monitoring_user: "monitoring@pve"
proxmox_monitoring_role: "PVEAuditor"
proxmox_monitoring_comment: "Monitoring user for Prometheus PVE Exporter"

# UniFi
unifi_monitoring_user: "monitoring"
unifi_monitoring_role: "readonly"  # Options: admin, readonly
unifi_monitoring_email: "monitoring@localhost"

# Synology
synology_snmp_enabled: true
synology_snmp_port: 161
```

## Usage

### Run the entire role
```bash
cd ansible
ansible-playbook playbooks/infrastructure.yml --tags monitoring-users
```

### Run specific tasks
```bash
# Only provision Proxmox user
ansible-playbook playbooks/infrastructure.yml --tags proxmox-user

# Only provision UniFi user
ansible-playbook playbooks/infrastructure.yml --tags unifi-user

# Only configure Synology SNMP
ansible-playbook playbooks/infrastructure.yml --tags synology-snmp
```

## Integration with Monitoring Stack

This role should be run **before** deploying the monitoring stack:

```bash
# Step 1: Provision monitoring users
ansible-playbook playbooks/infrastructure.yml --tags monitoring-users

# Step 2: Deploy monitoring stack (uses credentials from step 1)
ansible-playbook playbooks/infrastructure.yml --tags monitoring --limit openobserve
```

## Proxmox User Details

### Created User
- **Username**: `monitoring@pve`
- **Authentication Realm**: PVE (Proxmox VE)
- **Role**: `PVEAuditor` (read-only access)

### Permissions
The PVEAuditor role provides:
- Read-only access to all Proxmox resources
- View VM status and resource usage
- View storage and node information
- No modification capabilities

### Manual Verification
```bash
# SSH to Proxmox host
ssh root@172.16.100.10

# Check user exists
pveum user list | grep monitoring

# Check user permissions
pveum user permissions monitoring@pve

# Test authentication
pveum ticket monitoring@pve
```

## UniFi User Details

### Created User
- **Username**: `monitoring` (configurable)
- **Role**: `readonly` (read-only admin)
- **Access**: Full network visibility, no configuration changes

### API Access
The monitoring user can:
- View all network devices (APs, switches, gateways)
- View client connections and statistics
- View DPI and traffic data
- Access all sites in the controller

### Manual Verification
```bash
# Test login via API
curl -k -X POST https://172.16.100.1:8443/api/login \
  -H "Content-Type: application/json" \
  -d '{"username":"monitoring","password":"your-password"}'
```

## Synology SNMP Details

### SNMP Configuration
- **Version**: SNMPv1, SNMPv2c
- **Port**: 161 (UDP)
- **Community String**: Configured via `synology_snmp_community`
- **Access**: Read-only

### Available OIDs
The SNMP exporter monitors:
- **System Info**: 1.3.6.1.4.1.6574.1.* (model, serial, temp, status)
- **Disk Info**: 1.3.6.1.4.1.6574.2.* (disk model, temp, status)
- **RAID Info**: 1.3.6.1.4.1.6574.3.* (RAID status, free space)
- **Services**: 1.3.6.1.4.1.6574.6.* (service status)
- **UPS Info**: 1.3.6.1.4.1.6574.4.* (UPS status, battery)
- **Standard MIBs**: sysUpTime, ifTable, hrStorage, etc.

### Manual Verification
```bash
# Test SNMP connectivity
snmpwalk -v2c -c your-community 172.16.20.10 1.3.6.1.2.1.1.1

# Test Synology-specific OIDs
snmpwalk -v2c -c your-community 172.16.20.10 1.3.6.1.4.1.6574.1
```

## Troubleshooting

### Proxmox User Creation Fails
```bash
# Check if user already exists
ssh root@172.16.100.10 pveum user list | grep monitoring

# Manually create user
ssh root@172.16.100.10
pveum user add monitoring@pve --comment "Monitoring User"
pveum passwd monitoring@pve
pveum aclmod / -user monitoring@pve -role PVEAuditor
```

### UniFi API Connection Issues
- Ensure admin credentials are correct
- Check UniFi Controller is accessible at configured URL
- Verify SSL certificate issues (role uses `validate_certs: false`)
- Check firewall allows access to port 8443

### Synology SNMP Not Working
1. **Manual Web UI Method** (recommended):
   - Login to DSM: https://172.16.20.10:5001
   - Control Panel → Terminal & SNMP → SNMP tab
   - Enable SNMP service (SNMPv1, SNMPv2c)
   - Set community string

2. **SSH Method** (if enabled):
   ```bash
   ssh admin@172.16.20.10
   sudo synoservicecfg --enable SNMP
   sudo synoservicecfg --start SNMP
   sudo synoservicecfg --status SNMP
   ```

3. **Firewall Check**:
   - Ensure UDP port 161 is open
   - Check Synology firewall rules
   - Test with `snmpwalk` from monitoring host

## Security Considerations

1. **Credential Storage**
   - All passwords stored in Ansible Vault
   - Use strong passwords for monitoring accounts
   - Regularly rotate credentials

2. **Access Levels**
   - Proxmox: Read-only (PVEAuditor)
   - UniFi: Read-only admin
   - Synology: SNMP read-only community

3. **Network Security**
   - Consider restricting SNMP access by source IP
   - Use firewall rules to limit monitoring access
   - Monitor for unauthorized access attempts

## Dependencies

This role has no dependencies on other Ansible roles.

## License

MIT

## Author

Homelab Infrastructure Team
