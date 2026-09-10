# authentik — two realms on the cluster (ADR 0040 P5c)

`make talos-authentik` deploys `kubernetes/authentik/` twice from one tree (`REALM=internal|external` for one). Everything declarative lives in the realm's blueprint (`blueprint-internal.yaml`, `blueprint-external.yaml`), applied by the worker at deploy time; the steps below are the parts that live outside the repo (other products' UIs, the Cloudflare dashboard) or are per-person.

| | Internal realm | External realm |
|---|---|---|
| Namespace / Infisical folder | `authentik` / `/authentik` | `authentik-ext` / `/authentik-ext` |
| URL | `https://auth.<service domain>` (Ingress, LAN/VPN only) | `https://auth.<media domain>` (Cloudflare tunnel, no Ingress) |
| Users | operator | family + operator |
| Consumers | Traefik forward-auth (arr stack, Homepage, Kiwix, Tautulli), OIDC: Grafana, Portainer, MeshCentral, PDM, PVE, PBS | LDAP outpost → Jellyfin (P5d), Seerr via Jellyfin accounts |
| Admin login | `akadmin` / Infisical `/authentik/bootstrap_password` | `akadmin` / Infisical `/authentik-ext/bootstrap_password` |
| API token | `/authentik/bootstrap_token` | `/authentik-ext/bootstrap_token` |
| Postgres dump | nightly 02:20 → PBS ns `databases`, backup-id `authentik-postgres` | same, `authentik-ext-postgres` |

Both admins should register a passkey (user settings → MFA devices → WebAuthn) and the external `akadmin` password must never be reused for anything on the LAN.

## External realm — tunnel route (Cloudflare dashboard)

Zero Trust → Networks → Tunnels → the plex-services tunnel → Public Hostname → add `auth.<media domain>` → `HTTP` → `authentik-server.authentik-ext.svc.cluster.local:80`. Add a WAF rule blocking `/if/admin/` and `/api/` from outside the LAN's egress address once the family is enrolled. Test from a phone on cellular: `https://auth.<media domain>` shows the login page and passkey registration succeeds.

## External realm — enrolling a family member

Admin → Directory → Invitations → create, flow `family-enrollment`, single use, expiry a few days. Send the link; the person picks a username/password and lands in the `family` group. Password reset: Directory → Users → the user → *Create recovery link* (flow `family-recovery`; no mail is sent anywhere, hand the link over).

Jellyfin binds as `cn=ldapsvc,ou=users,dc=ldap,dc=goauthentik,dc=io` with `/authentik-ext/ldap_bind_password` against `ak-outpost-ldap.authentik-ext.svc:389`, base DN `dc=ldap,dc=goauthentik,dc=io`; the outpost Deployment is created and rolled by authentik itself (Kubernetes service connection), never by a manifest in this repo.

## External realm — Jellyfin (P5d)

`make talos-jellyfin` (`kubernetes/jellyfin/`) owns everything Jellyfin-side: the first-run wizard, the LDAP-Auth plugin install and its configuration, and the Movies/TV/Music libraries are driven through the API from inside the pod, so nothing is set in the Jellyfin UI. The plugin admits members of `family` or `admins` (search filter on `memberOf`), makes `admins` Jellyfin administrators, creates the Jellyfin user on first login (`CreateUsersFromLdap`) with every library enabled, and password changes stay in authentik (`AllowPassChange: false` — use the recovery link). The local `admin` account (Infisical `/jellyfin/admin_password`) exists only for the API and as the break-glass login.

- A family member's first Jellyfin login is their authentik username + password on any client (web, Roku, Android TV, Swiftfin) — the LDAP outpost caches users, so an account enrolled seconds ago may take a refresh cycle to be accepted.
- `https://jellyfin.<media domain>` resolves to Traefik on the LAN (BIND serves the media zone internally) and to the VPS relay from outside (Cloudflare unproxied A/AAAA → VPS DNAT 443 → pfSense WG_VPS forward → Traefik); the pfSense forward row is in [pfsense-wireguard-vps-peer.md](pfsense-wireguard-vps-peer.md).
- Seerr: Settings → General → switch the account backend to Jellyfin (`http://jellyfin.jellyfin.svc:8096`, sign in with an `admins` member) so family accounts request with the same credentials.

## Internal realm — consumers outside the cluster

Client IDs equal the app name; each secret is Infisical `/authentik/<app>_oidc_client_secret`; issuer `https://auth.<service domain>/application/o/<app>/`, discovery at `…/.well-known/openid-configuration`.

