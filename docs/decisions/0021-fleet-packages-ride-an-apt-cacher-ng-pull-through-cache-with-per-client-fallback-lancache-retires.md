# ADR 0021 — Fleet packages ride an apt-cacher-ng pull-through cache with per-client fallback; Lancache retires

- **Status:** Accepted
- **Date:** 2026-08-11
- **Deciders:** operator + agent
- **Context source:** flaky-apt-source open item in [docs/ms01-cluster-iac-plan.md](../ms01-cluster-iac-plan.md) (measurements 2026-08-04, rebuild-speed angle 2026-08-11); W4 dress-rehearsal evidence; kickoff homelab-aptcache-20260811

## Context

Cloud-init leaves every guest on `archive.ubuntu.com`, whose IPv4 path from here is erratic: three consecutive 6 MB range fetches measured 0 B/s / 4.5 MB/s / 0 B/s against 8.9 / 9.2 / 3.9 MB/s to `mirror.math.princeton.edu` (2026-08-04, from unifi). Guests are IPv4-only on mgmt, so they cannot fall back to Canonical's faster IPv6, and apt has no minimum-rate abort — a 19 KB/s transfer is indistinguishable from a hang, producing silent multi-minute `make update` stalls whenever a kernel is in the set.

The same WAN-pull cost dominates the rebuild flow: every guest's cloud-init apt phase and every node's `pveceph install` pulls independently, so a fleet rebuild (~3 nodes + ~15 guests) re-downloads the same package set a dozen-plus times over the flaky path. W4 dress rehearsal showed nested `pveceph install` across 3 nodes was the single slowest phase — and `download.proxmox.com` has no mirror-fallback option at all.

Separately, Lancache (VM 110, 4 cores / 4 GB / 500 GB NFS cache) is a retirement candidate: it was trialed for Windows Update caching, performed poorly, and stays only if an apt/PVE caching role earns its keep.

Hard constraint (re-litigated, settled — do not reopen): the cache must NOT be a hard bootstrap dependency of the rebuild that recreates it. Either the cache VM and its redirection come up before dependents, or first-boot apt tolerates cache-absent and falls back to the WAN.

## Decision

Retire Lancache. Stand up **apt-cacher-ng** as a small static-IP guest on the new cluster, fronting both `archive.ubuntu.com` (guest apt) and `download.proxmox.com` (node `pveceph install` / PVE no-subscription repo).

Clients reach it by explicit proxy configuration, never DNS interception: cloud-init (guests) and the `proxmox_host` role (nodes) install an `Acquire::http::Proxy-Auto-Detect` script that probes the cache and returns `DIRECT` when it is unreachable. First boot on a cold cutover therefore works with no cache present — apt probes, times out in seconds, and pulls straight from the WAN; once the cache guest is rebuilt, the same probe silently routes traffic back through it. No ordering requirement, no operator intervention.

The cache's upstream is a deb822-style backend list with a measured-fast mirror ahead of `archive.ubuntu.com`, so even cache misses avoid the flaky path. The cache directory is disposable derived state — every byte is re-fetchable — so the guest is pure ADR 0015 disposable-rootfs with no detached data volume.

## Rejected alternatives

- **Adapt Lancache — add apt/PVE domains to `cachedomains` + AdGuard rewrites (option a).** Three independent disqualifiers. (1) It structurally violates the bootstrap constraint: DNS interception has no per-client fallback — with the AdGuard rewrite live and the Lancache VM absent (exactly the cold-cutover state), every guest's first-boot apt connects to a dead IP and stalls fleet-wide; "fallback" would mean an operator flipping AdGuard rewrites mid-cutover. (2) Correctness risk: Lancache's nginx cache heuristics are tuned for immutable game-CDN objects; apt's volatile `InRelease`/index metadata served stale produces hash-sum-mismatch failures, the exact problem apt-aware caches exist to solve. (3) It deepens DNS-interception coupling on split-horizon AdGuard (ADR 0012 territory) to keep alive a 4-core / 4 GB / 500 GB service that already failed its original purpose.
- **deb822 multi-URI fast-mirror fallback only, no cache (option c).** Fixes the flaky Ubuntu path but cuts zero repeated pulls across ~18 rebuild-time downloads of the same set, and does nothing for `download.proxmox.com` — the slowest measured phase. Its useful half survives inside the decision as the cache's backend mirror list, not as per-guest sources.

## Consequences

- **Cold-cutover first-boot survival:** per-client `Proxy-Auto-Detect` with `DIRECT` fallback means the cache is an accelerator, never a dependency. A from-scratch rebuild works in any order; rebuilding the cache guest first merely makes the rest faster. This mechanism is the load-bearing half of the decision — any future change to explicit-proxy delivery must preserve it.
- **Lancache retires:** remove VM 110 from `terraform/vm-configs.tf` and the services play, delete `ansible/roles/lancache/`, and drop its NFS share and any AdGuard/homepage references. The `lancache` tag leaves `services.yml`.
- **Follow-on implementation (scoped here, built separately):** an `apt_cacher_ng` role + guest definition (static IP per ADR 0003, disposable rootfs per ADR 0015, pinned OS image per ADR 0016); the auto-detect proxy script delivered via cloud-init for guests and `proxmox_host` for nodes; backend mirror list configured in the cache from the measured-fast mirror set.
- **Accepted costs:** one new small service to run and monitor (Uptime Kuma reachability monitor per ADR 0011); cache misses on volatile index files still touch the WAN by design.
- **Scope: cache everything (operator, 2026-08-11).** Plain-HTTP repos need no registration — acng in proxy mode caches any package-shaped request passing through, so the two HTTP custom sources (`download.proxmox.com` pve/pbs + pbs-client) cache automatically. The four HTTPS repos — `repos.influxdata.com` (telegraf, fleet-wide), `artifacts-cli.infisical.com` (infisical CLI, fleet-wide; its Cloudsmith setup script writes an `https://` list that must be rewritten), `nvidia.github.io` (docker VM), `repo.plex.tv` (plex VM) — are cached via explicit remap: guest source flips to `http://`, an acng `Remap-*` line per host pins the `https://` backend. GPG signing keeps the trust model; DIRECT fallback keeps working (verified 2026-08-11: all four answer plain HTTP with a 301→https that apt ≥1.5 follows, except repo.plex.tv which serves 200 directly). Explicit remaps, not reliance on acng following the 301s itself — redirect-following is version-dependent and a bounced redirect degrades to silently-uncached CONNECT traffic. Keep a minimal `PassThroughPattern` allowlisting those hosts as a safety net so an unconverted `https://` source still works uncached instead of failing (acng denies CONNECT by default); never the `HTTPS///` pseudo-host source forms (`http://HTTPS///host/...` with the cache as proxy, or `http://cache:3142/HTTPS///host/...` hardcoded) — both make the source line meaningless without an acng proxy interpreting it (the pseudo-host `HTTPS` doesn't resolve), so DIRECT fallback dies for that source and the cache becomes a dependency again.
- **Forbidden:** DNS-rewrite redirection of public repo hostnames to a fleet-internal cache — it recreates the bootstrap trap this ADR closes.
