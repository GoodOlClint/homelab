# Ingress policy — a declared exposure mode per service

Status: **plan, awaiting operator approval** (brownfield gate, 2026-08-29)
Motivating need: the forthcoming **Case Project** guests must be reachable from the internet for remote testing, on `<name>.<service domain>`, with publicly-trusted TLS.

## 1. What already exists

The four modes are not four machineries. Three of them already share one listener, and the survey below is what the code says today, not what the plan proposes.

| Mode | Public entry point | State |
|---|---|---|
| `none` | Traefik LB (services offset 65), LAN-only, LE wildcard default TLS store, optional `authentik-forward-auth` | Fully built (ADR 0035, 0040 P5b) |
| `vps` | Cloudflare A/AAAA → VPS reserved IP → `vps_nftables` DNAT :443 → pfSense `WG_VPS` → **the same Traefik LB** | **Fully built** — Jellyfin rides it (ADR 0040 P5d) |
| `tunnel` | `cloudflared` pod in `plex-services` (token auth) → in-cluster Service DNS | Pod runs; **routes are Cloudflare dashboard hand steps**, not declarative |
| `direct` | — | **Nothing.** pfSense has no API in this repo (`terraform/modules/network/pfsense.tf.placeholder`) |

Two facts that delete work packages outright:

- **`auth.<service domain>` already serves a public Let's Encrypt certificate.** Verified live on 2026-08-29: `issuer=C=US, O=Let's Encrypt, CN=YR1`, `subject=CN=*.<service domain>`, valid to 23 Nov 2026. It inherits `wildcard-tls` as Traefik's default TLS store. **No cert work is required for `auth`** — the actual gap there is reachability, addressed in WP4.
- **`none` and `vps` differ by exactly one DNS record.** Same listener, same certificate, same middleware chain. Anything already published as a cluster `Ingress` becomes internet-reachable by pointing a public record at the VPS reserved IP. No new proxy, no new certificate, no new firewall rule (:443 is already open on both the Vultr group and the `WG_VPS` NAT row).

There is also a precedent for the shape the Case VMs will take: **Plex already terminates its own Let's Encrypt TLS on a distinct port over the VPS relay** (`plex_certificate` role, probed at `https://plex.<media domain>:32400/identity`). The Case VMs are that pattern, not a new one.

## 2. Decisions taken at the gate (operator, 2026-08-29)

1. **Publish the internal authentik realm.** `auth.<service domain>` becomes internet-reachable.
2. **Each Case VM terminates its own TLS.** No Traefik `Service`-without-selector shim.
3. **Build `direct`.** The pfSense NAT row is a documented operator hand step.
4. **Retrofit existing exposures** (plex, jellyfin, seerr, tautulli, valheim) into the declared policy.

### Decision 1 publishes the internal realm — the blast radius is narrower than it first looks

ADR 0040 split the realms *by audience*: `auth.<service domain>` internal/LAN-only, `auth.<media domain>` external. Decision 1 reverses that half, and the first draft of this plan overstated the consequence. The correcting argument (operator, 2026-08-29):

**Publishing the IdP does not publish its relying parties.** pfSense, PVE, PBS, PDM, Portainer, MeshCentral, Headlamp, Grafana and Zot all sit behind a LAN-only Traefik. An attacker who reaches the login page and even succeeds holds a session for services they cannot route to. Network isolation is doing the real work, and it is unchanged.

Three risks survive that argument and are the actual scope of the mitigation:

1. **authentik becomes internet-facing attack surface in its own right.** An authentication bypass or RCE in the IdP is a beachhead *inside the cluster*, in a namespace holding the identity Postgres. This is independent of whether any relying party is exposed, and it is the reason the realm stays patched on a short leash.
2. **Credential takeover is durable.** A brute-forced account buys nothing reachable today, but it stays valid — and cashes in the moment the attacker reaches the LAN by any other route (guest wifi, a compromised device, a later exposure).
3. **The "no exposed relying parties" premise expires by design.** The Case VMs are internet-exposed *and* authenticate against this realm — that is the whole motivation. Once they land, fleet-admin accounts and external-tester accounts share one realm, and **account separation replaces network isolation as the control that matters.**

Mitigations, scoped to those three and nothing more:

