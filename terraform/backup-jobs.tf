# B3 backup control plane, step 2 (audit 2026-08-10): PVE backup jobs → PBS.
# The audit found backup=true flags with NO job scheduling anything anywhere —
# the data-volume holder (VMID 900, owner of ALL fleet durable state) was in no
# backup. Jobs are defined here; the PBS storage entry they reference is
# registered by `make backup-finalize` (ansible/playbooks/backup-finalize.yml),
# which must run once before the first apply that populates backup_jobs.
#
# backup_jobs stays empty until the WP4 fleet manifest lands (same pattern as
# data_volumes). The cutover manifest MUST cover: the holder (900), infisical,
# proxmox-backup itself, and every Class-V guest per the rebuild matrix.

resource "proxmox_backup_job" "jobs" {
  for_each = var.backup_jobs

  id       = each.key
  schedule = each.value.schedule
  storage  = each.value.storage
  # bpg declares all/vmid as conflicting attributes regardless of value —
  # emit exactly one of them (Codex P1).
  vmid = each.value.all ? null : each.value.vmids
  all  = each.value.all ? true : null

  mode             = each.value.mode
  enabled          = true
  protected        = each.value.protected
  prune_backups    = each.value.prune_backups
  repeat_missed    = true
  notes_template   = "{{guestname}} — IaC backup job '${each.key}'"
  mailnotification = "failure"
}
