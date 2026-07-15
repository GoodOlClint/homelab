output "node_services_ips" {
  description = "Per-node VLAN 40 (services) host addresses — web UI / API."
  value       = { for k, v in var.nodes : k => v.services_ip }
}

output "node_storage_ips" {
  description = "Per-node VLAN 20 (storage) host addresses — jumbo NFS/PBS."
  value       = { for k, v in var.nodes : k => v.storage_ip }
}

output "bonds" {
  description = "Per-node bond members, as applied."
  value       = { for k, b in proxmox_network_linux_bond.bond0 : k => b.slaves }
}
