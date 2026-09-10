# Home Assistant Green — certificate from the internal CA (Let's Encrypt add-on)

The HA Green serves `https://homeassistant.<service domain>:8123` from the Infisical `fleet-hosts` CA ([ADR 0041](decisions/0041-p7-per-host-certs-are-acme-dns-01-against-infisical-through-bind-s-dynamic-update-path-on-a-scoped-tsig-key-pbs-fingerprint-pins-retire-infisical-s-own-cert-is-api-issued-behind-caddy.md)), the same issuer as the nodes and appliances. Unlike the DSM ([synology-acme.md](synology-acme.md)) no shell is needed: the official **Let's Encrypt add-on** is a general certbot wrapper with a custom `acme_server` option and RFC 2136 DNS-01, so the whole thing is add-on configuration in the HA UI.

The certificate name is `homeassistant.<service domain>` — the name DHCP registers. Do not add it to `make dns-records` (pfSense DDNS owns the A/PTR pair; the appliance rule).

## Add-on configuration

Settings → Add-ons → Let's Encrypt → Configuration, YAML mode. Values from Infisical `/infrastructure` and `kubernetes/.secrets/homelab-ca.crt`:

```yaml
domains:
  - homeassistant.<service domain>
email: <acme_email from all.yml>
key_type: rsa
challenge: dns
acme_server: <acme_directory_url>          # the FULL directory URL, not a hostname
acme_root_ca_cert: |-
  <homelab-ca.crt PEM, literal block>
dns:
  provider: dns-rfc2136
  rfc2136_server: <dns_server.bind_ipv4>   # the BIND VIP
  rfc2136_port: '53'
  rfc2136_name: acme-homeassistant
  rfc2136_secret: <acme_tsig_homeassistant>
  rfc2136_algorithm: hmac-sha256
certfile: fullchain.pem
keyfile: privkey.pem
```

Then point Home Assistant at the pair **in the UI, not `configuration.yaml`** (current HA moved the SSL settings out of the `http:` YAML block): the certificate/key fields take `/ssl/fullchain.pem` and `/ssl/privkey.pem`, and a **full restart** is required — a quick YAML reload does not restart the http server (the symptom of a missing restart is plain HTTP still answering on 8123, which a TLS client reports as `wrong version number` / `tlsv1 alert protocol version`). From then on plain `http://` and raw-IP access are gone — repoint any consumer that used them.

For the MCP server integration, also set **Settings → System → Network → Home Assistant URL** (internal and external) to `https://homeassistant.<service domain>:8123` — without it HA's `/.well-known/oauth-authorization-server` document carries relative endpoint paths and no `issuer`, and a spec-compliant MCP client rejects it (`expected string, received undefined` on `issuer`).

## Traps (all hit on first setup, 2026-09-09)

- **`acme_server` validates as a URL** — a bare hostname fails `expected a URL` at save. It is the full Infisical directory URL (`…/acme/applications/<id>/profiles/<id>/directory`).
- **`acme_root_ca_cert` must be a literal block (`|-`)** — the UI editor is happy to fold it (`>-`), which collapses the PEM to one line and certbot rejects it.
- **`rfc2136_algorithm` is lowercase `hmac-sha256`** — the add-on routes dns-rfc2136 through certbot-dns-multi (lego, Go), which rejects certbot's uppercase `HMAC-SHA256` form with `unsupported TSIG algorithm`.
- **The secret is `acme_tsig_homeassistant`, not `bind_tsig_key_secret`** — every key in `/infrastructure` is 44-char base64; the wrong one fails as `dns: bad authentication` because the signature does not verify for the key *name* `acme-homeassistant`. To bisect a bad-auth from the workstation: `nsupdate -y "hmac-sha256:acme-homeassistant:<secret>"` adding a TXT at `_acme-challenge.homeassistant.<service domain>` proves the key server-side (the grant is that one name, TXT only — ADR 0050; any other name is REFUSED).
- **`key_type: rsa` is load-bearing** — the `fleet-hosts` intermediate is RSA and Infisical only signs a CSR of the CA's key family.

## Renewal

The add-on only renews when it **starts** — there is no daemon. An HA automation (weekly time trigger → action *Add-on: Start* on the Let's Encrypt add-on) keeps it current; certbot no-ops until fewer than 30 days remain. The `TLSCertExpiringSoon` blackbox lane does not watch this host; if that coverage is wanted, add `homeassistant` to the `blackbox-tls` targets in `kubernetes/monitoring/`.

## SSO (authentik OIDC, 2026-09-09)

Login rides the `hass-oidc-auth` HACS integration against the internal realm's `homeassistant` provider (strict redirect, client secret in Infisical `/authentik`). Two known behaviors, not bugs: after logout the same browser may show **"login aborted / start over"** — HA login flows are single-use and the browser resumed a consumed one; *Start over* (or clearing site data once) fixes it. And logging out of HA does not end the authentik session (HA has no OIDC end-session), so the next "Login with Authentik" signs straight back in — the local account stays as break-glass, and its username must not collide with an authentik username.
