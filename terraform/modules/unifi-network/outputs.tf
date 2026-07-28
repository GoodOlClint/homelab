output "l2_network_ids" {
  description = "UniFi network ids for the Terraform-created L2 VLANs (corosync, ceph)."
  value       = { for k, n in unifi_network.l2 : k => n.id }
}

output "switch_id" {
  description = "UniFi device id of the aggregation switch."
  value       = unifi_device.aggregation.id
}
