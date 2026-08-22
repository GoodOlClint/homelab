# pfSense config backup

pfSense is hand-managed ([ADR 0005](decisions/0005-pfsense-stays-hand-managed-unifi-gets-a-terraform-module.md)), so its `config.xml` is the only record of firewall rules, DHCP scopes, WireGuard peers, NUT, and DDNS settings. Until 2026-08-22 the DR story was "the running box" — this page makes it a copy.

## Primary: AutoConfigBackup (built in)

The Netgate 6100 runs pfSense Plus, which ships **Services → Auto Config Backup** — every config change is encrypted with a passphrase you choose and pushed to Netgate's ACB store. It is free, needs no NAS path or cron, and restores from the pfSense installer or the *Restore* tab.

Enable once:

1. **Services → Auto Config Backup → Settings**: *Enable automatic configuration backups*, set the **encryption password** (store it in Infisical `/pfsense` as `pfsense_acb_passphrase` — without it the backups are unreadable), leave *Hint* empty, *Schedule* = on every change.
2. Click *Backup now* and confirm the entry appears under the *Restore* tab with today's date.

The passphrase is the asset. A rebuilt Netgate can pull the latest copy with nothing but the device serial + passphrase.

## Secondary: local copy on the NAS

ACB is vendor-hosted. For an on-prem copy, a daily cron on pfSense copies `config.xml` to the NAS backup share over the `ansible` account already in `inventory/pfsense.yaml` (SSH key present):

- **Services → Cron** (package `Cron`), add: `minute 15, hour 3`, user `root`, command:

  `/usr/bin/scp -q /conf/config.xml ansible@<nas>:/volume1/backups/pfsense/config-$(date +\%F).xml`

`<nas>` is `proxmox_backup_nfs_src`'s host in `group_vars/all.yml`; create `/volume1/backups/pfsense` on the Synology first and let the share's own retention handle age-out.

## Verify

- ACB: *Restore* tab shows a backup dated after the last config change.
- NAS: `ls /volume1/backups/pfsense/` shows a file for yesterday.

A restore test belongs with the next pfSense upgrade (which is also when the NUT package is known to vanish — see [pfsense-nut.md](pfsense-nut.md)).
