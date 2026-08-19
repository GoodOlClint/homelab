# Ansible Collection Modernization Review

Date: 2026-08-12. Scope: every hand-rolled `shell`/`command`/`uri` task in `ansible/` (vendored `juju4.openobserve` and `geerlingguy.docker` roles excluded), plus the state of the custom collection repos under `~/Source`. Rule applied: defer to a maintained collection unless ours is clearly superior.

## TL;DR

1. **The devopsarr collections are declared but never used.** `requirements.yml` and `plex_services/meta/main.yml` list `devopsarr.{sonarr,radarr,lidarr,prowlarr}`, yet `plex_services` drives every arr API with ~76 raw `uri` calls. Roughly 28 of those (the arr trio + Prowlarr) map 1:1 onto devopsarr modules. This is the single biggest replaceable surface in the repo.
2. **`community.proxmox` 2.0 covers more than we use.** `monitoring_users` provisions PVE users/ACLs/tokens with `pveum` over SSH; `backup-finalize.yml` and `ceph.yml` define storage with `pvesh`/`pvesm` — `proxmox_user`, `proxmox_access_acl`, and `proxmox_storage` replace all of it, and the storage switch takes the PBS token off the process argv.
3. **Your own PBS collection is the right answer for the `proxmox_backup` role.** No maintained PBS-config collection exists; `goodolclint.proxmox_backup_server` (15 modules, unmerged branch, red CI) covers ~15 of the role's ~24 shell tasks — including the verify/gc/prune-job tasks that today can never fail and report changed every run.
4. **The `ansible-arrs/` directory should be abandoned.** One scaffold commit per repo, module code never committed, no remotes, no tests, and it duplicates both devopsarr (maintained) and the standalone bazarr repo (better). Nothing worth salvaging.
5. **Post-migration, the portfolio converges — one plausible new collection, and it's an upstream contribution.** The future state (Part 4) retires several roles this review would otherwise fix (nvidia, nvidia_licensing, squid, lancache), maps its recurring rebuild machinery onto collections we already have or built (community.proxmox, PBS, uptime_kuma, openobserve), adds `community.crypto` at WP8, and leaves exactly one genuine gap: Infisical PKI modules — best pursued upstream in `infisical.vault`, not as a new `ansible-collection-*` repo.
6. **The standalone custom collections are real code stuck in delivery limbo.** 7 of 10 implemented ones sit entirely on unmerged `claude/build-ansible-collection-*` branches (GitHub main = empty scaffold). Merged and usable today: **uptime_kuma, tautulli, seerr**. The adoption winners are **uptime_kuma** (replaces the hand-managed Kuma config + `seed_uptime_kuma.py`), then **bazarr / sabnzbd / openobserve / proxmox_backup_server** after merge + green CI.

## Part 1 — Homelab repo: hand-rolled → maintained modules

~229 shell/command tasks found; after excluding vendored roles, molecule dirs, and legitimate keeps, ~20 clear replacements remain.

### Tier 1 — REPLACE (clear wins)

