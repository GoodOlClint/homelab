# pfSense — certificates from the internal CA (ACME)

pfSense gets its webConfigurator certificate from the Infisical `fleet-hosts` CA (ADR 0041), the same issuer as the nodes and guests. The ACME package is hand-configured: pfSense's `ansible` sudo is password-gated, so nothing here can be driven unattended, and **a pfSense upgrade removes packages** (the NUT precedent, [docs/pfsense-nut.md](pfsense-nut.md)) — expect to redo the package install after one.

## Two prerequisites that are not in the Netgate docs

Both exist because the ACME server is a *private* CA reached by an *internal-only* name. Netgate's guide assumes a public one, so it covers neither.

1. **Trust the root.** The directory URL is served by the Infisical guest, whose certificate chains to `Homelab Root CA`. Import that root under **System → Cert. Manager → CAs → Add → Import an existing Certificate Authority** first (`kubernetes/.secrets/homelab-ca.crt`). Without it acme.sh cannot complete TLS to the directory.
2. **Resolve internal names.** Every internal name lives only in BIND; the public copy of the zone holds just the DDNS records pfSense itself maintains. With the DNS Resolver disabled, pfSense uses the servers from **System → General Setup**, but **"Allow DNS server list to be overridden by DHCP/PPP on WAN" (DNS Server Override) prepends the ISP's resolvers**, so every internal lookup goes public and returns NXDOMAIN. Untick it. The symptom is curl error **6** (`COULDNT_RESOLVE_HOST`) in `/tmp/acme/_registerkey/acme_issuecert.log` — *not* a TLS or settings error:

        Please refer to https://curl.haxx.se/libcurl/c/libcurl-errors.html for error code: 6
        Cannot init API for: https://infisical.<service domain>/api/v1/cert-manager/acme/...

## ACME server entry

The custom server only adds an entry to the ACME-server dropdown; it issues nothing. Both fields must be non-empty or the package skips it silently (`installedpackages/acme/customacme/servers`, `intid`/`name`/`url`).

| Field | Value |
|---|---|
| Internal ID | `homelab-ca` |
| Display Name | `Homelab CA (fleet-hosts)` |
| Server URL | Infisical `/infrastructure/acme_directory_url` |

## Account key

| Field | Value |
|---|---|
| Name | `homelab-ca` (internal identifier — the Certificates page refers to it by this) |
| Description | `Homelab fleet-hosts CA (Infisical)` |
| E-Mail Address | `acme_email` from `group_vars/all.yml` |
| ACME Server | `Homelab CA (fleet-hosts)` |
| EAB Key ID / HMAC Key | **blank** — the directory advertises `externalAccountRequired: false` |
| Account Key | **Generate New Account Key** |

**Save before registering** — the Register button acts on the saved entry.

## Certificate — DNS-01 only

HTTP-01 is not usable: the name resolves only internally. Method **DNS-NSupdate / RFC 2136**.

| Field | Value |
|---|---|
| Server | the BIND VIP (`dns_server.bind_ipv4`) |
| Key Name | `acme-key` |
| Key Algorithm | `HMAC-SHA256` |
| Key | Infisical `/infrastructure/acme_tsig_key_secret` |

**Set DNS Sleep to a non-empty value (30 is plenty).** Left empty, acme.sh runs `_check_dns_entries()` — it polls *public* DNS over Cloudflare DoH to confirm the TXT propagated before asking the CA to validate, and even purges Cloudflare's cache for the name. The service zone is internal-only, so that check can never pass and issuance stalls with `Not valid yet, let's wait for 10 seconds then check the next one`. Any value for DNS Sleep replaces the check with a fixed wait (acme.sh's own hint: *"You can use '--dnssleep' to disable public dns checks"*). BIND is authoritative and local, so the record is live as soon as `nsupdate` returns.

The Key Name help text ("(Optional) A name for the key, if it is different than `_acme-challenge.[DomainName]`") is misleading — it is the **TSIG key name** and is required. BIND's policy is `grant acme-key wildcard *.<service domain>. TXT`, so that key may write challenge TXT records in the service zone and nothing else; a refused update means the request was for a name outside it.

## Known limitation

The Infisical directory advertises only `newNonce`, `newAccount` and `newOrder`. RFC 8555 §7.1.1 also requires `revokeCert` and `keyChange`, and both are absent — so **certificate revocation through this CA does not work from pfSense**. Issuance and renewal are unaffected. Same family as the PVE client's CRLF/PEM incompatibility recorded in CLAUDE.md: this ACME server is somewhat non-conformant and client tolerance varies.

## The certificate name

Whatever name is issued becomes load-bearing in three places: the certificate SAN, the SAML2 SP Base URL (which derives the ACS and SP Entity ID), and every admin's browser. It must be the interface the webConfigurator is actually browsed on. Note pfSense **self-registers its own name over DDNS** — do not add it to `make dns-records`, which fights that registration on both the A and PTR records.
