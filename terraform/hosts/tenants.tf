# Tenant enclaves (ADR 0067): one pool, user, privsep-off token and ACL set per entry
# in network-data/local/tenants.yaml (schema: network-data/tenants.example.yaml).
# Absent file = no tenants. PVE ACLs are the enforcement; VMID range is convention.
# Token value: `terraform output -json tenant_api_tokens` — handed to the tenant by hand.

locals {
  tenants_file = "${path.module}/../../network-data/local/tenants.yaml"
  vlans_file   = "${path.module}/../../network-data/vlans.yaml"

  # Absent file = no tenants. A present file that does not decode, or has no `tenants`
  # map, fails the plan (an empty fallback would plan deletion of every tenant resource).
  tenants_doc = yamldecode(fileexists(local.tenants_file) ? file(local.tenants_file) : "tenants: {}")
  tenants     = local.tenants_doc.tenants

  tenant_vnets = {
    for t, v in local.tenants : t => {
      sdn_zone = yamldecode(file(local.vlans_file)).vlans[v.vlan].sdn_zone
      bridge   = yamldecode(file(local.vlans_file)).vlans[v.vlan].bridge
    }
  }

  tenant_storage_acls = merge([
    for t, v in local.tenants : {
      for s in distinct(concat(v.storages, [for l in try(v.iscsi_luns, []) : l.storage_id], [v.image_store.id])) :
      "${t}/${s}" => {
        tenant  = t
        storage = s
        role    = s == v.image_store.id ? "PVEDatastoreAdmin" : "PVEDatastoreUser" # image upload needs Datastore.AllocateTemplate
      }
    }
  ]...)

  tenant_mapping_acls = merge([
    for t, v in local.tenants : {
      for m in try(v.pci_mappings, []) : "${t}/${m}" => { tenant = t, mapping = m }
    }
  ]...)
}

resource "proxmox_virtual_environment_pool" "tenant" {
  for_each = local.tenants

  pool_id = each.value.pool
  comment = "Tenant enclave (ADR 0067)"
}

resource "proxmox_virtual_environment_user" "tenant" {
  for_each = local.tenants

  user_id = "${each.value.pool}@pve"
  comment = "Tenant enclave (ADR 0067)"
  enabled = true
}

resource "proxmox_user_token" "tenant" {
  for_each = local.tenants

  user_id               = proxmox_virtual_environment_user.tenant[each.key].user_id
  token_name            = each.value.pool
  comment               = "Tenant token — ACLs inherited from the user"
  privileges_separation = false
}

resource "proxmox_acl" "tenant_pool" {
  for_each = local.tenants

  user_id   = proxmox_virtual_environment_user.tenant[each.key].user_id
  path      = "/pool/${proxmox_virtual_environment_pool.tenant[each.key].pool_id}"
  role_id   = "PVEVMAdmin"
  propagate = true
}

resource "proxmox_acl" "tenant_pool_alloc" {
  for_each = local.tenants

  user_id   = proxmox_virtual_environment_user.tenant[each.key].user_id
  path      = "/pool/${proxmox_virtual_environment_pool.tenant[each.key].pool_id}"
  role_id   = "PVEPoolAdmin"
  propagate = true
}

resource "proxmox_acl" "tenant_storage" {
  for_each = local.tenant_storage_acls

  user_id   = proxmox_virtual_environment_user.tenant[each.value.tenant].user_id
  path      = "/storage/${each.value.storage}"
  role_id   = each.value.role
  propagate = true
}

resource "proxmox_acl" "tenant_vnet" {
  for_each = local.tenants

  user_id   = proxmox_virtual_environment_user.tenant[each.key].user_id
  path      = "/sdn/zones/${local.tenant_vnets[each.key].sdn_zone}/${local.tenant_vnets[each.key].bridge}"
  role_id   = "PVESDNUser"
  propagate = true
}

resource "proxmox_virtual_environment_role" "tenant_mapping" {
  count = length(local.tenant_mapping_acls) > 0 ? 1 : 0

  role_id    = "TenantMapping"
  privileges = ["Mapping.Use", "Mapping.Audit"]
}

resource "proxmox_acl" "tenant_mapping" {
  for_each = local.tenant_mapping_acls

  user_id   = proxmox_virtual_environment_user.tenant[each.value.tenant].user_id
  path      = "/mapping/pci/${each.value.mapping}"
  role_id   = proxmox_virtual_environment_role.tenant_mapping[0].role_id
  propagate = true
}
