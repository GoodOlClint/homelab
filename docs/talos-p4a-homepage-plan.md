# P4a change plan — ingress controller, Infisical→k8s secret path, homepage on the cluster, retire LXC 211

Status: **Built 2026-08-23**. Deviations: the Infisical operator chart emits no `metadata.namespace`, so `helm_apply` now passes `-n` to `kubectl apply`; Traefik's first template pass races its own CRDs (TLSStore), so `deploy.sh` applies twice; the readiness probe must send a `Host:` header because homepage validates `HOMEPAGE_ALLOWED_HOSTS`; `projectId` is accepted by the CRD, so no slug lookup. PVE widget 401s: `monitoring@pve` was never recreated on the new cluster (pre-existing, `monitoring_users` role). Decision record: [ADR 0035](decisions/0035-p4a-traefik-ingress-on-one-lb-ip-with-a-wildcard-internal-cert-the-infisical-kubernetes-operator-is-the-secret-path-and-homepage-is-the-first-zot-templated-ref.md). Follows [P3b](talos-p3b-plan.md) / [ADR 0034](decisions/0034-p3b-metallb-l2-on-a-reserved-vlan40-slice-zot-behind-an-internal-cert-manager-ca-arc-scale-sets-as-hostnetwork-dind-pods-pinned-to-one-node-and-a-cronjob-reaper.md); closes the [ADR 0031](decisions/0031-a-three-node-talos-kubernetes-cluster-becomes-the-services-plane-and-the-bootstrap-tier-stays-on-proxmox.md) "Infisical secret path for k8s" deferral; first consumer of [ADR 0022](decisions/0022-container-images-pull-through-a-fleet-local-registry-via-templated-refs-the-registry-rebuilds-itself-from-upstream.md)'s templated refs.

## Existing state (mapped 2026-08-23)

- Cluster: 3 CPs Ready, MetalLB pool offsets 64–79 (`.64` = Zot), cert-manager `homelab-ca` ClusterIssuer (self-signed placeholder for Infisical PKI), Zot `registry.<domain_suffix>` proxying `docker.io`/`ghcr.io`/`quay.io`, nodes trust the CA. No ingress controller. Deploy pattern: `kubernetes/<component>/deploy.sh` sourcing `lib.sh` (`helm_apply`, `subnet_ip`, `inf_get`, `ns`). Secrets so far: one-off `kubectl create secret` from `make` (ARC only).
- homepage = LXC 211 (vlan40 offset 111): Caddy (`tls internal`, `home.<vlan40 zone>` + `homepage.local`) → homepage:3000; config from five Jinja templates (`services/settings/widgets/bookmarks/docker.yaml`) whose only inputs are fleet `service_ip`s from `vms.yaml`, `network_data.dns_server.dns_ipv4`, `proxmox_host`, `synology_host`, `openobserve_listen_port`, `pbs_monitoring_user`; 17 `HOMEPAGE_VAR_*` env vars rendered by the Infisical agent from `/plex-services` (8 API keys), `/plex` (`plex_token`), `/monitoring` (`grafana_admin_password`, `proxmox_token_value`, `pbs_api_token`), `/homepage` (adguard/unifi/authentik/portainer). Docker socket mounted but discovery unused. Also on the guest: avahi (mDNS `homepage.local`), portainer agent, pbs_client, telegraf, rsyslog.
- References to retire: `vm-configs.tf` entry, `backup_jobs.nightly-fleet` vmid `211`, `services.yml` play + `homepage` tag, `docker-config.yml` homepage section, `update-all.yml` host + path, `refresh-identity.yml` host, `infrastructure.yml` `portainer_agent_hosts`, `adguard` defaults (`adguard_rewrite_vms`, `home` alias), the role, `infisical_client/templates/secrets/homepage.env.tpl.j2`.
- `/homepage` Infisical folder stays: `adguard_*` is read by `adguard-pause.yml`/`adguard-rewrite.yml`.
- Workstation: `helm`, `kubectl`, `jq`, `envsubst`, `.venv` python with pyyaml; no `yq`.

## Decisions (ADR 0035)

