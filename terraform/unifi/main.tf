# WP5 — the aggregation switch + migration-touched UniFi config.
# Run via `make unifi-plan` / `make unifi-apply` AFTER the switch is adopted
# and network-data/local/unifi-ports.yaml is filled (see the module README).
module "unifi_network" {
  source = "../modules/unifi-network"

  vlans_file_path = "${path.root}/../../network-data/vlans.yaml"
  ports_file_path = "${path.root}/../../network-data/local/unifi-ports.yaml"
}

output "l2_network_ids" {
  value = module.unifi_network.l2_network_ids
}
