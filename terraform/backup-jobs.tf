# PVE backup jobs → PBS (B3). The PBS storage entry the jobs reference is
# registered by `make backup-finalize` (ansible/playbooks/backup-finalize.yml),
# which must run once before the first apply that populates backup_jobs.
#
# backup_jobs stays empty until the WP4 fleet manifest lands (same pattern as
# data_volumes). The cutover manifest MUST cover: the holder (900), infisical,
# proxmox-backup itself, and every Class-V guest per the rebuild matrix.
# proxmox-backup must NEVER be in a job whose storage is PBS itself: the
# guest-agent fs-freeze freezes the datastore the backup writes to and the
# backup connect times out (observed live 2026-08-11). Give it its own job to
# non-PBS storage (nas-nfs), or set freeze-fs-on-backup=0 on the guest.

resource "proxmox_backup_job" "jobs" {
  for_each = var.backup_jobs

  id       = each.key
  schedule = each.value.schedule
  storage  = each.value.storage
  # bpg declares all/vmid as conflicting attributes regardless of value —
  # emit exactly one of them.
  vmid = each.value.all ? null : each.value.vmids
  all  = each.value.all ? true : null

  mode          = each.value.mode
  enabled       = true
  protected     = each.value.protected
  prune_backups = each.value.prune_backups
  repeat_missed = true
  # ASCII only: bpg round-trips non-ASCII in notes-template as mojibake and
  # fails the apply with "inconsistent result" (hit live with an em-dash).
  notes_template   = "{{guestname}} - IaC backup job '${each.key}'"
  mailnotification = "failure"
}

# Tenant nightly jobs (ADR 0067): one per tenant, selecting the tenant's pool.
# The fleet root owns them because creating a job needs Sys.Modify on /.
# The `<tenant>-pbs` storage entry comes from `make backup-finalize` (see
# docs/make-targets.md). Absent tenants.yaml = no jobs.
locals {
  tenants_file = "${path.root}/../network-data/local/tenants.yaml"

  # Absent file = no jobs. A present file that does not decode, or has no `tenants`
  # map, fails the plan instead of planning deletion of every tenant job.
  tenant_bindings = yamldecode(fileexists(local.tenants_file) ? file(local.tenants_file) : "tenants: {}").tenants
}

resource "proxmox_backup_job" "tenants" {
  for_each = local.tenant_bindings

  id        = "${each.key}-nightly"
  schedule  = each.value.backup.schedule
  storage   = "${each.key}-pbs"
  pool      = each.value.pool
  mode      = "snapshot"
  enabled   = true
  protected = false
  prune_backups = {
    keep-all = "1"
  }
  repeat_missed    = true
  notes_template   = "{{guestname}} - IaC tenant backup job"
  mailnotification = "failure"
}