- **MFA enforced on the admin-bound groups** (`authentik Admins`, `pfsense-admins`) via an authentication-flow stage in `blueprint-internal.yaml`. This is the one that covers all three risks, and the one place the plan refuses to be lazy.
- **Case testers land in their own group, never in an admin group**, and the Case application binding is group-gated the way `pfsense-admins` already is. This is risk 3's control.
- **Break-glass local accounts stay** in pfSense's auth-server order (already ADR 0043 policy), so a realm outage never locks the firewall.
- **Rate limiting at the VPS edge**, reusing the per-source meter `vps_nftables` already implements for Plex.
- **`redirect_uris` stay anchored to `${DOMAIN_RE}`** (the 2026-08-28 fix). An unanchored pattern was LAN-exploitable before and is internet-exploitable after.

GeoIP allowlisting is available (`nft_geoip_enabled`) but **not** recommended here — remote testers are the point, and their locations are not known in advance.

### Identity topology — one operator account, via federation (revision to Decision 1)

Operator constraint (2026-08-29): *"I just don't want multiple accounts if I can help it."*

Today that is already two — an internal account for fleet admin, an external one for media. The first draft of Decision 1 would have kept it at two and put **tester accounts in the admin realm**. Federation does better: it takes the operator to **one** account and keeps testers out of the admin realm entirely.

**Recommended topology:**

- **Internal realm = the operator's identity, and only the operator's.** Fleet admin accounts, MFA-enforced. It is the upstream IdP and the single source of truth for who the operator is.
- **External realm = every other human** — family today, Case testers tomorrow — plus an **OIDC/SAML source pointing at the internal realm**, so the operator signs in there as "continue with `<internal>`" rather than holding a second credential.
- **Case VMs authenticate against the external realm**, which is already public-facing. They never touch the admin realm.

What this changes versus the first draft:

| | First draft | With federation |
|---|---|---|
| Operator accounts | 2 (unchanged) | **1** |
| Tester accounts live in | internal realm, beside admins | external realm only |
| ADR 0040's audience split | reversed | **preserved** |
| §2 risk 3 (admins + testers share a realm) | mitigated by group-gating | **does not arise** |

**Decision 1 still stands, and is still required** — federation is a browser redirect, so the internal realm's authorization endpoint must be publicly reachable for the operator to log in from off-net. What changes is that its exposure now serves a much narrower purpose: operator login and federation, not hosting a tester directory. That makes ADR 0046 a smaller decision than first drafted.

Two consequences to design around:

- **Branding/domain.** Redirecting a business tester to `auth.<media domain>` to log in is confusing. authentik **brands** let one instance serve a second hostname (e.g. `auth-case.<service domain>`) with its own theming over the same user directory, so this needs no third realm. Exact blueprint model names are a build-time detail to confirm against the 2026.8 schema.
- **Federation makes external depend on internal for operator login.** If the internal realm is down, the operator cannot federate in; family and tester **local** accounts are unaffected. Acceptable, but it means the operator keeps a break-glass path into the external realm — the same reasoning ADR 0043 already applies to pfSense.

This supersedes the "expose the internal realm so Case VMs can use it" reading of Decision 1. It is written in as the recommendation rather than re-asked, because federation was not on the table when Decision 1 was taken and the plan is itself the approval gate — reject it at review and the first-draft shape still works.

### Decision 2 creates a port collision — solved by a second VPS, not by touching pfSense

`WG_VPS:443` is already claimed by Traefik. If each Case VM terminates its own TLS, a second backend cannot also have `:443` on that path. One public IP, one port, N hostnames, N certificates.

The first draft proposed HAProxy SNI passthrough **on pfSense**. That is now rejected: it puts a new load-bearing component on a hand-managed appliance with no API in this repo, and one with existing scar tissue around MTU overrides and stale pf states. The operator's counter-proposal — **generalize the VPS role to multiple ingress VPSs** — is adopted instead, and it is better for a reason worth recording:

**A second VPS dissolves the collision without touching the firewall at all.** Its own reserved IP means its own `:443`. pfSense stays a dumb pass-through.

One objection was raised against any proxy-based option and then **disproved by reading the code**: that a proxy would cost the real client IP. It would not, because `vps_nftables` already ends with `oifname wg0 masquerade` — every relayed connection is SNAT'd today, so backends already see the VPS tunnel address, not the visitor. (Per-source rate limiting still works because the meter runs in `forward`, ahead of postrouting.) Client IP is not a differentiator between any of these options; nothing is being given up.

What a second VPS buys beyond the collision fix:

- **Trust-boundary isolation.** External business testers share no entry point with family media. Abuse complaints, blacklisting or a DDoS against the Case edge leave Plex and Jellyfin untouched.
- **Independent lifecycle.** `make vps-rebuild` today takes down media, games and mobile WireGuard together. A separate Case edge can be rebuilt freely — exactly what a test environment needs.
- **Independent placement.** A VPS near the testers cuts their latency without moving media.

