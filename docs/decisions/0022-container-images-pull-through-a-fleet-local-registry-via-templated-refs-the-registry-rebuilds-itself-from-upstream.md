# ADR 0022 — Container images pull through a fleet-local registry via templated refs; the registry rebuilds itself from upstream

- **Status:** Accepted (architecture; registry product provisionally Zot — Harbor evaluation open, see Decision)
- **Date:** 2026-08-11
- **Deciders:** operator + agent
- **Context source:** fleet caching review in the ADR 0021 session (2026-08-11); [ADR 0021](0021-fleet-packages-ride-an-apt-cacher-ng-pull-through-cache-with-per-client-fallback-lancache-retires.md) settled apt; this ADR settles container images

## Context

The fleet's compose templates reference ~90 container images: 56 from docker.io, 32 from ghcr.io, 2 from quay.io. A fleet rebuild pulls all of them per guest behind one NAT IP, and Docker Hub's unauthenticated per-IP rate limits are shaped exactly to hurt that. Images are the largest uncached download class left after ADR 0021.

The transparent route is closed: dockerd's `registry-mirrors` applies to Docker Hub only (verified against current docs and community reports 2026-08-11), so ghcr.io/quay.io cannot be mirrored without either a containerd-native runtime (Talos-style per-registry mirrors — not what the fleet runs) or rewriting image refs. Rewriting refs on a live fleet was rejected repeatedly in the ADR 0021 discussion as hardcoding the cache into config. The MS-01 rebuild changes that calculus: every compose template is being reworked anyway, so ref templating is WP4-timed work, not surgery.

The operator also wants a private registry for locally built test images — a capability, not just a cache.

ADR 0021's bootstrap constraint has two satisfying branches: per-client fallback, or the cache comes up before dependents. Apt took the fallback branch (free via `Proxy-Auto-Detect`). No such per-registry fallback exists for image refs pointed at a local registry — a ref names its registry, so this decision must take the ordering branch and make it safe.

## Decision

All fleet compose `image:` refs route through a fleet-local pull-through registry, via a **templated registry prefix** — a single variable, not hardcoded hostnames — with one proxy namespace per upstream (docker.io, ghcr.io, quay.io). Private/test images get their own namespace on the same registry.

**Bootstrap rule (load-bearing):** the registry guest's own compose refs point at upstream registries directly, so it can always rebuild itself from the WAN with nothing local existing; it is phase-0 in the fleet rebuild order, before any guest that pulls through it. This is ADR 0021's ordering branch, made safe by self-hosting-from-upstream. Runtime exposure is pulls only — running containers and `restart: unless-stopped` use local images, so a registry outage degrades updates, not uptime.

**Registry product: Zot is recommended provisionally** — single small binary, per-upstream on-demand sync (pull-through), authenticated private hosting, minimal UI. **Harbor is NOT rejected**: the operator is evaluating whether its web UI, Trivy scanning, and retention policies are worth ~10 standing containers (postgres, redis, core, trivy, …). Because refs are templated, the product choice is config, not architecture — swapping Zot for Harbor later changes the prefix variable and the registry guest's stack, nothing fleet-wide.

Registry TLS rides a real certificate via the existing Cloudflare DNS-01 pattern (`plex_certificate` model) — docker clients demand HTTPS, and a trusted cert avoids fleet-wide `insecure-registries` daemon.json surgery.

## Rejected alternatives

- **dockerd `registry-mirrors` alone (docker.io-only mirror, ghcr/quay direct).** The pre-rebuild recommendation, obsoleted by the rebuild: it leaves 34 of 90 refs uncached and provides no private hosting. Its one advantage — transparent fallback to Hub — matters less once the ordering branch is made safe.
- **Per-upstream `registry:2` instances + templated refs.** Caches everything but private hosting is crude (no auth story, no UI), and running 3–4 registry containers to avoid one better-suited binary is complexity without capability.
- **Hardcoded registry hostnames in compose templates.** Kills the product-swap freedom and couples every template to one host. The template variable costs nothing at rebuild time.
- **Migrating guests to Podman for `registries.conf` per-registry mirrors-with-fallback.** Genuine transparent fallback for all upstreams, but swapping the container runtime across every compose stack to improve image caching is out of proportion.

*Not rejected:* **Harbor** — under active operator evaluation as the registry product; see Decision.

## Consequences

- **WP4 template work:** ~90 `image:` refs across ~15 compose templates move to the registry-prefix variable. Mechanical, riding the rebuild's existing template rework.
- **Rebuild ordering gains a rule:** registry guest is phase-0 (with the ADR 0021 cache guest); its self-hosting-from-upstream property must be preserved — never template the registry guest's own refs.
- **Durable-state split:** proxy-cache contents are disposable (re-fetchable, plain rootfs); **private images are durable state** and ride an ADR 0015 detached data volume. The registry guest is the first fleet member needing both classes at once.
- **A TLS cert + DNS name for the registry** via the existing Cloudflare DNS-01 pattern; AdGuard serves the internal name (an ordinary internal-service record, not repo-hostname interception — ADR 0021's DNS-rewrite prohibition is untouched).
- **Monitoring:** Uptime Kuma reachability monitor per ADR 0011.
- **Until this lands, images stay uncached** — ADR 0021's apt cache ships independently and first.
- **Open item carried:** operator research on Zot vs Harbor; the ADR is amended with the final product pick when made. The research must also pick the **blob storage backend** — proxy-cache blobs will reach hundreds of GB, so they belong on NAS capacity, not local/Ceph NVMe: either the registry's S3 driver against a NAS-backed object store (Garage or SeaweedFS — **never MinIO: upstream archived Feb 2026, unpatched; the existing idle minio VM 112 rides that dead image and is a retirement candidate unless this decision revives its slot**) or the plain filesystem driver on an ADR 0017 host bind mount if the registry lands as an LXC. Private-image durability (ADR 0015 volume) is unchanged either way. Research note (operator, 2026-08-11): also evaluate running the object store **natively on the Synology** — a community DSM package (SynoCommunity et al.) or a Container Manager deployment of Garage/SeaweedFS on a native volume — which would make S3 one more protocol the NAS itself serves alongside NFS/SMB/iSCSI, with no gateway VM and no NFS-under-object-store sandwich; DSM has no first-party S3 server (a recurring community feature request), so this is package-hunting, and the finding should name the package/image, its maintenance status, and whether DSM's resource limits handle registry-blob traffic.
