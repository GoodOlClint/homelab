variable "vlans_file_path" {
  description = "Absolute path to the canonical vlans.yaml file"
  type        = string
}

variable "manage_sdn" {
  description = "Whether to create/manage SDN zones and VNETs. Set to true for the infrastructure project (owns network resources), false for services (read-only)."
  type        = bool
  default     = true
}

variable "proxmox_nodes" {
  description = "All cluster node names for SDN zone deployment (WP3: zones span every node). Only used when manage_sdn = true."
  type        = list(string)
  default     = ["pve"]
}
