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
  rfc2136_name: acme-key
  rfc2136_secret: <acme_tsig_key_secret>
  rfc2136_algorithm: hmac-sha256
certfile: fullchain.pem
keyfile: privkey.pem
```

Then `configuration.yaml`:

```yaml
http:
  ssl_certificate: /ssl/fullchain.pem
  ssl_key: /ssl/privkey.pem
```

and restart Home Assistant. From then on plain `http://` and raw-IP access are gone — repoint any consumer that used them.

## Traps (all hit on first setup, 2026-09-09)

- **`acme_server` validates as a URL** — a bare hostname fails `expected a URL` at save. It is the full Infisical directory URL (`…/acme/applications/<id>/profiles/<id>/directory`).
- **`acme_root_ca_cert` must be a literal block (`|-`)** — the UI editor is happy to fold it (`>-`), which collapses the PEM to one line and certbot rejects it.
- **`rfc2136_algorithm` is lowercase `hmac-sha256`** — the add-on routes dns-rfc2136 through certbot-dns-multi (lego, Go), which rejects certbot's uppercase `HMAC-SHA256` form with `unsupported TSIG algorithm`.
- **The secret is `acme_tsig_key_secret`, not `bind_tsig_key_secret`** — both live in `/infrastructure` and both are 44-char base64; the wrong one fails as `dns: bad authentication` because the signature does not verify for the key *name* `acme-key`. To bisect a bad-auth from the workstation: `nsupdate -y "hmac-sha256:acme-key:<secret>"` adding a TXT under `_acme-challenge.…` proves the key server-side (the acme-key's grant is TXT-only, wildcard).
- **`key_type: rsa` is load-bearing** — the `fleet-hosts` intermediate is RSA and Infisical only signs a CSR of the CA's key family.

## Renewal

The add-on only renews when it **starts** — there is no daemon. An HA automation (weekly time trigger → action *Add-on: Start* on the Let's Encrypt add-on) keeps it current; certbot no-ops until fewer than 30 days remain. The `TLSCertExpiringSoon` blackbox lane does not watch this host; if that coverage is wanted, add `homeassistant` to the `blackbox-tls` targets in `kubernetes/monitoring/`.