| Where | Now | Replace with |
|---|---|---|
| `roles/monitoring_users/tasks/proxmox.yml:4-30` | `pveum user list` + parse + `user add` over root SSH | `community.proxmox.proxmox_user` (API-based, idempotent) |
| `proxmox.yml:44-70` | `pveum acl list` + substring-match `when` + `aclmod` | `community.proxmox.proxmox_access_acl` — also fixes a latent bug: the substring check can false-positive across unrelated ACL lines |
| `proxmox.yml:74-98` | `pveum user token list/add` + regex secret scrape | `proxmox_user` `tokens:` suboption (returns secrets; the Infisical write-back at :100-107 is unchanged) |
| `roles/proxmox_backup/tasks/main.yml` (~15 of ~24 shell tasks: datastore :431-456, user :483-506, ACLs :536-707, tokens :570-637, verify/gc/prune jobs :710-745) | `proxmox-backup-manager` shells; the job tasks are `failed_when: false` + `changed_when: rc == 0` — they can never fail and always report changed | `goodolclint.proxmox_backup_server` modules (`datastore`, `datastore_config`, `user`, `token`, `acl`, `verify_job`, `prune_job`) — see Part 3 for the merge prerequisite |
| `playbooks/backup-finalize.yml:45-152` | `pvesh get /storage` + 4-way drift branching + `pvesm add/set` with the token on argv | `community.proxmox.proxmox_storage` `type: pbs` (`pbs_options` verified to carry server/datastore/username/password/fingerprint/namespace); keep the `pvesm status` probe as the verification gate |
| `roles/proxmox_host/tasks/ceph.yml:91-106, 128-151` | `pvesm add rbd/cephfs` + read-then-`pvesh set` content dance | `proxmox_storage` `type: rbd`/`cephfs` with declarative `content:` |
| apt repo stanzas ×5: `docker/tasks/main.yml:39-98`, `telegraf/install-debian.yml:4-49`, `plex/tasks/main.yml:202-237`, `pbs_client/tasks/main.yml:12-57`, `proxmox_backup/tasks/main.yml:37-79` | stat-key → get_url → `gpg --dearmor` → shell-grep → apt_repository, repeated per repo; `pbs_client` even uses a `wget` shell for the key | `ansible.builtin.deb822_repository` — one task per repo; also delete the noise install-gates (`dpkg -l \| grep`, shell-grep repo checks). **Do NOT pass `signed_by:` a URL** (an earlier draft of this row recommended it): given a URL the module re-fetches on EVERY run — `write_signed_by_key` early-exits only for `os.path.isfile` — and raises an unhandled `RuntimeError` when the fetch fails, making the vendor host a hard per-run dependency of every play the role appears in. Fetch the key with `get_url` to a path behind a `not exists or size == 0` guard and pass the **path**. See the CLAUDE.md rule and the W6 results doc; this was measured, not theorised |
| `playbooks/update-all.yml:48-50` | `shell: docker image prune -af` with `changed_when: false` | `community.docker.docker_prune` |
| `roles/plex_certificate/tasks/main.yml:100-147` | xmlstarlet in-place edits, no `changed_when` — **bounces Plex on every run** | `community.general.xml` (idempotent; keep `no_log` on the PFX edit; drop the xmlstarlet package) |
| `roles/vps_hardening/tasks/fail2ban.yml:22-27`, `roles/vps_nftables/tasks/main.yml:47-53` | `command: rc-update add <svc> default` | fold `enabled: true` into the adjacent `ansible.builtin.service` task (speaks OpenRC natively) |
| `roles/proxmox_backup/tasks/main.yml:226-305` | `iscsiadm` discovery/login/auto-startup + `readlink` | `community.general.open_iscsi` (returns `devicenodes`) |
| `roles/nvidia/tasks/main.yml:113-122` | `shell: curl --insecure -o token_$(date).tok` | `ansible.builtin.get_url` with a fixed dest (also kills the fragile `ls -1t` scrape at :70-77) |
| `roles/nvidia_licensing/tasks/main.yml:26-36` | `git config --global --add safe.directory` — appends duplicates every run | `community.general.git_config` |
| venv creation ×3: `nvidia_licensing/tasks/main.yml:50-58`, `mcp/tasks/mempalace.yml:46-50`, `plex/tasks/main.yml:355-361` | `command: python3 -m venv` before `pip:` | delete — `ansible.builtin.pip` with `virtualenv:` creates the venv itself |
| `roles/rsyslog_client/tasks/main.yml:30-35` | `shell: ls ... \|\| true` | `ansible.builtin.find` |

Two non-module bugs surfaced in passing, worth fixing regardless: the `monitoring_users` ACL substring check (`proxmox.yml:58`) and the unconditional `pveum passwd` that re-sets the password every deploy (`proxmox.yml:32-42` — verify `proxmox_user` updates existing passwords before deleting it).

