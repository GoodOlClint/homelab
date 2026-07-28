# macOS Fleet Management & Metrics — Research

Status: research findings (2026-07-20). Deep-research workflow: 5 angles, 22 sources fetched, 85 claims extracted, 25 adversarially verified (22 confirmed / 3 refuted). Not yet an ADR — this is the survey feeding one.

## TL;DR recommendation

Split the two jobs; they do not want the same tool.

- **Updates — split by layer.** Homebrew/app/config stays in Ansible (bolt Macs onto `make update`). OS patching goes to a lightweight MDM, because on Apple silicon it *has* to. Recommended: **Mosyle Business FREE** (full macOS MDM, 30-device cap) — it escrows the bootstrap token and drives updates via Declarative Device Management (DDM), which macOS 27 now mandates.
- **Metrics — feed OpenObserve, don't build a dashboard.** Run an Apple-silicon Prometheus exporter (**macmon** or **mactop**) on each Mac and scrape it into the existing OpenObserve stack. These expose GPU/ANE/thermal telemetry that generic `node_exporter` cannot. No standalone dashboard needed.

The one non-negotiable gotcha drives the whole update recommendation: **unattended OS updates on Apple silicon require volume ownership** — a secure-token user whose bootstrap token is escrowed to an MDM. Without it, `softwareupdate`/`ScheduleOSUpdate` fails with a permissions error. A pure-Ansible `softwareupdate` OS-update role was **refuted 0-3** in verification. There is no Ansible-only path to headless OS updates.

## Updates

### Why Ansible can't do OS updates (but should do everything else)

| Layer | Tool | Notes |
|---|---|---|
| Homebrew / casks / mas / dotfiles / firewall | **Ansible** (`osx-provisioner` collection) | 9 roles incl. `homebrew_retry` (network-resilient brew installs). No OS-update role — deliberately. Complements `make update`. |
| macOS OS updates / upgrades | **MDM + DDM** (Mosyle FREE recommended) | Requires bootstrap-token escrow. Not scriptable from Ansible without the MDM. |

`osx-provisioner/collection` ships: asdf, clamav, colima, downloader, firewall, homebrew_retry, homeshick, jumpcloud, symlinks. This is your drop-in for adding macOS hosts to the existing Ansible layer — app/config/dotfile management, nothing that touches OS patching.

### MDM options for OS updates

| Option | Fit | Cost / effort | Watch-outs |
|---|---|---|---|
| **Mosyle Business FREE** ⭐ | Turnkey, full macOS MDM | Free, ≤30 devices | 30-device cap; reduced support; vendor holds control plane. Cloud SaaS (a vendor sees your fleet). |
| Kandji free tier | Possible | — | **Not confirmed** in this research — evaluate separately before relying on it. |
| MicroMDM / NanoMDM | Self-hosted, MIT, GUI-less | High engineering effort | MicroMDM in maintenance mode (fixes through end-2025); its legacy update path **breaks on macOS 27** (no DDM orchestration). NanoMDM is the minimalist successor but needs a separate declaration server (kmfddm) — real build work. |

The macOS 27 / WWDC-2026 change is load-bearing and recent (~6 weeks before this research): Apple removed the legacy MDM software-update commands **with no grace period**. Updates must go through DDM declarations now. This is *why* a maintained MDM beats rolling your own right now — the OSS path just got a new mandatory component to build.

### Headless-Mac update gotchas (all confirmed)

- **Volume ownership** = secure-token user + bootstrap token escrowed to MDM. The escrowed token itself becomes a volume owner, letting the MDM silently authorize updates on macOS 11+.
- Bootstrap token is generated when a secure-token user **first logs in** (10.15.4+) and auto-escrows to MDM. So a fresh headless Mac needs that first interactive-ish login to bootstrap the chain.
- **Open question for us:** where does the secure-token user's recovery secret live — Infisical? And how do we bootstrap MDM enrollment + the first secure-token login on a fresh headless Mac Studio with no GUI session?

## Metrics

### Don't build a dashboard — scrape an exporter into OpenObserve

