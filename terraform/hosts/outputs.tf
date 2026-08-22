output "node_storage_ips" {
  description = "Per-node VLAN 20 (storage) host addresses — jumbo NFS/PBS."
  value       = { for k, v in var.nodes : k => v.storage_ip }
}

output "bonds" {
  description = "Per-node bond members, as applied."
  value       = { for k, b in proxmox_network_linux_bond.bond0 : k => b.slaves }
}

output "ci_api_token" {
  description = "ci@pve!ci token secret for the runners (ADR 0032) — GitHub repo secret, never Infisical"
  value       = proxmox_user_token.ci.value
  sensitive   = true
}
