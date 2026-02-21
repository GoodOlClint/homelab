# Input variables for the network module

variable "vlans_file_path" {
  description = "Absolute path to the canonical vlans.yaml file"
  type        = string
}

variable "manage_sdn" {
  description = "Whether to create/manage SDN zones and VNETs. Set to true for the infrastructure project (owns network resources), false for services (read-only)."
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Proxmox node name for SDN zone deployment (e.g., 'pve'). Only used when manage_sdn = true."
  type        = string
  default     = "pve"
}
