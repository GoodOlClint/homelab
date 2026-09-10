# Network Module

Reads the canonical `network-data/vlans.yaml` and provides VLAN configuration to the rest of the Terraform codebase. Optionally manages Proxmox SDN zones and VNETs.

## Usage

```hcl
module "network" {
  source          = "../modules/network"
  vlans_file_path = "${path.root}/../../network-data/vlans.yaml"
  proxmox_node    = "pve"
}

module "vms" {
  source = "../modules/proxmox-vm"
  vlans  = module.network.vlans
  # ...
}
```

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `vlans_file_path` | Path to `vlans.yaml` | (required) |
| `proxmox_node` | Proxmox node for SDN deployment | `"pve"` |

## Outputs

| Name | Description |
|------|-------------|
| `vlans` | VLAN map for the proxmox-vm module (excludes WireGuard) |
| `all_vlans` | Complete VLAN map including WireGuard |
| `dns_servers` | DNS server list for cloud-init |
| `management_vlan_key` | Management VLAN key (e.g., `"vlan10"`) |
| `management_subnet` | Management VLAN IPv4 CIDR |
| `network_data` | Raw parsed YAML for full metadata access |

## Forward Compatibility

Placeholder files show where future integrations would plug in:
- `pfsense.tf.placeholder` — pfSense REST API provisioning (VLAN interfaces, DHCP, firewall)
- `unifi.tf.placeholder` — UniFi network/SSID provisioning
