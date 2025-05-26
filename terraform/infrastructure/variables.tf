variable "virtual_environment_endpoint" {
  type        = string
  description = "The endpoint for the Proxmox Virtual Environment API (example: https://host:port)"
}

variable "virtual_environment_password" {
  type        = string
  description = "The password for the Proxmox Virtual Environment API"
}

variable "virtual_environment_username" {
  type        = string
  description = "The username and realm for the Proxmox Virtual Environment API (example: root@pam)"
}

variable "virtual_environment_node" {
  type        = string
  description = "The name of the node in the proxmox datacenter to perform actions against"
}

variable "virtual_environment_storage" {
  type        = string
  description = "The name of the strorage in the proxmox datacenter"
}

variable "virtual_machine_timezone" {
  type        = string
  description = "The timezone to set for Virtual Machines via cloud-init"
  default     = "America/Chicago"
}

variable "virtual_machine_username" {
  type        = string
  description = "The username to add in Virtual Machines via cloud-init"
}

variable "nvidia_url" {
  description = "Url containing the Nvidia Grid driver to download into VMs"
  type        = string
}