- **Grafana, Portainer, MeshCentral**: wired by the repo (`kubernetes/monitoring/app.yaml` env; the `control` role's Portainer settings task and MeshCentral `config.json`). Portainer keeps `/#!/internal-auth` as the local-admin door; Grafana's login form is disabled (basic auth stays on for the homepage widget); MeshCentral shows an OIDC button beside its local login.
- **PVE** (hand step, bpg has no realm resource): Datacenter → Permissions → Realms → Add → OpenID Connect: issuer URL as above (`pve`), client ID `pve`, client key from Infisical, autocreate users on, username claim `username`. Then grant the autocreated `<user>@authentik` a role. The provider accepts any `https://<node>.<service domain>:8006` redirect.
- **PBS** (hand step): Configuration → Access Control → Realms → Add → OpenID; same fields with `pbs`; redirect `https://proxmox-backup.<service domain>:8007`.
- **PDM** (hand step, done 2026-08-25): Access Control → Realms → OpenID Connect; same fields with `pdm`. PDM's realm dialog has no redirect field (unlike PVE/PBS) — none needed, the provider's `https://pdm.<service domain>:8443` redirect URI covers it.

Forward-auth: any Ingress opts in with `traefik.ingress.kubernetes.io/router.middlewares: authentik-forward-auth@kubernetescrd` (domain mode — one session cookie on `<service domain>`). The arr apps still show their own login form behind it; set each to *Authentication: External* in its UI to drop the second prompt. Uptime Kuma deliberately stays outside forward-auth: `make uptime-kuma` drives it over socket.io from the workstation and a redirect breaks the handshake; it keeps its own login.

## Rebuild

A realm rebuild is `kubectl delete ns` + `make talos-authentik REALM=…`; the Infisical folder survives, so every secret and client secret stays stable and the consumers need nothing. Data comes back from the PBS dump: restore `pg_dumpall-<date>.sql.gz` from ns `databases` and `psql -U authentik -f` into the fresh Postgres before the server starts (or after, then restart both Deployments). Verify the lane by snapshot recency on PBS, never by the CronJob's exit code.

## Internal realm — Zot registry (2026-08-27; OIDC login removed 2026-09-10)

The `zot` OIDC provider is gone (ADR 0049, WP1 of the Kubernetes-IaC plan): Zot panics at startup when its OIDC issuer is unreachable, which made the registry depend on authentik and closed the Zot/Traefik/authentik cold-start cycle. The web UI is now htpasswd-only (the `push` identity, `/infrastructure/zot_push_password`); CLI pushes were always htpasswd because Zot's OIDC cannot authenticate `docker`/`containerd`. `/authentik/zot_oidc_client_secret` is deleted by hand after the redeploy (`infisical secrets delete`).

Access control (`kubernetes/zot/values.yaml`): `anonymousPolicy: [read]` on `**`, `defaultPolicy: [read]` for any authenticated user, and `adminPolicy` limited to `push`. Before this, the registry had no `auth` block at all and accepted **anonymous pushes** — anyone on the LAN could overwrite a tag the cluster pulls. Verify after any change to that file:

    curl -s -o /dev/null -w '%{http_code}\n' -X POST https://registry.<service domain>/v2/scratch-authcheck/blobs/uploads/   # must be 401
    curl -s -o /dev/null -w '%{http_code}\n' https://registry.<service domain>/v2/docker.io/library/busybox/tags/list       # must be 200

## Internal realm — Synology DSM (provider ready, DSM side is a hand step)

The `synology` OIDC provider exists in the blueprint. On the NAS: **Control Panel → Domain/LDAP → SSO Client**, tick *Enable OIDC SSO service*, then Profile `OIDC`, Account type `Domain/LDAP/local`, Name `authentik`, Well Known URL `https://auth.<service domain>/application/o/synology/.well-known/openid-configuration`, Application ID `synology`, Application Key from Infisical `/authentik/synology_oidc_client_secret`, Redirect URL exactly `https://ds1821plus.<service domain>:5001` (or `http://…:5000`), scope `openid profile email`, username claim `preferred_username`.

DSM builds the expected redirect from the **Host and HTTPS headers of the request you are browsing**, compares it to the single configured Redirect URL, and rejects a mismatch **locally and instantly** — before contacting authentik, so nothing appears in the authentik event log. The field must therefore equal the base URL in your address bar exactly: right scheme, right port, no path and no `#/signin`, and watch for typos in the device name. DSM supports only ONE redirect URI, so the provider lists both candidate URLs as strict entries (`:5001` https and `:5000` http) and DSM picks one.

The name tracks **DSM's own device name** (`ds1821plus`), because that is what pfSense DHCP DDNS registers — there is no static alias for the NAS, and adding one would fight pfSense for the PTR. **Renaming the NAS in DSM changes the DNS name and breaks the redirect**, so update `blueprint-internal.yaml` in the same change. DDNS registers on lease grant/renewal, so a freshly enabled DHCP scope shows nothing until the device renews.

DSM authenticates existing accounts only: each user must already exist locally on the NAS before SSO will admit them.

## Internal realm — Home Assistant (provider ready, HA side is a hand step)

Home Assistant is **not fleet-managed** — nothing in this repo deploys or configures it. The `homeassistant` provider exists so the HA side can be wired by hand.

HA ships no SSO of its own, so it needs one of the two community integrations (HACS). Pick one; the provider's redirect regex accepts either callback path:

| Integration | Callback path |
|---|---|
| `christiaangoossens/hass-oidc-auth` | `/auth/oidc/callback` |
| `cavefire/hass-openid` | `/auth/openid/callback` |

Values for the HA side:

- Discovery URL: `https://auth.<service domain>/application/o/homeassistant/.well-known/openid-configuration`
- Client ID: `homeassistant`
- Client secret: Infisical `/authentik/homeassistant_oidc_client_secret`

The redirect is a **regex** — `^https?://(homeassistant|hass|ha)\.<service domain>(:8123)?/auth/(oidc|openid)/callback$`, with the domain part anchored to the escaped service domain — because HA's *hostname* is not known to this repo. Consequences:

- HA must be reached **by name** (`homeassistant`/`hass`/`ha` + any domain, optional `:8123`). An IP-addressed HA will not match, and an RFC 1918 address cannot go in a tracked file — narrow the provider by hand in the authentik UI for that case.
- `http` is permitted because HA commonly serves plain HTTP on the LAN, but the authorization code then crosses the network in clear. Prefer https, and once the real URL is settled, replace the regex with a strict URI in `blueprint-internal.yaml`.
- Group claims arrive via the `profile` scope, so admin mapping in the HA integration can key on `groups` without an extra property mapping.

**Do not enable "Block other login methods" (hass-openid) until an OIDC login has succeeded** — it removes HA's local login and will lock you out otherwise.

## Internal realm — pfSense webConfigurator (SAML2, ADR 0043)

The firewall is the one admin surface with no OIDC client — pfSense speaks Local Database, LDAP and RADIUS only. SSO rides SAML2 through `pfrest/pfSense-pkg-saml2-auth` v2.1.0, so an admin already signed in to authentik reaches the webConfigurator with no second prompt. **Local accounts stay in the authentication server order as break-glass**: the firewall's admin auth now depends on the services plane, and that is the only mitigation when the cluster is down.

The repo side is `blueprint-internal.yaml` (provider `pfsense`, application `pfsense`, group `pfsense-admins` bound to the application). Everything below is a hand step — pfSense's `ansible` sudo is password-gated — and **a pfSense upgrade removes the package**, so expect to redo it after one.

### 1. Install the package

pfSense's own trust store rejects the GitHub download chain (`Certificate verification failed for … Sectigo Public Server Authentication Root E46`), so fetch the asset on a machine with a current CA bundle and copy it over. Pick the build matching the base ABI — `pkg config abi` on the firewall, `FreeBSD:14` → the `2.7` asset, `FreeBSD:15` → `2.8`, `FreeBSD:16` → `2.9`:

    # workstation
    curl -fL -o saml2-auth.pkg https://github.com/pfrest/pfSense-pkg-saml2-auth/releases/latest/download/pfSense-<2.7|2.8|2.9>-pkg-saml2-auth.pkg
    scp saml2-auth.pkg root@pfsense.<service domain>:/root/
    # firewall
    pkg-static add /root/saml2-auth.pkg

v2.1.0 sha256: `99321193…` (2.7) · `81aed75e…` (2.8) · `e37b4e72…` (2.9).

### 2. Point it at authentik

**System → SAML2** (the package's page), then let it auto-configure from the IdP metadata:

| Field | Value |
|---|---|
| IdP Metadata URL | `https://auth.<service domain>/application/saml/pfsense/metadata/` |
| SP Base URL | `https://pfsense.<service domain>` — must equal the certificate name and what the browser shows |
| IdP Groups Attribute | `http://schemas.xmlsoap.org/claims/Group` |

The SP Base URL is load-bearing: the package derives the ACS (`…/saml2_auth/sso/acs/`) and the SP entity ID (`…/saml2_auth/sso/metadata/`) from it, and both must match the provider's `acs_url` and `audience` byte for byte. Verify against the API, not the UI:

    curl -sH "authorization: Bearer <token>" https://auth.<service domain>/api/v3/providers/saml/ | jq '.results[] | {acs_url, audience}'

### 3. Grant privileges

Create a pfSense group scoped **Remote** whose name is exactly `pfsense-admins` and give it the privileges admins should have. pfSense matches the assertion's group attribute against that name.

**The trap:** with no groups in the assertion *and* a local account of the same username present, pfSense silently admits the login with that local account's privileges. The blueprint's policy binding is what keeps this unreachable — a user outside `pfsense-admins` never receives an assertion — but it also means **break-glass usernames must not collide with authentik usernames**.

### 4. Keep the local database

Leave Local Database in **System → User Manager → Settings → Authentication Server** order. A cluster outage otherwise locks the firewall's web UI out entirely; the console stays available either way.
