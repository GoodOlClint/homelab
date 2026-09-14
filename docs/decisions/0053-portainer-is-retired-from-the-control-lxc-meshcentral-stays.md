# ADR 0053 — Portainer is retired from the control LXC; MeshCentral stays

- **Status:** Accepted
- **Date:** 2026-09-13
- **Deciders:** operator + agent
- **Context source:** the authentik SSO cleanup session of 2026-09-13 (the Portainer tile resolved, then showed four environments all `down`)

## Context

[ADR 0030](0030-three-management-planes-vlan10-out-of-band-vlan30-hypervisor-with-pdm-pbs-apt-cache-pxe-vlan40-services.md) put a Portainer server on the `control` LXC as half of the out-of-band management plane, at a time when most fleet services were docker-compose stacks on their own guests. Portainer's four registered environments were agent endpoints on VMs 203 (openobserve), 204 (docker), 206 (plex-services) and 211 (homepage).

All four of those guests were retired when their stacks moved to the Talos cluster over P4a–P4d ([ADR 0035](0035-p4a-traefik-ingress-on-one-lb-ip-with-a-wildcard-internal-cert-the-infisical-kubernetes-operator-is-the-secret-path-and-homepage-is-the-first-zot-templated-ref.md) through [ADR 0038](0038-p4d-the-games-host-moves-to-the-cluster-valheim-on-a-metallb-udp-lb-with-local-policy-the-playfab-status-sidecar-keyed-by-server-name-in-the-same-pod-kiwix-zims-via-an-nfs-pv-meshcentral-stays-on-control.md)). Nothing ran a Portainer agent afterwards, `portainer_agent_hosts` was left at `[]`, and the `control` role only ever added environments — never pruned — so four dead registrations survived the migration and the UI reported them as down. Portainer had no local environment either, so with the four gone it would manage nothing at all.

The remaining compose stacks in the fleet (authentik, infisical, plex, llm, apt-cache, control itself) are each converged by their own Ansible role, and the cluster half has Headlamp. Keeping Portainer means either accepting a UI that manages nothing or building a `portainer_agent` role to re-deploy agents onto the bootstrap-tier guests — new surface for a capability Ansible already covers.

Portainer also carried real cost: an OIDC provider and application in the internal authentik realm, a client secret in `/authentik`, a generated admin password in `/control`, an API key in `/homepage` for a dashboard widget, an entry in the Infisical agent template, and a role task block large enough to need its own idempotency reasoning. Portainer CE cannot map a group claim to a role, so SSO there also needed an explicit username-to-administrator promotion step that no other consumer requires.

## Decision

Portainer is removed from the fleet. The `control` LXC runs MeshCentral only, and ADR 0030's description of that guest is amended accordingly.

Every artifact that existed to serve Portainer goes with it: the compose service and its state directory, the role's task block and variables, the authentik OIDC provider and application, the Infisical agent template branch, the homepage tile and widget, the telegraf probe target, and the secrets `/authentik/portainer_oidc_client_secret`, `/control/portainer_admin_password` and `/homepage/portainer_api_key`.

Container management on the bootstrap tier is the guest's own Ansible role. Container management on the services plane is Headlamp.

## Rejected alternatives

**Prune the dead environments and keep Portainer with a local endpoint.** Registering control's own docker socket would have given Portainer exactly one environment: the two-container stack it is itself half of. The tile would load and show almost nothing, and the SSO, secret and role surface would all remain to serve it.

**Build a `portainer_agent` role and re-point Portainer at the remaining compose guests.** This is the only option that gives Portainer a job again, and it is the wrong direction: it adds an agent, a port and a trust path to every bootstrap-tier guest so that a UI can do what `make ansible <guest>` already does declaratively. The set of compose guests is shrinking, not growing.

**Add a prune step and leave the decision for later.** Making the role converge in both directions is correct in the abstract, but writing deletion logic for a component about to be deleted is work with a known expiry date.

## Consequences

- ADR 0030's `control` guest is MeshCentral only. The VM's data volume sizing comment in `terraform/vm-configs.tf` no longer counts Portainer state; the volume is not resized, since shrinking it would cost a rebuild for no benefit.
- The homepage dashboard loses its Portainer tile and its container-count widget. No replacement is added — Headlamp covers the cluster and the fleet guests are role-converged.
- `/homepage/portainer_api_key` was an operator-regenerated credential after every control rebuild ([infisical-external-credentials.md](../infisical-external-credentials.md)); that recurring hand step is gone.
- MeshCentral becomes the sole reason the `control` guest exists. If MeshCentral is ever retired too, the guest goes with it rather than being kept for a second tenant.
- The `/control` Infisical folder now holds only `pdm_root_password`. It is not merged into another folder — a folder per owner stays the convention.
- Nothing in the removal touches MeshCentral's data. Device groups and AMT node records live in `meshcentral.db` on the guest and are unaffected.
