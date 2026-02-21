packer {
  required_version = ">= 1.10.0"
  required_plugins {
    proxmox = {
      version = ">= 1.1.8"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

source "proxmox-iso" "ubuntu-24-04" {
  # Proxmox Connection Settings
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  node                     = var.proxmox_node
  insecure_skip_tls_verify = var.insecure_skip_tls_verify

  # VM Template Settings
  template_name        = "ubuntu-24.04-base-${formatdate("YYYYMMDD-hhmm", timestamp())}"
  template_description = "Ubuntu 24.04 LTS base template - Built with Packer on ${formatdate("YYYY-MM-DD", timestamp())}"

  # ISO Settings
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  iso_storage_pool = var.iso_storage_pool
  unmount_iso      = true

  # Hardware Configuration
  cores    = 2
  memory   = 2048
  sockets  = 1
  cpu_type = "x86-64-v3"

  # Disk Configuration
  scsi_controller = "virtio-scsi-single"
  disks {
    disk_size         = "10G"
    storage_pool      = var.storage_pool
    type              = "scsi"
    format            = "raw"
    io_thread         = true
    discard           = true
  }

  # Network Configuration
  network_adapters {
    model  = "virtio"
    bridge = var.network_bridge
  }

  # Cloud-init drive (disabled - we don't use cloud-init)
  cloud_init              = false
  cloud_init_storage_pool = var.storage_pool

  # Boot Configuration for Ubuntu 24.04 Autoinstall
  boot_wait = "5s"
  boot_command = [
    "<esc><wait>",
    "e<wait>",
    "<down><down><down><end>",
    "<bs><bs><bs><bs><wait>",
    "autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ---<wait>",
    "<f10><wait>"
  ]

  # HTTP directory for autoinstall files
  http_directory = "http"

  # SSH Configuration (temporary for provisioning)
  ssh_username         = "packer"
  ssh_password         = var.ssh_password
  ssh_timeout          = "20m"
  ssh_handshake_attempts = 50

  # QEMU Guest Agent (installed by provisioning scripts)
  qemu_agent = true
}

build {
  sources = ["source.proxmox-iso.ubuntu-24-04"]

  # Run provisioning scripts
  provisioner "shell" {
    execute_command = "echo '${var.ssh_password}' | sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    scripts = [
      "scripts/01-setup.sh",
      "scripts/02-network-default.sh",
      "scripts/03-hardening.sh",
      "scripts/04-remove-cloud-init.sh",
      "scripts/05-cleanup.sh"
    ]
    expect_disconnect = true
  }

  # Inject bootstrap SSH key for Ansible connectivity
  provisioner "file" {
    source      = "bootstrap_ssh_key.pub"
    destination = "/tmp/bootstrap_key.pub"
  }

  provisioner "shell" {
    execute_command = "echo '${var.ssh_password}' | sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "cat /tmp/bootstrap_key.pub >> /home/ansible/.ssh/authorized_keys",
      "chmod 600 /home/ansible/.ssh/authorized_keys",
      "chown ansible:ansible /home/ansible/.ssh/authorized_keys",
      "rm /tmp/bootstrap_key.pub",
      "echo 'Bootstrap SSH key installed for ansible user'"
    ]
  }
}