All of these emit Prometheus text over HTTP that OpenObserve ingests. Generic `node_exporter`/Alloy gives you CPU/load/mem/disk/net but **not** Apple-silicon GPU/ANE/thermal/power — those need one of these:

| Exporter | Metrics | Headless packaging | Maturity |
|---|---|---|---|
| **macmon** (`macmon serve`, :9090) ⭐ | CPU/GPU/ANE power, per-cluster CPU usage/freq, CPU/GPU temp, RAM/Swap. **Sudoless.** Ships a ready Prometheus+Grafana example. | LaunchAgent → **needs a login session (auto-login)** | Established, most-starred |
| **mactop** (`-p <port>`) | CPU/GPU/core usage, power, temps, thermal state, DRAM bandwidth. Also `--headless --format json` for run-once. | LaunchAgent (login session) | Established, single binary |
| macmon-prometheus-exporter (:9101) | P/E-core split, GPU power/usage/freq/temp, ANE, system power | wraps macmon | Single-author, unproven |
| mac-powermetrics-exporter (:9127) | CPU/GPU power (mW), per-core freq/temp, residency, vm_stat mem | **root LaunchDaemon → runs at boot, no login needed** | Immature (~3 commits) |

**Packaging nuance that matters for headless:** macmon/mactop install as **LaunchAgents** (need a logged-in session → the Mac needs auto-login enabled). powermetrics-based exporters run as a **root LaunchDaemon** (start at boot, no login). If you don't want to enable auto-login, the LaunchDaemon path is architecturally cleaner — but those exporters are the least mature. Trade-off to decide when we build the role.

### Suggested topology

Ansible role deploys the exporter + a LaunchDaemon/Agent plist per Mac; OpenObserve scrapes each Mac's `/metrics` (or a per-Mac Alloy/otel agent scrapes localhost and remote-writes). Fits the existing Ansible-managed monitoring pattern. If you want the full OS-metric set too, pair `node_exporter` (via Alloy `prometheus.exporter.unix`) with the Apple-silicon exporter — two collectors per Mac, since no single maintained exporter combines both.

## What was refuted (don't chase these)

- ❌ Ansible role wrapping `softwareupdate` for unattended OS installs (0-3). Volume-ownership wall.
- ❌ `node_exporter` thermal collector *errors* on Apple silicon / must be disabled (0-3). Not an established failure — but it still doesn't give you SoC GPU/ANE/thermal power regardless.
- ❌ Mosyle FREE = "full PREMIUM feature set" (1-2). Full *macOS MDM* is confirmed; the 30-device cap and reduced support are real limits.

## Open questions before an ADR / build

1. OpenObserve ingestion: scrape config vs remote-write, and central-scrape vs per-Mac agent — which fits our Ansible stack?
2. Concrete DDM unattended-update flow under macOS 27 for Mosyle FREE — can it be triggered/orchestrated alongside `make update`, or is it purely out-of-band MDM?
3. Secure-token/bootstrap-token provisioning on a fresh headless Mac — Infisical for the recovery secret? How to do first login without a GUI?
4. Auto-login (for macmon/mactop LaunchAgents) vs LaunchDaemon exporters — pick the packaging model.

## Key sources

- Apple — [secure token, bootstrap token, volume ownership](https://support.apple.com/guide/deployment/use-secure-and-bootstrap-tokens-dep24dbdcf9e/web) (primary)
- Apple — [device management updates / DDM](https://support.apple.com/guide/deployment/device-management-updates-depd638aa061) (primary)
- [osx-provisioner/collection](https://github.com/osx-provisioner/collection) (Ansible macOS roles)
- [vladkens/macmon](https://github.com/vladkens/macmon) · [metaspartan/mactop](https://github.com/metaspartan/mactop) (exporters, primary)
- [micromdm/nanomdm](https://github.com/micromdm/nanomdm) (OSS MDM)
- [Mosyle Business FREE announcement](https://www.businesswire.com/news/home/20210405005194/en/Mosyle-Launches-Mosyle-Business-FREE-to-Make-Apple-Mobile-Device-Management-More-Affordable-and-Accessible-to-All-Organizations)
