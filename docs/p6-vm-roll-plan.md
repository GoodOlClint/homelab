# P6 — the deliberate VM roll (change plan)

- **Status:** LANDED 2026-08-25 (approved the same day; as-built deviations at the end)
- **Decides:** nothing new. ADR 0016 (pinned + rolled images), ADR 0021 (the apt-proxy probe rides the next roll), ADR 0025 (PBS on Debian 13), ADR 0039 (the PBS dump is the vault's DR path), ADR 0040 (`domain_suffix` retires with the next VM roll) already decide it; this plan records the interview outcomes as consequence notes on those ADRs.
- **Tracker:** [ms01-cluster-iac-plan.md](ms01-cluster-iac-plan.md) P6 row. Kickoff `homelab-p6-vm-roll-20260826`.

## Existing state (mapped 2026-08-25)

- Six VMs carry cloud-init user-data: `apt-cache` 216, `pxe` 217, `pdm` 220, `unifi` 200, `proxmox-backup` 201, `infisical` 205. Every other guest is an LXC (no snippet) or a Talos node (`terraform/talos.tf`, its own image). All six answer `hostname -f` = `<name>.<old .internal suffix>` and none has `Proxy-Auto-Detect` in `apt-config dump`.
- `terraform/modules/proxmox-vm/templates/user-data.yaml.tmpl` renders `fqdn: <name>.${domain_suffix}`; a changed snippet shows every VM as `must be replaced` (ADR 0016). `domain_suffix` lives in: `vlans.yaml` (gitignored) + `vlans.example.yaml`, `modules/network/outputs.tf`, `main.tf`, `modules/proxmox-vm/variables.tf` + `virtual_machines.tf` + `tests/data_volume_slots.tftest.hcl`, `scripts/security_guardrails.sh` (sed line), `vars.auto.tfvars.example` (a comment), CLAUDE.md. Nothing in Ansible reads it.
- `ansible/roles/apt_proxy` (ADR 0021 client half) ships `/usr/local/bin/apt-proxy-detect` + `/etc/apt/apt.conf.d/01proxy` only via `make apt-proxy` (`playbooks/apt-proxy.yml`); `site.yml` never runs it, so a rebuilt VM has no probe until the operator remembers. `apt_proxy_host` = `hostvars['apt-cache'].ansible_host` = apt-cache's only leg (vlan30, `ip_offset` 16) — Terraform can derive the identical address from `local.vm_configurations` + `module.network.vlans`, so cloud-init and Ansible converge on the same file content once the template drops its `ansible_managed` header.
- Image pins: `cloud_image` = resolute **20260731**, which is still the newest serial on cloud-images.ubuntu.com (checked 2026-08-25) — nothing to bump. `cloud_images.debian13` = trixie 20260810-2566; upstream has **20260819-2575** (sha512 fetched). `pxe`/`pdm`/`proxmox-backup` are the Debian guests.
- Baseline `make plan`: 0 to add, **3 to change**, 0 to destroy — `cloudflare_dns_record.{vps,plex,jellyfin}_ipv6` content drift (the VPS's `v6_main_ip` moved within the same /64 since 2026-08-22; Terraform wants to correct the public AAAA records to the instance's current address). No guest drift.
- Infisical DR: `host/infisical` in PBS ns `databases` has a 2026-08-25T06:30Z snapshot (`infisical-backup.pxar` = `pg_dump -Fc` + globals + `encryption_material_*.env`); the cron is healthy. `make infisical-backup` (`secrets.sops.yml`) is 4 days old and its `FOLDERS` list lacks `authentik`, `authentik-ext`, `jellyfin` (P5c/P5d folders) — a silent gap in the SOPS DR artifact. `make rebuild-infisical` today re-bootstraps a **fresh** vault (new org/project/identities written into `bootstrap.sops.yml`, SOPS seed) — that path discards the ADR 0039 root CA. Its `qm set --protection 0` step is also broken since cutover (`qm list | awk /infisical/` matches 105 and 205, and `proxmox_host` is the VIP so `qm list` is the wrong node). worklab hosts a running resolute scratch VM `wl-resolute` (5301, `.30.93`, Docker 29 + `proxmox-backup-client`) — the rehearsal host.
- PBS rebuild rotates `pbs_backup_token` + `pbs_fingerprint` in `/shared` (the role regenerates the token); the Infisical agent re-renders every VM's `pbs.env`, the cluster CronJobs (plex-services, authentik ×2) reload through their `InfisicalSecret`s; only the baked `pbs_client` fallback on each guest needs an Ansible pass — `make ansible-all` (a DoD item anyway) covers it. `pbs-self` vanishes with VMID 201 (PVE drops a job with its last member) → `make backup-jobs` after `make backup-finalize`.
- UniFi keeps **no** backup file on the VM (0 `.unf`; the autobackup dir in the uosserver Podman volume is empty); the 2026-08-21 rebuild was restored from a downloaded `.unifi` file through the setup wizard. PDM keeps only remotes config (re-added via the UI wizard, [rebuild-as-routine-design.md](rebuild-as-routine-design.md)) plus its authentik realm (hand step, [authentik-setup.md](authentik-setup.md)). pxe/apt-cache are fully derived; PBS reuses the LUN datastore (`--reuse-datastore`, ADR 0025).
- Lancache: VM 110 is **not** on the cluster (`pvesh get /cluster/resources` lists 100–117 minus 110/112); what remains is `ansible/roles/lancache/`, the `services.yml` play + tag, the `docker-config.yml` block + vars_file, the `update-all.yml` host + dir, README rows, CLAUDE.md/AGENTS.md prose. The ADR 0021 filename contains the word and stays (renaming an ADR breaks every link).
- netconsole: `axosyslog.conf` `options{}` has `use_dns(no)`; `s_netconsole` is `flags(no-parse)` and `d_openobserve_netconsole` stamps `host=${SOURCEIP}`. Every node address has a PTR in BIND since P5a (`dig -x` answers `ms-01a/ms-01b/msi/worklab.<service domain>` from the workstation).

## Interview outcomes (operator, 2026-08-25)

1. **`domain_suffix` is deleted everywhere.** The VM module variable becomes `service_domain`, fed from `module.network.service_domain`; the key leaves `vlans.yaml`, `vlans.example.yaml`, the network output, the guardrail sed line (which keeps `service_domain|media_domain`, so the service domain stays blocked) and the tftest.
2. **Pins: resolute stays 20260731 (already newest); `debian13` bumps to 20260819-2575** — the Ubuntu guests roll on the snippet change alone, the Debian guests get a fresh image with it.
3. **Infisical rolls by restoring the PBS dump**, not by re-bootstrapping. `make rebuild-infisical` is rewritten around a new `make infisical-restore` (script shared with the rehearsal). Org/project/identities/PKI survive; `make refresh-identity` then only confirms health.
4. **UniFi rolls in this tranche with two operator hand steps** — download a backup before, wizard-restore after. I stop before `make rebuild unifi` until the backup is confirmed.

Routine calls made here, not interview items: the three Cloudflare AAAA corrections apply before the snippet change so the "exactly six replaced" plan check is unambiguous; the netconsole stream's `host` becomes `${HOST}` with `use_dns(yes)` + `use_fqdn(no)` on `s_netconsole` only (short names, matching the syslog lanes); the apt-proxy Ansible template drops `ansible_managed` so cloud-init and Ansible write identical bytes; `scripts/infisical_backup.sh` gains the three missing folders.

## Scope and sequencing (serial — `PARALLEL: no`)

### 0. Commit hygiene

Small commits on `nut-client`, no push (operator gate). Each numbered step below is one or two commits; the roll itself commits nothing until its docs update.

### 1. DR gate — before any VM is touched

1. `scripts/infisical_backup.sh`: add `authentik authentik-ext jellyfin` to `FOLDERS`; run `make infisical-backup` → fresh `secrets.sops.yml` (count = every folder).
2. New `scripts/infisical_pbs_restore.sh` + `make infisical-restore [HOST=<ip>] [DIR=/opt/infisical] [SNAPSHOT=<host/infisical/…>]`: reads `shared.pbs_backup_token`/`pbs_fingerprint` from `secrets.sops.yml` and composes `PBS_REPOSITORY` from the inventory (`backup@pbs!backup-token@<proxmox-backup ansible_host>:synology`, the `pbs_client` defaults); over SSH on `HOST`: `proxmox-backup-client restore` the newest (or named) snapshot's `infisical-backup.pxar`, check the dump's `ENCRYPTION_KEY`/`AUTH_SECRET` against the stack's (`bootstrap.sops.yml`), stop the `infisical` app container, `dropdb`/`createdb` + `pg_restore` into the `postgres` container, start the app, poll `/api/status` = 200, then one universal-auth secret read with the `bootstrap.sops.yml` client id/secret (proof the identities survived). When `DIR` has no compose file (rehearsal host), the script writes a minimal one (same three images as the role, encryption material from the dump, throwaway Postgres password) — that is the only branch the rehearsal takes that production does not.
3. **Rehearsal:** `make infisical-restore HOST=<wl-resolute .30.93> DIR=/opt/infisical-rehearsal` → `/api/status` 200 + a `/shared` secret read back → then tear the stack down (`docker compose down -v`, delete the restored files). **No VM is rebuilt before this passes.** Also proves the script the real infisical roll runs in step 3.

### 2. Snippet + bindings (one commit, plan-gated)

- `user-data.yaml.tmpl`: `fqdn: ${hostname}.${service_domain}`; `write_files` for `/usr/local/bin/apt-proxy-detect` (the `apt_proxy` probe verbatim, `${apt_proxy_host}`/`${apt_proxy_port}`, `DIRECT` fallback — never a hard `Acquire::http::Proxy`) and `/etc/apt/apt.conf.d/01proxy`, both gated on `apt_proxy_host != ""`. `write_files` runs in the init stage, before `packages:` installs `qemu-guest-agent`, so first-boot packages already go through the cache when it answers.
- Module: `variable "domain_suffix"` → `variable "service_domain"`; new `apt_proxy_host` (string, default `""`) + `apt_proxy_port` (default 3142). `main.tf`: `service_domain = module.network.service_domain`, `apt_proxy_host = cidrhost(module.network.vlans[<apt-cache first vlan>].subnet, <apt-cache ip_offset>)` derived from `local.vm_configurations` by name. `modules/network/outputs.tf` drops `domain_suffix`. tftest key renamed. `vars.auto.tfvars.example` comment fixed. `vlans.example.yaml` loses the key + its comment block; `vlans.yaml` (local) likewise.
- `scripts/security_guardrails.sh`: sed pattern `(service_domain|media_domain)`.
- `ansible/roles/apt_proxy/templates/apt-proxy-detect.sh.j2`: drop the `{{ ansible_managed }}` line (content parity with cloud-init).
- `terraform/variables.tf`: `debian13` → 20260819-2575 + sha512.
- Cloudflare AAAA first: `make tf ARGS='apply -target=cloudflare_dns_record.vps_ipv6 -target=cloudflare_dns_record.plex_ipv6 -target=cloudflare_dns_record.jellyfin_ipv6'` (reviewed plan output before approve).
- **Gate:** `make plan` shows exactly `apt-cache`, `pxe`, `pdm`, `unifi`, `proxmox-backup`, `infisical` as `must be replaced` (their `user_data` snippets updated in place), plus the `debian13` download-file resource, and **nothing else** — read before any apply. `cd terraform/modules/proxmox-vm && terraform test` passes.

### 3. The roll — one VM at a time

Order and per-VM checks (each: `make rebuild <vm>` → second `make ansible <vm>` = 0 changed → `hostname -f` = `<name>.<service domain>` → `apt-config dump | grep -c Proxy-Auto-Detect` = 2 and `/usr/local/bin/apt-proxy-detect http://archive.ubuntu.com/` prints the cache URL → `make dns-records` 0 changed → a PBS snapshot under the new VMID after the next nightly run, or `vzdump`-on-demand via the PVE job for the same-day check).

1. **apt-cache** — cache goes cold (disposable, ADR 0021). First VM proves the snippet; its own probe answers `DIRECT` on first boot (acng not up yet), then the cache once the role runs.
2. **pxe** — nothing to repoint (pfSense netboot options target the address); `make ansible pxe` re-ships the baked answer files; verify `curl http://<pxe>/boot.ipxe` and the arm gate still 404s.
3. **pdm** — operator hand steps after: re-add remotes (cluster via the VIP, worklab standalone) in the PDM UI; re-do the authentik realm ([authentik-setup.md](authentik-setup.md)).
4. **unifi** — **STOP for the operator:** confirm a fresh `.unifi` backup is downloaded (Settings → System → Backups). Then `make rebuild unifi`; operator restores through the wizard; verify UOS healthy, three devices connected without re-adoption, Kuma `UniFi` green, `make unifi-plan` = no changes.
5. **proxmox-backup** — `make rebuild proxmox-backup` (single-writer LUN: the replace destroys the old VM before the new one logs in) → `make backup-finalize` → `make backup-jobs` (`pbs-self` re-created) → verify `pvesm status` on every node shows the PBS entry active, `/shared` token+fingerprint rotated, the Infisical dump cron and the cluster CronJobs still authenticate (`proxmox-backup-client snapshot list --ns databases` from 205 with the freshly rendered env).
6. **infisical** — last, after PBS is healthy: `make rebuild-infisical` (rewritten: `pvesh … --protection 0` on the VMID/node found through the VIP → `terraform apply -replace` with `-var unprotect=true` → `make inventory` → `site.yml --limit infisical` brings the stack up with the bootstrap keys → `make infisical-restore` → `/api/status` 200 + secret read). Then `make refresh-identity` (expect every identity healthy, 0 refreshed), `make ansible infisical` = 0 changed, and the vault's own nightly dump must produce a `databases/infisical` snapshot **newer than the roll** — the DoD checks recency, not exit codes.

Then `make ansible-all` twice: the second run = 0 changed with the recap reaching `plex`.

### 4. Carried debt 1 — Lancache removal (ADR 0021 Consequences)

Delete `ansible/roles/lancache/`; remove the play + tag from `services.yml`, the block + vars_file from `docker-config.yml`, the host + dir from `update-all.yml`, the README rows, the CLAUDE.md/AGENTS.md prose mentions (the ADR link keeps its filename). VM 110 does not exist on the cluster — no `qm destroy`. Synology NFS share `lancache` = operator. Check: `git grep -i lancache -- . ':!docs/'` returns only the ADR-filename link lines.

### 5. Carried debt 2 — netconsole hostnames

`kubernetes/monitoring/config/axosyslog.conf`: `s_netconsole` gains `use_dns(yes) use_fqdn(no)`; `d_openobserve_netconsole` stamps `host=${HOST}` and keeps the address as `source_ip=${SOURCEIP}`; the `app.yaml` Service comment updated. `make talos-monitoring`; prove with `echo '<3>p6 netconsole hostname probe' > /dev/kmsg` on ms-01a and an OpenObserve `netconsole` stream query showing `host: ms-01a`. `scripts/test_axosyslog_routing.py` still passes.

### 6. Docs + hand-off

CLAUDE.md: P6 landed paragraph (cloud-init `fqdn` = service domain, the probe rides cloud-init, `make infisical-restore`/`rebuild-infisical` semantics, Lancache gone, netconsole names); the `domain_suffix` What-Never-To-Do bullet retires; the `make rebuild-infisical` row + a `make infisical-restore` row in the Make Targets table; README (make targets, VM table). ADR consequence notes on 0016 / 0021 / 0039 / 0040. Tracker P6 row → as-built. Then the P7 (per-host PKI) kickoff via the `kickoff` skill, recommending a new session.

## Constraints honoured

No AdGuard rewrite (none exists; `make dns-records` is unchanged because hostnames do not change). AdGuard-first resolver order untouched (ADR 0012; `dns_config` still writes the drop-ins). PBS and infisical are never in one apply (`make rebuild` is single-target; `rebuild-infisical` targets the one VM). The guardrail still blocks the service and media domains. `domain_suffix` no longer appears in a tracked file outside `docs/`.

## Rollback

- Snippet/bindings commit: revert restores the old snippet; already-rolled VMs stay on the new fqdn (harmless — hostnames and addresses are unchanged) and would show as `must be replaced` again.
- A failed VM rebuild leaves the old VM destroyed (replace is atomic per apply, not per VM): apt-cache/pxe/pdm are derived state; PBS's data is the LUN; unifi restores from the operator's backup; infisical restores from the PBS dump (the rehearsal is the proof this path works before it is the only path).
- Cloudflare AAAA apply: Terraform-owned records, `terraform apply -target` back to the prior content if the VPS address was wrong (it is read live from the instance).

## Definition of done

`git grep domain_suffix -- . ':!docs/'` = 0; `make plan` = no changes; each of the six VMs: `hostname -f` on the service domain and `Proxy-Auto-Detect` in `apt-config dump` (fails today on all six); `make ansible-all` second run = 0 changed, recap reaches `plex`; PBS lists a snapshot per new VMID and a `databases/infisical` snapshot newer than the roll; the wl-resolute rehearsal answered `/api/status`; `git grep -i lancache -- . ':!docs/'` = only the ADR-filename link; the `netconsole` stream shows a hostname; `terraform test` in the VM module passes; push notification "P6 ready for operator testing".

## As-built (2026-08-25) — deviations from the plan above

- **DR gate:** rehearsal on `wl-resolute` passed first try (snapshot `host/infisical/2026-08-25T06:30:02Z` → 1 org → `/api/status` 200 → `/shared` read). The refreshed SOPS export grew from 12 to 18 folders / 84 secrets.
- **Cloudflare AAAA:** the "drift" was pure formatting — Cloudflare compresses, Vultr reports a 4-digit group — so the apply changed nothing and the plan showed it again. Fixed for good with `cidrhost("${v6}/128", 0)` in `cloudflare-dns.tf`.
- **First rebuild aborted** after destroying 216: bpg's SSH client refuses a `known_hosts` line with an empty hostname (line 183, left by an earlier `ssh-keygen -R`). Recovery was `make build apt-cache` (the VM was out of state, so `-replace` no longer applied). Delete malformed lines before a roll.
- **A bare `terraform plan` outside `make`** prompts for `TF_VAR_*` on stdin and holds the state lock while it waits — always go through `make plan` / `make tf ARGS=`.
- **PBS:** `make rebuild proxmox-backup` died at its `inventory` step because PVE dropped `pbs-self` with VMID 201 (the CLAUDE.md bullet); recovery = `terraform state rm`, `make inventory`, `make ansible proxmox-backup`, `make backup-finalize`, `make backup-jobs`. The rotated token/fingerprint propagated through the agents and the three cluster `InfisicalSecret`s within minutes; `make infisical-backup` had to be re-taken so the restore script's PBS creds were current.
- **Infisical:** the first `site.yml` pass after the replace ends 401 once the empty stack answers (a later play's secrets login) — benign, the recipe now tolerates it. **The restored 06:30Z dump pre-dated the PBS rotation**, so `/shared` came back with the dead token and `pbs_client`'s verify step hung on the fingerprint prompt (11 min; `timeout` does not end it). Fixed by PATCHing the two keys from `secrets.sops.yml`; `make rebuild-infisical` now takes a fresh dump right before the replace. `refresh-identity` found every identity healthy — nothing re-issued, the PKI root untouched.
- **PVE prunes a destroyed VMID from every backup job** (`nightly-fleet` lost 205); `make rebuild` now ends with `make backup-jobs`.
- **UniFi:** wizard restore by the operator; `make unifi-plan` converged to no changes against the restored controller. **pdm:** remotes + authentik realm remain operator hand steps.
- **netconsole:** proven with a KERN_ERR line from ms-01a → `host: ms-01a`, `source_ip` beside it.
- Observed, not P6's: `nightly-fleet` does not include `pdm` 220 or `control` 212 (`backup_jobs` in `vars.auto.tfvars`); PDM's own snapshot this session was on-demand.
