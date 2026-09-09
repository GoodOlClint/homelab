# Synology DSM — certificate from the internal CA (acme.sh)

DSM serves its UI (and every service that reuses the system certificate) from the Infisical `fleet-hosts` CA, the same issuer as the nodes and guests ([ADR 0041](decisions/0041-p7-per-host-certs-are-acme-dns-01-against-infisical-through-bind-s-dynamic-update-path-on-a-scoped-tsig-key-pbs-fingerprint-pins-retire-infisical-s-own-cert-is-api-issued-behind-caddy.md)). Neither of DSM's own paths can do it: the built-in client and the third-party `dnsacme` package are both hard-wired to Let's Encrypt, so the client has to be one that takes an arbitrary directory URL. That is acme.sh, installed in the admin user's home.

**Nothing here needs root.** DSM's `sudo` is password-gated, and the whole setup — issuance and the deploy into DSM — runs as `goodolclint` (a member of `administrators`), because acme.sh's `synology_dsm` deploy hook installs the certificate through the **DSM web API**, not the filesystem. The one part of the hook that does need root, `SYNO_USE_TEMP_ADMIN=1` (it shells out to `synouser`), is therefore not used.

The certificate name is `ds1821plus.<service domain>` — the name DHCP registers for the NAS. Do not add the NAS to `make dns-records`: pfSense's DDNS owns that A and PTR pair and a second writer fights it (the same rule that governs every other appliance).

## One-time setup

Everything below is run over SSH as `goodolclint`. `curl`, `openssl` and `nsupdate` all ship with DSM 7.4.

**1. Trust the root.** The directory URL is served by the Infisical guest, whose certificate chains to `Homelab Root CA`, and DSM's bundle does not carry it. Without this every acme.sh call dies at `curl: (60) SSL certificate problem: self-signed certificate in certificate chain`.

    ssh goodolclint@<nas> 'umask 022; cat > ~/homelab-ca.crt' < kubernetes/.secrets/homelab-ca.crt

`scp` to DSM fails (`Connection closed` — the sftp subsystem is off); pipe into a remote `cat` instead.

**2. Install acme.sh** with `--nocron` (see Renewal — there is no `crontab` binary on DSM):

    curl -fsSL -o /tmp/acme-install.sh https://get.acme.sh
    sh /tmp/acme-install.sh email=<acme_email> --nocron
    mv -f ~/homelab-ca.crt ~/.acme.sh/homelab-ca.crt

**3. TSIG key** for the DNS-01 challenge — the TXT-only `acme-key`, `/infrastructure/acme_tsig_key_secret`, in `nsupdate`'s key-file format, mode 0600 at `~/.acme.sh/acme-tsig.key`:

    key "acme-key" {
        algorithm hmac-sha256;
        secret "<acme_tsig_key_secret>";
    };

**4. Register the account** against the fleet directory. `--ca-bundle` is saved into `account.conf`, so every later run — including the scheduled one — trusts the root without being told again.

    export NSUPDATE_SERVER=<dns_server.bind_ipv4> NSUPDATE_KEY=$HOME/.acme.sh/acme-tsig.key
    ~/.acme.sh/acme.sh --register-account --server <acme_directory_url> \
      -m <acme_email> --ca-bundle $HOME/.acme.sh/homelab-ca.crt

**5. Issue:**

    ~/.acme.sh/acme.sh --issue --server <acme_directory_url> \
      --ca-bundle $HOME/.acme.sh/homelab-ca.crt \
      -d ds1821plus.<service domain> --dns dns_nsupdate --dnssleep 30 --keylength 2048

`--dnssleep 30` is required, the same trap as [pfSense](pfsense-acme.md). Without it acme.sh runs `_check_dns_entries()`, which polls **public** DNS over Cloudflare DoH to confirm the TXT propagated; the service zone is internal-only, so that check can never pass and issuance stalls on `Not valid yet, let's wait for 10 seconds then check the next one`. BIND is authoritative and local — the record is live as soon as `nsupdate` returns.