1. **Ingress controller = Traefik** (helm chart `traefik/traefik`, namespace `traefik`), `Service` type LoadBalancer on vlan40 offset **65**, plain `networking.k8s.io/v1 Ingress` resources (Gateway API not enabled). ingress-nginx is retired upstream (best-effort maintenance ended March 2026); Traefik is the boring maintained choice and speaks Gateway API later without a swap.
2. **One wildcard Certificate** `*.<domain_suffix>` from `homelab-ca` in the `traefik` namespace, installed as Traefik's **default TLS store** — per-app Ingresses carry no `tls:` block and no Certificate. Hostnames are AdGuard rewrites to the ingress IP (`make adguard-rewrite`, same as Zot). HTTP→HTTPS redirect on.
3. **Infisical→k8s secret path = the Infisical Kubernetes operator** (`secrets-operator` chart, namespace `infisical-operator`). One bootstrap k8s Secret `infisical-universal-auth` (the existing universal-auth machine identity from `bootstrap.sops.yml`, created once by `make`) — the k8s twin of Ansible's Tier-1 bootstrap — and everything else as `InfisicalSecret` CRDs: one per Infisical folder, `creationPolicy: Orphan`, `template.data` mapping folder keys to the env-var names the consumer expects. Pods consume with `envFrom`. Rotation propagates without a redeploy (the operator's managed secret is re-synced, and `secrets.infisical.com/auto-reload: "true"` rolls the Deployment). ARC's one-off secrets stay as they are until ARC's next touch.
4. **homepage** = `kubernetes/homepage/`: Deployment (1 replica, image `registry.<domain_suffix>/ghcr.io/gethomepage/homepage:latest` — the **first ADR 0022 templated ref**, prefix from `nodes.json` at deploy time), ConfigMap from the five config files **translated** from the role templates (`${VAR}` placeholders filled by `envsubst` from `vms.yaml` + `nodes.json` in `deploy.sh` — no Ansible, no private IPs tracked), four `InfisicalSecret`s (`/homepage`, `/plex-services`, `/plex`, `/monitoring`), Service, Ingress `homepage.<domain_suffix>`. `HOMEPAGE_ALLOWED_HOSTS` = the ingress hostnames. No docker socket, no Caddy, no mDNS (`homepage.local` goes; AdGuard names cover every client). Widgets keep targeting fleet guests by `service_ip`; Portainer/AdGuard/PVE/PBS/UniFi widgets unchanged.
5. **Component images through Zot** where the chart exposes a registry prefix as one value (Traefik `image.registry`, Infisical operator `controllerManager.manager.image.repository`); MetalLB/cert-manager/ARC stay as deployed.
6. **Retire 211:** `pct stop 211` + `onboot 0` (never destroy, ADR 0028); `terraform state rm` the container + its cloud-init/file resources, drop from `vm-configs.tf` + `backup_jobs`; delete the role, the `services.yml` play + `homepage` tag, the agent template, and every reference in the list above; `home.<zone>` alias repointed at the ingress IP via `make adguard-rewrite` (the adguard config template is initial-only). Only after the DoD curl passes.
7. **Not in scope:** the Infisical PKI swap for `homelab-ca` (its own gate before ref-templating; the wildcard Certificate makes it a one-resource re-issue), Harbor/S3, authentik, Uptime Kuma status-page widget.

## Changes

| # | Change | Files |
|---|---|---|
| 1 | `kubernetes/traefik/` — `deploy.sh` (helm template traefik; LB IP via `subnet_ip 65`), `values.yaml`, `certificate.yaml` (wildcard), `tlsstore.yaml` (default store) | `kubernetes/traefik/**` |
| 2 | `kubernetes/infisical/` — `deploy.sh` (helm template secrets-operator; bootstrap secret from `bootstrap.sops.yml` if absent), `values.yaml` | `kubernetes/infisical/**` |
| 3 | `kubernetes/homepage/` — `deploy.sh`, `config/{services,settings,widgets,bookmarks,docker}.yaml` with `${…}` placeholders, `secrets.yaml` (4 InfisicalSecrets), `app.yaml` (Deployment/Service/Ingress) | `kubernetes/homepage/**` |
| 4 | `lib.sh`: `inv_ip <host>` (service_ip from `vms.yaml`), `inf_project_slug` | `kubernetes/lib.sh` |
| 5 | Makefile: `talos-ingress`, `talos-infisical`, `talos-homepage` | `Makefile` |
| 6 | Retire 211 (decision 6) | `terraform/vm-configs.tf`, `terraform/vars.auto.tfvars`, `ansible/**` |
| 7 | Docs: plan row, CLAUDE.md (pipelines, make targets, folder table, tags, `secrets` path rule), README | `docs/**`, `CLAUDE.md`, `README.md` |

## Sequencing

1. Traefik (`make talos-ingress`) → wildcard cert Ready → `curl -k https://<lb65>/` returns 404 from Traefik with the `homelab-ca` chain.
2. Infisical operator (`make talos-infisical`) → a throwaway `InfisicalSecret` syncs (`status.conditions` Ready) → deleted.
3. homepage (`make talos-homepage`) → pod Running with the Zot ref, 4 managed Secrets populated, Ingress admitted, AdGuard rewrite set → DoD curl + widget check (Sonarr/Radarr widget shows queue counts = `/plex-services` key in use).
4. Retire 211 + cleanup, `make plan` + `make talos-plan` clean.
5. Docs + memory, small commits per row.

## Test bar / Definition of Done

- `curl https://homepage.<domain_suffix>/ --cacert kubernetes/.secrets/homelab-ca.crt` from the workstation → 200 + homepage HTML via the Traefik LB IP.
- `kubectl -n homepage describe pod` shows `registry.<domain_suffix>/ghcr.io/gethomepage/homepage`; Zot `/v2/_catalog` lists `ghcr.io/gethomepage/homepage`.
- `kubectl -n homepage get infisicalsecret` → all 4 Ready; the homepage UI renders a widget populated from an Infisical-sourced key (Sonarr).
- `pct status 211` = stopped, `onboot: 0`; 211 absent from `vm-configs.tf`, `vms.yaml`, backup job; second `make plan` and `make talos-plan` show no homepage/ingress changes.
- Rollback: 211 is intact — `pct start 211` + re-point the AdGuard rewrites.

## Risks

- Traefik default TLS store requires the cert secret in Traefik's namespace — the Certificate lives there; apps elsewhere just omit `tls:`.
- The operator needs the Infisical **project slug** (not id); `deploy.sh` resolves it through the API with the bootstrap identity.
- Template `data` in `InfisicalSecret` is Go-templated per key: a key missing upstream renders empty rather than failing — same behavior as the agent's `if eq .Key` blocks today.
- Widgets reach vlan30 (PBS) and vlan10 (Portainer on `control`) from pod egress = node vlan40 address; the LXC had the same source VLAN, so pfSense rules are unchanged.
