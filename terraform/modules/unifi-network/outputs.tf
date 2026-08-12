output "l2_network_ids" {
  description = "UniFi network ids for the Terraform-created L2 VLANs (corosync, ceph)."
  value       = { for k, n in unifi_network.l2 : k => n.id }
}

output "switch_ids" {
  description = "UniFi device ids of the managed switches, keyed by bindings stanza."
  value       = { for k, d in unifi_device.switches : k => d.id }
}
