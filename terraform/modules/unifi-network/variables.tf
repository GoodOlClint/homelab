variable "vlans_file_path" {
  type        = string
  description = "Path to the canonical network-data/vlans.yaml (gitignored)."
}

variable "ports_file_path" {
  type        = string
  description = "Path to the gitignored switch port bindings (see network-data/unifi-ports.example.yaml)."
}
