# Authentik SSO — Post-Deployment Setup

After deploying Authentik containers via `make docker-deploy`, configure via the web UI.

## Initial Setup

1. Navigate to `https://<docker-vm-ip>:9443/if/flow/initial-setup/`
2. Create the admin account with a strong local password (break-glass account, independent of Plex)

## Plex Authentication Source

1. Go to **Directory > Federation & Social login > Create > Plex Source**
2. Name: "Plex"
3. Enter your Plex account credentials to obtain the client identifier
4. Enable **"Allow friends to authenticate"** to let Plex friends log in
5. Under **"Allowed servers"**, add your Plex server name to restrict access to your server's friends only

## User Groups

1. Create group **"Plex Users"** — default group for Plex-authenticated users
2. Create group **"Admin"** — add only your account
3. Map the Plex source to auto-assign the "Plex Users" group on login

## Application & Provider Setup

For each protected app, create a Proxy Provider (Forward Auth mode) and linked Application:

| Application | Internal URL | Access Group |
|-------------|-------------|-------------|
| Tautulli | `http://<plex-services-vm>:8181` | Plex Users |
| Jellyseerr | `http://<plex-services-vm>:5055` | Plex Users |
| Grafana | `http://<monitoring-vm>:3000` | Admin |
| OpenObserve | `http://<monitoring-vm>:5080` | Admin |
| Uptime Kuma | `http://<monitoring-vm>:3001` | Admin |

## Cloudflare Access Integration

1. In Authentik, create a **generic OAuth2/OIDC provider** for Cloudflare Access
2. Note the client ID, client secret, and OIDC discovery URL
3. In Cloudflare Zero Trust dashboard:
   - Go to **Settings > Authentication > Add new > OpenID Connect**
   - Enter Authentik's OIDC endpoints
   - For each tunneled application, create an Access Policy requiring authentication via the Authentik IdP
4. Auth flow: User → Cloudflare Access → Authentik → "Sign in with Plex" → OIDC token → Cloudflare grants access

## Fallback Authentication

- **Admin account** has a local password (set during initial setup) — works even if plex.tv is down
- **Regular users** depend on Plex auth; if plex.tv is down, they wait (acceptable — Tautulli/Jellyseerr need Plex anyway)
