# Change plan — in-use gating for `make update`, and Valheim on the public status page

- **Status:** awaiting operator review (brownfield gate step 4)
- **Date:** 2026-08-01
- **Motivating incident:** `make update` recreated the Valheim container and rebooted the docker VM while players were connected.

## Scope

Two changes sharing one signal source.

1. **Gate `make update`** so container recreates and reboots defer when Valheim or Plex is in use. Operator-selected behaviour: **skip the host and continue the run**, report what was deferred, `FORCE=true` to override.
2. **Put Valheim on `status.<media domain>`** (an UptimeRobot Public Status Page — the subdomain is a CNAME to `stats.uptimerobot.com`), and audit/document the intended monitor set for that page, which is hand-managed today with no inventory doc.

Out of scope: automating UptimeRobot itself (no API key in the repo, no provider); Uptime Kuma status pages (ADR 0011 keeps Kuma internal); any change to the alerting channel.

## What the existing system gives us

- **Valheim health and player count — superseded 2026-08-10.** `valheim-status` now queries the PlayFab lobby instead of A2S (operator-built image `valheim-server:playfab-test`) and `STATUS_HTTP=true` publishes `/opt/valheim/htdocs/status.json` on `:8080`, rewritten every 10s with `player_count`, `join_code`, `max_players`, `game_version` and a `players` array. This replaces both signals the earlier draft of this plan relied on: no log scraping for the count, no status-file read for health. On a failed query the file carries only `error` plus a timestamp.
- **Still true:** A2S itself is dead under crossplay (`ZNet.OpenServer()` only builds the Steam game server on the Steamworks backend), so nothing answers on the UDP game port and UptimeRobot still cannot probe Valheim outside-in. Uptime Kuma *can* now watch it internally — a `json-query` monitor on `status.json` landed 2026-08-10.
- **New risk introduced by the image swap:** `valheim-server:playfab-test` exists only on the docker host — `docker pull` returns `pull access denied for valheim-server`. Play 2 of `update-all.yml` runs `pull: always`, so **`make update` now fails on the docker host** until the image has a registry home or the service opts out of the pull.
- **Plex in-use:** the check already exists — `roles/plex/templates/plex_config_pbs_backup.sh.j2:108-129` curls `/status/sessions` with `X-Plex-Token` and reads `size="N"` off the `MediaContainer`. The Ansible-side token is `secrets.plex.plex_token`.
- **Metrics path:** telegraf runs fleet-wide with `[[outputs.prometheus_client]]` on `:9273`, and Prometheus has a `telegraf` scrape job. A new metric needs a telegraf input on the docker VM — **not** the node_exporter textfile collector, which only exists on the monitoring VM.
- **Heartbeat path:** `roles/monitoring/tasks/main.yml:369-380` already pushes a per-minute UptimeRobot heartbeat with the URL templated from Infisical and `no_log: true`. Same pattern, second URL.

## Design

**`status.json` is the single source of truth** — no helper script needed, which deletes WP1's main deliverable. Every consumer reads the same endpoint on the docker VM. Nothing reads OpenObserve: ADR 0011 rejected a detector that queries OpenObserve because it shares a failure mode with what it watches, and that objection applies here too.

| Consumer | Mechanism |
|---|---|
| Metric | telegraf `[[inputs.http]]` with `data_format = "json_v2"` scraping `:8080/status.json` → `player_count`, `max_players` → existing Prometheus `telegraf` job |
| Container health | compose `healthcheck` — `error == null` plus a 2-minute mtime floor on the status file, so a frozen updater is caught. Landed 2026-08-10 |
| Internal reachability | Uptime Kuma `json-query` monitor, `platform == playfab`. Landed 2026-08-10 |
| Status page | cron on the docker VM: push `uptimerobot_valheim_heartbeat_url` while `curl -fsS localhost/status.json \| jq -e '.error == null'` succeeds |
| Update gate | `ansible.builtin.uri` against `:8080/status.json` in `update-all.yml`, gating on `player_count` |

The heartbeat asserts **the server process is healthy**, not that it is reachable from the internet. Nothing can assert the latter while the server answers no queries; that limitation gets written into the status-page doc rather than papered over.

