# ADR 0035 — P4a: Traefik ingress on one LB IP with a wildcard internal cert, the Infisical Kubernetes operator is the secret path, and homepage is the first Zot-templated ref

- **Status:** Accepted (approved 2026-08-23)
- **Amended:** ADR 0040 (P5a, 2026-08-25): Ingress hostnames are external-dns records in the flat service zone, not AdGuard rewrites; legacy names redirect via `kubernetes/traefik/legacy-redirect.yaml`. P5b (2026-08-25): the default TLS store's certificate is a Let's Encrypt wildcard from the `letsencrypt` ClusterIssuer, with a second `homelab-ca` Certificate (`legacy-tls`) in the store's `certificates` list for the legacy names.
- **Date:** 2026-08-23
- **Deciders:** operator + agent
- **Context source:** P4a brownfield gate, [docs/talos-p4a-homepage-plan.md](../talos-p4a-homepage-plan.md); closes the deferral in [ADR 0031](0031-a-three-node-talos-kubernetes-cluster-becomes-the-services-plane-and-the-bootstrap-tier-stays-on-proxmox.md); builds [ADR 0022](0022-container-images-pull-through-a-fleet-local-registry-via-templated-refs-the-registry-rebuilds-itself-from-upstream.md), [ADR 0034](0034-p3b-metallb-l2-on-a-reserved-vlan40-slice-zot-behind-an-internal-cert-manager-ca-arc-scale-sets-as-hostnetwork-dind-pods-pinned-to-one-node-and-a-cronjob-reaper.md)

## Context

P4 migrates the docker-LXC stacks onto the Talos cluster one at a time; homepage is first. The cluster has MetalLB, an internal CA and Zot but no HTTP ingress, and the only secret path is ARC's one-off `kubectl create secret` from `make`. ADR 0031 deferred the Kubernetes equivalent of the Infisical-agent-renders-env-files pattern to the first stack that needs it. homepage is config-only but its widgets read 17 keys from four Infisical folders, so the decision lands here. Every P4 stack after this one reuses all three pieces.

## Decision

- **Ingress: Traefik** via helm (`kubernetes/traefik/`), one MetalLB address at vlan40 offset **65**, apps publish standard `Ingress` resources. ingress-nginx is retired upstream; Traefik is maintained and adds Gateway API later without replacing the controller.
- **TLS: one wildcard `Certificate` `*.<domain_suffix>`** from `homelab-ca`, set as Traefik's default TLS store. App Ingresses carry no `tls:` stanza and no per-host Certificate. Hostnames are AdGuard rewrites → the ingress IP. When `homelab-ca` is swapped for Infisical PKI (ADR 0034's open gate) one Certificate re-issues.
- **Secret path: the Infisical Kubernetes operator** (`secrets-operator` chart, `kubernetes/infisical/`). Exactly one out-of-band secret exists in the cluster: `infisical-universal-auth` (client id/secret of the universal-auth identity in `bootstrap.sops.yml`), created by `make talos-infisical` — the Kubernetes twin of Ansible's Tier-1 bootstrap. Every runtime secret is declared as an `InfisicalSecret` CRD in the consuming component's tree: one per source folder, `creationPolicy: Orphan`, a `template.data` block that renames folder keys to the env names the workload expects, consumed via `envFrom`; `secrets.infisical.com/auto-reload: "true"` restarts the Deployment on rotation. The folder-ownership table is unchanged — consumers read from the source folder, never from copies. ARC's two one-off secrets are grandfathered until ARC is next touched.
- **Images: first ADR 0022 templated ref.** homepage runs `registry.<domain_suffix>/ghcr.io/gethomepage/homepage:latest`; the prefix is derived from `nodes.json` at deploy time, never written into a tracked manifest. Charts that expose a registry prefix as one value (Traefik, the Infisical operator) take it too; components deployed before Zot existed are left as they are.
- **homepage** is a Deployment + ConfigMap + Service + Ingress in `kubernetes/homepage/`; its config files are the role templates translated to `${VAR}` placeholders filled from `vms.yaml`/`nodes.json` by `deploy.sh`. No Caddy, no docker socket, no mDNS.
- **Retirement:** LXC 211 stopped + `onboot 0` (never destroyed, ADR 0028), state-removed and dropped from `vm-configs.tf`/`backup_jobs`; the `homepage` role, play, tag and agent template are deleted. Infisical `/homepage` stays (owned by nobody, read by the adguard playbooks and the k8s `InfisicalSecret`).

## Rejected alternatives

- **ingress-nginx** — upstream retired it in March 2026; starting a new platform on it means a forced swap later.
- **Gateway API (Envoy Gateway / Cilium)** — the cluster runs Flannel and nothing needs routes beyond host matching; `Ingress` is the boring object and Traefik serves Gateway API if that changes.
- **Per-host Certificates** — one resource per app for no isolation gain on a LAN CA; the wildcard also makes the PKI swap one re-issue.
- **External Secrets Operator with the Infisical provider** — a second abstraction (SecretStore + ExternalSecret) in front of the only secret backend this fleet will ever have; the Infisical operator does the same job with one CRD and is maintained by the same vendor.
- **Keep one-off `kubectl create secret` from `make`** — the P3b stopgap: no rotation, secrets depend on the workstation having sops, and every stack would grow its own `if ! kubectl get secret` block.
- **One recursive `InfisicalSecret` at `/`** — pulls every folder (VPS keys, PBS admin) into a namespace that needs four; violates least privilege for one fewer resource.
- **Infisical Agent sidecar in the pod** — the compose-era pattern; the operator is the same agent run once cluster-wide.
- **Carrying `homepage.local` mDNS into the cluster** — avahi in a pod is a hostNetwork hack; AdGuard already names the service for every client.

## Consequences

- `kubernetes/` gains `traefik/`, `infisical/`, `homepage/`; `make talos-ingress|talos-infisical|talos-homepage`. Offset 65 is the ingress IP; Zot keeps 64.
- CLAUDE.md Canonical pipelines: "runtime secrets reach a pod through an `InfisicalSecret` in the component's tree; the only `kubectl create secret` is `infisical-universal-auth`" — new cluster secrets must not add one-off create paths.
- P4b+ (openobserve, plex-services, mcp) inherit ingress + secret path; each becomes a `kubernetes/<stack>/` tree with its own `InfisicalSecret`s.
- The `homepage` Ansible role, play, tag, and `infisical_client` template are gone; `home.<zone>` and `homepage.<domain_suffix>` are AdGuard rewrites to the ingress IP (API-managed, since the AdGuard config template is initial-only).
- P10 item 2 (2026-08-25): the four *arr apps behind `authentik-forward-auth` run `authenticationMethod=external`, set by `kubernetes/plex-services/deploy.sh` through each app's `config/host` API on every deploy — the Ingress is the only login; the in-cluster Services answer unauthenticated and only pods reach them (MetalLB exposes Traefik alone). Bazarr has no proxy-trust mode and keeps its form.
- `homelab-ca` swap to Infisical PKI remains open (ADR 0034) — now gated on one Certificate + the node/workstation trust, not on per-app certs.