What it costs, stated plainly:

- **~$6/month per VPS, recurring.**
- **Each new VPS is a pfSense hand step** — a WireGuard peer, interface assignment, MTU override in *both* the tunnel config and the interface override (ADR 0013), and rules. pfSense is hand-managed per ADR 0005 and this does not change that.
- **Per-path MTU must be measured, not copied.** ADR 0013 is explicit that the number is measured per address family; a second tunnel to a different region is a different path.
- N× hardening and patching surface.

That cost profile sets the governing rule, which belongs in the ADR:

> **A new ingress VPS is justified by a trust boundary, not by a port collision.**

Small N — `media` (the existing relay, untouched) and `case` (new) — not one per service. Within a single VPS, several own-TLS backends on `:443` are handled by an **SNI-routing TCP proxy on that VPS**, which is Ansible-managed like the rest of the role and needs no hand step at all. That is where the SNI mechanism lives if it is ever needed; it never goes on pfSense.

## 3. The design

One tracked map in Terraform is the single home for public exposure, keyed by bare label with the domain interpolated (never literal — the service domain is a gitignored binding):

```hcl
# terraform/ingress.tf
#   mode: none | tunnel | vps | direct
#   tls:  traefik (inherits the wildcard) | self (backend terminates)
ingress = {
  jellyfin = { mode = "vps",    tls = "traefik", zone = "media"   }
  plex     = { mode = "vps",    tls = "self",    zone = "media", port = 32400 }
  seerr    = { mode = "tunnel", tls = "traefik", zone = "media"   }
  auth     = { mode = "vps",    tls = "traefik", zone = "service" }
  case-a   = { mode = "direct", tls = "self",    zone = "service", target = "case-a" }
}
```

What the mode drives, and nothing more:

| Mode | Terraform emits | Hand step |
|---|---|---|
| `none` | nothing public | — |
| `vps` | Cloudflare A + AAAA → VPS reserved IP; Vultr firewall rule if a new port | — (`:443` row exists) |
| `tunnel` | Cloudflare CNAME → tunnel target | dashboard route (unchanged) |
| `direct` | Cloudflare A → WAN (DDNS-owned, looked up at run time, never a static binding) | pfSense WAN NAT row |

`tls = "self"` additionally makes the guest run a **public-CA** certbot lane. This is a new variant of `cert_client`, not a change to it: the existing role is hardwired to Infisical's private directory over `dns-rfc2136` against BIND. A publicly-trusted certificate must be validated at the **public** authoritative nameserver — Cloudflare — so the variant is Let's Encrypt + `python3-certbot-dns-cloudflare` reading `/infrastructure/cloudflare_dns_api_token`, the same credential cert-manager already uses.

The `ingress` attribute rides the guest definition in `vm-configs.tf` for VM-hosted services, and flows into `vms.yaml` through the existing `ansible_inventory_yaml` output so the certificate role knows to run. Cluster-hosted services take an entry directly. One map, one place.

## 4. Generalizing the VPS role

The Ansible side is already parameterized — `vps_wireguard`, `vps_nftables` and `vps_hardening` all read from vars. What is singular is narrow and mechanical:

| Singular today | Becomes |
|---|---|
| `vultr_instance.vps`, `vultr_reserved_ip.vps`, `vultr_firewall_group.vps` + 9 rule resources | `for_each` over a `vps_instances` map; rules generated from each instance's forward list |
| `ansible/inventory/vps.yaml` — one host `vps` | a `vps` **group** with one host per instance |
| `vps_wg_tunnel` — one dict in `all.yml` | a map keyed by instance name (tunnel subnet allocated per VPS) |
| Infisical `/vps/vps_wg_private_key` — one key | one key per instance (`/vps/<name>_wg_private_key`) |
| `nft_forward_rules` — one role default | per-instance, derived from the §3 ingress map |

`make vps-deploy` / `vps-rebuild` / `vps-ansible` gain a `VPS=<name>` selector, defaulting to all. The existing relay keeps its name and its reserved IP, so **the media path is never rebuilt as part of this work**.

## 5. Work packages

Sequenced so each lands independently and nothing is built before it has a consumer.

