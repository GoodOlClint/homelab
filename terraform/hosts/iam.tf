# CI sandbox identity (ADR 0032): the runners get a token that can create and
# destroy guests ONLY inside pool `ci`, upload to one datastore, and attach to
# the Ci VNET. No privilege on / or /nodes — PVE ACLs are the enforcement, the
# VMID range (5000–5999) is convention. Token value: `terraform output -raw ci_api_token`
# → GitHub repo secret PVE_API_TOKEN as `ci@pve!ci=<value>`.

resource "proxmox_virtual_environment_pool" "ci" {
  pool_id = "ci"
  comment = "CI sandbox — disposable guests built by the runners (ADR 0032); reaped by proxmox_host"
}

resource "proxmox_virtual_environment_user" "ci" {
  user_id = "ci@pve"
  comment = "GitHub Actions runners (ADR 0032)"
  enabled = true
}

resource "proxmox_user_token" "ci" {
  user_id               = proxmox_virtual_environment_user.ci.user_id
  token_name            = "ci"
  comment               = "Runner token — ACLs inherited from ci@pve"
  privileges_separation = false
}

resource "proxmox_acl" "ci_pool" {
  user_id   = proxmox_virtual_environment_user.ci.user_id
  path      = "/pool/${proxmox_virtual_environment_pool.ci.pool_id}"
  role_id   = "PVEVMAdmin"
  propagate = true
}

resource "proxmox_acl" "ci_pool_alloc" {
  user_id   = proxmox_virtual_environment_user.ci.user_id
  path      = "/pool/${proxmox_virtual_environment_pool.ci.pool_id}"
  role_id   = "PVEPoolAdmin"
  propagate = true
}

resource "proxmox_acl" "ci_storage" {
  for_each  = toset(var.ci_storages)
  user_id   = proxmox_virtual_environment_user.ci.user_id
  path      = "/storage/${each.value}"
  role_id   = each.value == var.ci_iso_storage ? "PVEDatastoreAdmin" : "PVEDatastoreUser" # ISO upload needs Datastore.AllocateTemplate
  propagate = true
}

resource "proxmox_acl" "ci_vnet" {
  user_id   = proxmox_virtual_environment_user.ci.user_id
  path      = "/sdn/zones/${var.ci_sdn_zone}/${var.ci_vnet}"
  role_id   = "PVESDNUser"
  propagate = true
}