`--keylength 2048` is required because Infisical only signs a CSR whose key family matches the CA's, and the fleet issuer is the RSA intermediate `Homelab Hosts CA`. acme.sh's default is `ec-256`, which the CA rejects.

`NSUPDATE_SERVER` and `NSUPDATE_KEY` are saved into `account.conf` by the plugin on first use; the `--server`, `--ca-bundle`, `--dnssleep` and key length are saved into the domain conf. A renewal therefore needs no environment at all.

**6. Deploy into DSM.** With `SYNO_CERTIFICATE` unset the hook replaces the **default** system certificate, which is the one nginx serves for the box:

    export SYNO_USERNAME=goodolclint SYNO_PASSWORD=<synology_admin_password> SYNO_CREATE=1
    ~/.acme.sh/acme.sh --deploy --deploy-hook synology_dsm -d ds1821plus.<service domain>

The hook logs in at `http://localhost:5000`, uploads the pair, and restarts the HTTP services. The credentials are saved (base64) into the domain conf, so renewals redeploy unattended. The password lives at Infisical `/infrastructure/synology_admin_password` — it is the account's **DSM web** password, and the account must not have 2FA enabled (with 2FA the hook needs an interactive `SYNO_OTP_CODE` to mint a device ID first).

## Renewal

**DSM has no `crontab` binary**, so acme.sh cannot install its own cron job and `--nocron` above is not optional. Renewal is a **Task Scheduler** entry instead — `acme.sh renew`, task id 5, user `goodolclint`, daily at 03:15. Recreate it at *Control Panel → Task Scheduler → Create → Scheduled Task → User-defined script* running:

    /var/services/homes/goodolclint/.acme.sh/acme.sh --cron --home /var/services/homes/goodolclint/.acme.sh

`LOG_FILE` and `LOG_LEVEL=1` are set in `account.conf` so each run leaves `~/.acme.sh/acme.sh.log` — without it a scheduled run is invisible, since the task's own output is only readable as root.

Prove renewal the way the rest of the fleet's certs are proven — force it and confirm the *served* certificate moves:

    ~/.acme.sh/acme.sh --cron --home ~/.acme.sh --force
    openssl s_client -connect ds1821plus.<service domain>:5001 -servername ds1821plus.<service domain> </dev/null 2>/dev/null | openssl x509 -noout -serial -dates

Prometheus watches the expiry through `blackbox-tls` (`ds1821plus.<service domain>:5001`, `TLSCertExpiringSoon`), which is the only thing that would catch the scheduled task silently going away — a certificate good for a year gives no other warning.

## Known limitations

**The Task Scheduler "run now" API does not work for a user-owned script task** — `SYNO.Core.TaskScheduler` `method=run` returns `success: true` on version 1 and `4803 Failed to run task` on version 2, and in both cases the script never executes. Only the schedule fires it. Verify a task by moving its schedule a few minutes ahead and watching `~/.acme.sh/acme.sh.log`, never by the run button.

**`method=set` returns HTTP 502 if `extra` is omitted** — the CGI faults rather than reporting a missing field, and the task is left unchanged. Always resend the full payload (`name`, `owner`, `real_owner`, `enable`, `type`, `schedule`, `extra`). DSM also normalises `repeat_date` to `0`; a daily task is `date_type: 0` with `week_day: "0,1,2,3,4,5,6"`, which is the same shape DSM's own built-in S.M.A.R.T. tasks use.

**Revocation through this CA does not work**, as on pfSense: the Infisical directory advertises only `newNonce`, `newAccount` and `newOrder`, and RFC 8555 §7.1.1 also requires `revokeCert` and `keyChange`. Issuance and renewal are unaffected.

**A DSM major upgrade may drop the scheduled task or the SSH key**; the acme.sh install itself lives on the volume and survives. Re-check both after one, the same way the pfSense package install is re-checked.
