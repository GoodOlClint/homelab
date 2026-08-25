# PDM remotes — hand-managed, no fingerprint pins

PDM (VM 220, `pdm` role) installs the package and its ACME cert; the remotes are created by the PDM UI wizard and live in `/etc/proxmox-datacenter-manager/remotes.cfg` (tokens in `remotes.shadow`). Nothing in Ansible or Terraform owns them, by decision: the wizard mints the PVE token from `root@pam` itself, and a role-written task on a wizard-owned file would be the one-shot migration logic the greenfield rule bans.

## The pin habit

The PVE wizard writes `<node fqdn>,fingerprint=<sha256>` for every node it scans. A pinned remote verifies the node's cert by fingerprint, not through `Homelab Root CA`, so the next certbot renewal on that node (one-year `fleet-hosts` leaves, renewed at ~2/3 lifetime — ADR 0041) breaks the remote silently. PDM trusts the root through `ca_trust` since P7, so the pins buy nothing. ADR 0041 forbids them on any PBS consumer; the PDM remotes are the same class one hop over.

## Recipe — after every wizard-added PVE remote

```sh
proxmox-datacenter-manager-admin remote list                       # find the pinned lines
proxmox-datacenter-manager-admin remote update <id> --nodes <fqdn> [--nodes <fqdn> ...]   # bare FQDNs, one --nodes per node, no fingerprint=
proxmox-datacenter-manager-admin remote version <id>               # connects through the root; a TLS failure shows here
grep -c fingerprint /etc/proxmox-datacenter-manager/remotes.cfg    # 0
```

`remote update` rewrites only the fields given — the token in `remotes.shadow` and the authid survive. The PBS remote wizard writes no pin (added by hand 2026-08-25, none present).

## Proof (2026-08-25, P10 item 1)

`homelab` (ms-01a/ms-01b/msi) and `worklab` unpinned. `certbot renew --force-renewal --no-random-sleep-on-renew --cert-name msi.<service domain>` on msi rolled the served fingerprint from `sha256:993348f0c1ebc60deb76bc4e40bf3b0b9677e28872e89483d41b9e8ec7fe9794` (the wizard's pin) to `sha256:c9fe52845e637f3774b9d7974caab18c5f5cda6ff19b8b62e5f584a5a038a765`; with msi put first in the remote's node list (PDM dials the first reachable node) the remote enumerated all 35 cluster guests and msi's node status, then the order was restored. msi held no guests that day (evacuated for the RMA), so a per-node msi guest list is empty by placement.

Reading guests through the API from the VM: `POST /api2/json/access/ticket` (root@pam, Infisical `/control/pdm_root_password`) returns the ticket as an HttpOnly cookie (`ticket-info` in the body, no `ticket` key) — use a curl cookie jar — then `GET /api2/json/pve/remotes/<id>/resources`.
