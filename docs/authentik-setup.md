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