### Tier 2 — CONSIDER (module exists, hand-rolled has a reason)

| Where | Module | Why not automatic |
|---|---|---|
| `roles/proxmox_host/tasks/ceph.yml:44-87, 108-112` (mon/mgr/mds/osd/pool create) | `community.proxmox.proxmox_ceph_{mon,mgr,mds,osd,pool}` | Brand-new in 2.x, unproven; current CLI path is battle-tested through the worklab rehearsals (throttle:1 mon serialization etc.). ADR 0023 sets the API-module precedent — evaluate **post-cutover**. `pveceph install`/`init`/`fs create` have no module and stay CLI regardless |
| `roles/github_runner/tasks/main.yml:164-223` | `community.general.github_app_access_token` lookup | Kills the 25-line hand-rolled RS256 JWT shell but adds PyJWT+cryptography to the controller; the registration-token POST has no module either way |
| `roles/vps_hardening/tasks/aide.yml:21-26` | `community.general.apk` with `name: aide@testing` | Unverified that the module tolerates the `@tag` repo syntax — test on the VPS first |
| `roles/expand_disk/tasks/main.yml:50-57` | `community.general.filesystem` `resizefs: true` | Fine to switch; keep `growpart` (no module exists) |
| `tasks/bootstrap_pre_tasks.yml:55-89` | `password`/`random_string` lookups instead of `openssl rand` commands | Marginal; current form matches the `secret_gen_cmd` idiom. Do NOT touch the `sops set --value-stdin` tasks — deliberate no-argv design |
| `roles/infisical_client/tasks/install.yml:22-26` | `deb822_repository` instead of `curl \| bash` vendor script | Supply-chain win but pins a repo URL/key the vendor script abstracts |

### Tier 3 — KEEP (deliberately hand-rolled)