**Gate placement** (`ansible/playbooks/update-all.yml`):

| Play | Hosts | Gated |
|---|---|---|
| 1 — apt upgrade | all | see the hole below |
| 2 — compose pull/recreate | docker | yes |
| 3 — reboot | docker, plex | yes |

Plex is apt-installed, not a compose service, so it never appears in play 2.

## The hole in the chosen scope

The selected scope leaves play 1 ungated, on the reasoning that "apt upgrade doesn't interrupt anyone by itself". On these two hosts it does:

- **Plex VM:** upgrading `plexmediaserver` restarts the service in its postinst. Streams drop with no reboot involved.
- **Docker VM:** upgrading `docker-ce` restarts `dockerd`. `/etc/docker/daemon.json` has no `live-restore`, so running containers stop with it — and the daemon's own shutdown timeout is 15s, well under the `stop_grace_period: 120s` just added to the Valheim service. Valheim can be SIGKILLed mid-save by a package upgrade even though the compose-level stop is now safe.

Recommended amendment, for approval: **gate play 1 on the `docker` and `plex` hosts too** (fleet-wide apt stays ungated). Independently, add `"live-restore": true` to the docker daemon config so a daemon restart stops bouncing containers at all. Both are small; neither is in the plan below until you say so.

## Sequencing

Four commits, each independently revertable.

1. **WP1 — metric only.** telegraf `[[inputs.http]]` + `json_v2` parser on the docker VM, `player_count` visible in Prometheus. The script and the container healthcheck this WP originally carried are gone — `status.json` and the compose healthcheck (landed 2026-08-10) cover them. Fold in the registry fix for `valheim-server:playfab-test` here, since it blocks `make update` on the same host.
2. **WP2 — heartbeat + status page.** New external secret `uptimerobot_valheim_heartbeat_url` in Infisical `/monitoring`; cron on the docker VM mirroring the monitoring role's; new `docs/uptimerobot-status-page.md` recording the intended public monitor set (Plex HTTP, VPS ICMP, Valheim heartbeat, and what each does and does not prove). Requires creating the Heartbeat monitor in the UptimeRobot UI first — that URL is the secret.
3. **WP3 — the gate.** Pre-tasks in plays 2 and 3 of `update-all.yml`; `update_force` var (`FORCE=true` from the Makefile); deferred hosts reported in a final summary task.
4. **WP4 — docs.** CLAUDE.md: add the docker VM as a reader of `/monitoring`, add the new secret to the Infisical table, and add a "What Never To Do" entry for ungated fleet updates against user-facing services. Two ADRs via the `adr` skill (drafted below, written on approval).

## Decisions needing ADRs

- **ADR 0018 — Fleet updates defer on in-use services.** `make update` is no longer unconditional; hosts with live users are skipped, not blocked or queued, and the override is explicit. Rejected: wait-and-retry (turns an interactive command into a multi-hour block), abort-the-run (one Valheim player blocks patching DNS).
- **ADR 0019 — UDP-only public services report liveness by local-signal heartbeat.** A service that answers no probe cannot be monitored outside-in; it pushes instead, and the pushed signal is read locally on the host rather than from the observability stack. Rejected: an A2S probe (dead under crossplay), a Kuma monitor (UDP, and Kuma is internal per ADR 0011), reading the count from OpenObserve (shared failure mode, per ADR 0011's own rejection).

## Definition of done

Each half must fail before the change and pass after.

- **Gate:** with a player connected (or the helper stubbed to report one), `make update` skips the docker and plex hosts and names them in the summary; with nobody connected, both update normally; `FORCE=true make update` proceeds regardless. Today the playbook has no skip path at all, so the "before" case fails by construction.
- **Heartbeat:** stopping the Valheim container stops the pushes and drives the UptimeRobot monitor down within its grace window; starting it recovers. Evidenced with the monitor's own event log.
- **Metric:** `valheim_players` is queryable in Prometheus and matches the count in the container log.
- **Idempotency:** a second `make ansible docker` run reports zero changes.