| WP | Scope | Definition of Done (discriminating) |
|---|---|---|
| **WP1** | `terraform/ingress.tf` — the map, Cloudflare record resources, Vultr rule generation. Seed with the five names that are already public, so this is a **no-op diff**. | `make plan` shows **0 changes**. That is the whole test: the map provably describes reality before it drives it. |
| **WP2** | Retrofit — move `cloudflare-dns.tf`'s hand-written vps/plex/jellyfin records under the map. | `make plan` still 0 changes; `terraform state list` shows records at the new addresses. Jellyfin and Plex keep serving throughout (existing `curl --resolve` probe from the VPS). |
| **WP3** | `for_each` the VPS terraform + inventory group + per-instance tunnel/keys (§4). **No second instance yet.** | `make plan` shows **0 changes** against the live relay, and `make vps-ansible` is still idempotent (0 changed). A refactor that moves the existing VPS is a failed WP3. |
| **WP4** | `cert_client_public` — the Let's Encrypt + `dns-cloudflare` variant. Prove on **one throwaway guest on worklab**, never first on a Case VM. | `openssl s_client` returns `issuer=...Let's Encrypt`; a forced renewal succeeds (`certbot renew --force-renewal --no-random-sleep-on-renew --cert-name <fqdn>`). Never `--dry-run` — it silently retargets LE staging. |
| **WP5** | Stand up the `case` VPS: instance, reserved IP, firewall group, tunnel. pfSense peer is the hand step, MTU **measured** on the new path. | Tunnel up; `:443` DNATs to the Case target; media path provably untouched (Plex + Jellyfin probes still green). MTU proven by DF-set probe per `docs/pfsense-wireguard-vps-peer.md`, not computed. |
| **WP6** | Publish `auth` as a federation upstream + the §2 mitigations: MFA on admin groups, VPS rate-limit meter, redirect-URI anchor audit. | `auth.<service domain>` resolves publicly and serves the LE wildcard **from off-net**; an admin-group login without a second factor is refused; pfSense break-glass local login still works with the realm unreachable — test that by blocking the realm, not by reading config. |
| **WP6b** | Federation: OIDC source in the external realm pointing at internal; a `case` brand on `auth-case.<service domain>`; tester group + group-gated Case application. | The operator logs into the external realm **from off-net with no second credential**, and lands with their internal identity; a tester account is provably absent from every admin group; family login via local account still works with the internal realm blocked. |
| **WP7** | *Gated: only when a second own-TLS backend shares one VPS.* SNI-routing TCP proxy role on that VPS. | Two hostnames on one `:443`, each serving **its own** certificate. |
| **WP8** | Docs + ADRs (§7); `docs/operator-hand-steps.md` rows for the pfSense peer, NAT and tunnel-route steps. | Each hand step is a row with a verification command, matching the `pfsense-wireguard-vps-peer.md` house style. |

## 6. Risks

- **WP3 is the dangerous one**, not WP6. A `for_each` refactor that reindexes existing resources destroys and recreates the live relay — taking down Plex, Jellyfin, Valheim and mobile WireGuard. Its 0-changes bar is a hard gate, and `moved` blocks are the mechanism. Read the `will be destroyed` list before any apply.
- **WP6 feels irreversible and is not** — it is one DNS record, deletable in seconds. Worth stating, because it means the mitigations can be tested in production without ceremony.
- **`direct` exposes the home WAN address**, unlike `vps`. Inherent to the mode, and the reason `vps` stays the default for anything that does not specifically need otherwise.
- **The WAN record is DDNS-owned by pfSense's Cloudflare client.** Terraform must **not** own it; `internal_zones` already treats `vpn` this way — looked up at run time, never a static binding. `direct` follows that precedent exactly.
- **Recurring cost grows with VPS count.** The trust-boundary rule in §2 is the control; without it this pattern drifts to one VPS per service.
- **A public name is in CT logs forever.** Naming Case guests after clients or matters leaks that relationship. Use opaque labels.

## 7. Decision records this change owes

- **ADR 0044 — a declared ingress mode per service.** The enum, the single map, `tls = self|traefik`, and `direct` as a documented hand step.
- **ADR 0045 — ingress VPSs are plural, justified by trust boundary.** Generalizes ADR 0013's single relay. Carries the governing rule from §2, the masquerade finding (client IP is already lost, so proxying costs nothing), and the explicit rejection of putting SNI routing on pfSense.
- **ADR 0046 — the internal realm is published as a federation upstream; the external realm federates to it.** *Amends* rather than supersedes ADR 0040's audience split, which the federated topology preserves. Records: relying parties stay LAN-only; the three residual risks; one operator identity as the goal; and Case testers living in the external realm so admin and tester directories never merge.

`CLAUDE.md` gets the back-links and a "Canonical pipelines" row; the ADR 0013 / 0040 / 0043 paragraphs are amended in the same edit window per repo policy.