Everything session-severing (`ifreload -a` async, WireGuard restarts/`wg syncconf`, `wg genkey` — no module exists anywhere), all on-host verification probes (adguard/bind9 digs — the `dig` lookup runs on the controller, wrong vantage point), `pvecm qdevice` (not covered by `proxmox_cluster`), the Infisical identity/folder/bootstrap uri layer (`infisical.vault` 1.2.2 has secret CRUD + login only), `generate_secret.yml`'s parameterized generator design, the netconsole/sysctl/mount gates in `proxmox_host`, vendor installers (UniFi, nvidia-ctk), Alpine `lbu`, certbot, and squid's CA generation (squid retires at cutover — don't invest). `monitoring_users/tasks/unifi.yml` is operationally dead per the no-credentialed-probe rule — the real modernization there is deletion.

## Part 2 — The *arr API surface (plex_services)

`plex_services/tasks/main.yml` (2,553 lines) contains ~76 `uri`/curl tasks. Coverage breakdown:

| Target | ~tasks | Maintained coverage |
|---|---|---|
| Sonarr/Radarr/Lidarr (auth, naming, media-management/recycle bin, root folders, download clients, Plex notifications, profile lookups) | ~24 | **devopsarr** — near-complete (`*_host_config`, `*_naming`, `*_media_management`, `*_root_folder`, `*_download_client`, `*_notification`, profile info modules) |
| Prowlarr (app sync registration, indexer seeding) | 4 | **devopsarr.prowlarr** — `prowlarr_application`, `prowlarr_indexer` map 1:1 |
| SABnzbd (misc config, dirs, categories, news servers) | ~14 | none — custom collection candidate |
| Bazarr (form-encoded settings, providers, integrations, backfill) | ~10 | none — custom collection candidate |
| Overseerr/Jellyseerr (full first-run bootstrap; largest, most fragile block) | ~22 | none — custom collection candidate; **but no seerr service runs in the fleet today** (bookmark only) |
| Tautulli | 2 (rest is `ini_file`) | none; low priority as-is |

devopsarr maintenance status (Galaxy, checked 2026-08-12): sonarr 1.3.1 (Jun 2025), prowlarr 1.0.1 (Jan 2026), radarr 1.2.0 (Oct 2024), lidarr 1.0.0 (Feb 2024), readarr 0.1.0 (2023, dead — as is Readarr upstream). Uneven but alive, and by the defer-to-maintained rule it beats our uncommitted custom arrs decisively.

Glue that must stay hand-rolled under any module regime: API-key extraction from `config.xml`/`sabnzbd.ini`/`config.yaml` (modules need the key as input), service readiness gates (`until`/retries), Bazarr's self-restart-on-POST handling, the Seerr cookie-session bootstrap, the Infisical write-back of extracted keys, and the container/filesystem side effects (compose restarts, Postgres XML injection).

## Part 3 — Custom collections: state and what's needed

Full survey data is in the session transcript; the operative facts:

**Delivery, not code, is the gap.** The implemented collections follow `ansible-collection-standards.md` (stdlib-only clients, full docs, check_mode, unit+integration tests, CI) and the code is real — but 7 of 10 sit on unmerged `claude/build-*` branches with GitHub main containing only scaffold. Nothing is on Galaxy; homelab adoption means `requirements.yml` git-source entries, which makes **merge to main + a v0.1.0 tag the hard prerequisite** for everything below.

| Collection | State | Verdict / action |
|---|---|---|
| `ansible-arrs/*` (7 repos incl. servarr-common) | 1 scaffold commit each, modules **untracked in git**, no remotes, no tests | **Abandon.** Redundant with devopsarr; the bazarr copy is superseded by the standalone repo |
| uptime_kuma | **merged**, CI present, 8 modules | **Adopt first.** Replaces hand-managed Kuma UI config + `scripts/seed_uptime_kuma.py` declaratively (fits ADR 0011). Needs pip `uptime-kuma-api>=1.2.0` in the venv (`make init`); verify the lib supports the deployed Kuma version. `lucasheld.uptime_kuma` exists but is stale (1.2.0, 2023) — ours is not clearly inferior, and it's the same underlying pip lib |
| tautulli | **merged, CI green**, 8 modules, 14 test files | Adopt opportunistically — additive (e.g. `tautulli_notification_agent` → ntfy), nothing to replace |
| seerr | **merged**, 14 modules | Usable but **no consumer** — park until a seerr service exists in the fleet |
| bazarr (standalone) | branch-only, 14 modules, 9 test files, CI | Merge + green CI, then replace the Bazarr uri/curl block in plex_services. Verify the modules handle the form-encoded settings endpoint and self-restart behavior (the known traps) |
| sabnzbd | branch-only, 8 modules | Merge + green CI, then replace the SABnzbd uri block |
| openobserve | branch-only, 12 modules, 16 test files | Merge + green CI, then replace uri calls in `monitoring`/`openobserve_dashboards`. **Must validate against the pinned v0.92.0-rc2 (schema 46)** |
| proxmox_backup_server | branch-only, 15 modules, **CI red**, Phase-9 residue at root | Fix CI, merge, finish cleanup — then it's the Tier-1 replacement for the `proxmox_backup` role's shell (Part 1). Verify API datastore-create tolerates the path-not-empty re-registration case the current config-file workaround handles |
| authentik | branch-only, 25 modules, CI red | Park — authentik is disabled in the fleet; when it returns, weigh native blueprints first |
| synology_dsm | branch-only, 13 modules, CI red | Park — adopting expands IaC scope to the NAS; operator decision, not a gap-fill |
| caddy | branch-only, 6 modules | Park — homelab deploys a Caddyfile via template; admin-API config is a model mismatch |
| home_assistant | scaffold only, 0 modules | Nothing exists; HA not in fleet |
| ansible-pfsense-collection | on main but 1 unpushed commit + dirty tree, 34 modules, 71 test files, **no CI** | Blocked on an operator decision: it targets the pfSense REST API v2 (requires installing the jaredhendrickson13 package on the firewall) vs. the current hand-managed model (ADR 0005) + `pfsensible.core` (maintained, in use). Decide before investing |

## Part 4 — Post-migration future state: collection needs down the road

Read against [ms01-cluster-iac-plan.md](ms01-cluster-iac-plan.md) and [rebuild-as-routine-design.md](rebuild-as-routine-design.md). Galaxy re-checked 2026-08-12 for every future-state service: nothing maintained exists for Harbor, AdGuard Home, Zot, or PBS beyond one-person install roles — the maintained-collection landscape does not change the picture below.

### Findings above that die at cutover (don't invest)

The migration retires several roles this review touched — do the Tier-1 mechanical fixes only where the role survives:

- **nvidia / nvidia_licensing** — vGPU is retired entirely; the LLM VM runs full passthrough with the driver in the guest and the nvidia-licensing VM is deleted (plan WP4). The get_url/git_config/venv findings in those roles are moot; skip them.
- **squid** (already flagged), **lancache** (ADR 0021), **monitoring_users/unifi.yml** (operationally dead per the no-credentialed-probe rule) — deletion is the modernization.
- **plex_certificate** — survives but transforms: WP8 generalizes it into the LE-wildcard role. Do the `community.general.xml` fix now (it stops real spurious Plex restarts today), but fold the certbot flow question into WP8 rather than touching it twice.

### Future-state work that maps onto collections we already have or built

| Future-state item | Collection answer |
|---|---|
| Cluster create/join, storage defs, user/ACL/token provisioning | `community.proxmox` — already the ADR 0023 direction; Part 1's adoptions are the same trajectory. Ceph mon/mgr/osd/pool modules: post-cutover evaluation as already noted. Qdevice (temporary while 2-node, dropped when pve joins) stays `pvecm` CLI — no coverage, and it's transient anyway |
| PBS rebuild-as-routine (class S — config fully re-provisioned by role; fingerprint rotates every rebuild → fleet `pbs_client` re-run) | `goodolclint.proxmox_backup_server` — the rebuild story makes the module conversion *more* valuable post-migration, since the role re-runs from scratch on every PBS rebuild and today's never-fail job tasks would mask a bad rebuild. `node_info` may also replace the fingerprint scrape feeding `/shared` |
| Kuma monitors re-seeded on every openobserve-stack rebuild (`scripts/seed_uptime_kuma.py` is the current mechanism) | `goodolclint.uptime_kuma` — the rebuild verb turns the seed script from a one-time convenience into recurring rebuild machinery; declarative monitors are the right shape for that. Adopt before WP4 lands the openobserve LXC |
| OpenObserve dashboards/alerts re-provisioned (IaC per the matrix; history rides the data volume) | `goodolclint.openobserve` — same rebuild-driven argument; validate against the schema pin first |
| pfSense IaC (explicit plan future-work: "evaluate pfsensible collection vs a REST-API path") | This is exactly the parked `ansible-pfsense-collection` decision from Part 3. When that future-work item activates, the eval is three-way: `pfsensible.core` (maintained, SSH/PHP, already in use), the custom collection (REST API v2, needs the firewall-side package), or a Terraform provider. Nothing to do until then |
| Fleet cert distribution + LE wildcard renewals (WP8) | `community.crypto` — **not currently installed**; add it when WP8 starts. Even if lego/certbot own the ACME flow as the plan sketches, `x509_certificate_info` is the right tool for the WP8 DoD verification gates, and if the cert_client role goes module-based instead of CLI, `acme_certificate` is the maintained path |

### Genuinely new gaps (no collection exists, maintained or ours)

| Gap | When it bites | Recommendation |
|---|---|---|
| **Infisical PKI management** (WP8: internal CA, cert profiles, ACME directory config) | WP8, if the Infisical-PKI gate passes | `infisical.vault` 1.2.2 covers secret CRUD + login only — no PKI, identity, or folder modules. If WP8 goes Infisical PKI, the CA/profile provisioning will be more hand-rolled `uri`, exactly the pattern this review exists to retire. Options in order: contribute PKI modules upstream to `infisical.vault` (it's Infisical's own collection, active — Jun 2026 release), or extend the identity-provisioning uri layer we already keep. Don't start a custom collection until the WP8 gate confirms Infisical PKI is even available on the self-hosted tier; step-ca fallback changes the answer entirely |
| **AdGuard Home API** | Post-cutover steady state, maybe never | No maintained collection (Galaxy has install roles only). But the future state *shrinks* the need: config is IaC and rebuild-as-routine resets drift (class S, template-on-fresh-install works again every rebuild), DNS-first moves internal names to BIND with AdGuard forwarding zones, and the admin password gets seeded into Infisical pre-build so the role can template the bcrypt hash. The remaining live-edit pain (the "initial only" template gotcha) mostly evaporates when a rebuild is cheap. **Don't build**; revisit only if between-rebuild live edits stay frequent |
| **Container registry (ADR 0022, WP4)** | WP4 | Zot (provisional winner) is config-file-driven — templates suffice, no collection needed, and the ADR's self-rebuild requirement favors exactly that simplicity. Harbor would change this: it's API-configured and Galaxy has only hobby-grade collections (swisstxt/xrow, small) — a Harbor pick means either hand-rolled uri or another custom collection, which is itself a point against Harbor in the eval |
| **Proxmox Datacenter Manager (PDM VM)** | Day 3+ | Too young for any collection to exist; config surface is tiny (class S, verify at deploy). Hand-roll, don't build |
| **apt-cacher-ng (ADR 0021), Libation (ADR 0018), keepalived, BIND zone templating (ADR 0006), pg_dump timer, netconsole/rsyslog** | Various WPs | All file/template-driven by design — no collection needed, and that's the right answer. Listed to show they were considered |

### Net assessment

Post-migration, the collection portfolio converges rather than grows: `community.proxmox` + `goodolclint.proxmox_backup_server` cover the host/backup plane, devopsarr + the custom bazarr/sabnzbd collections cover the arr plane, uptime_kuma/openobserve cover monitoring re-seeding, and `community.crypto` joins at WP8. The only plausible *new* collection down the road is Infisical PKI modules — and the right first move there is upstream contribution, not another `ansible-collection-*` repo. Everything else future-state is deliberately file-driven or covered by retirements.

## Suggested sequencing

1. **Quick wins in-repo, no collection work needed:** deb822_repository consolidation (5 roles), `docker_prune`, `community.general.xml` in plex_certificate (stops the spurious Plex restarts), OpenRC `enabled:` folds, venv/pip cleanups (skip the nvidia_licensing one — role retires at cutover), `open_iscsi`, the two monitoring_users bugs. Each is a localized mechanical change.
2. **community.proxmox adoption:** `monitoring_users/proxmox.yml` → `proxmox_user`/`proxmox_access_acl`; `backup-finalize.yml` + ceph storage defs → `proxmox_storage`. (Ceph mon/mgr/osd/pool modules: post-cutover evaluation.)
3. **devopsarr adoption in plex_services:** replace the ~28 arr-trio + Prowlarr uri tasks with the modules already declared in requirements.yml. Keep the key-extraction/readiness/write-back glue.
4. **Custom collection pipeline:** adopt uptime_kuma now; fix CI + merge bazarr, sabnzbd, openobserve, proxmox_backup_server, then wire each into its role; archive `ansible-arrs/`; park the rest pending operator decisions (pfsense model, synology scope, authentik return).

Items 2–4 are each brownfield-gate-sized changes (cross-cutting, multi-commit) — plan them as such rather than folding into cutover work.
