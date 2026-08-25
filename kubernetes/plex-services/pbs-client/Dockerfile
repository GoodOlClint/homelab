# proxmox-backup-client for the pg-backup CronJob (ADR 0037).
# Built + pushed by `make plex-pbs-image` — the client suite tracks the Debian base, so
# rebuild against the matching base when the PBS server major rolls (see ADR 0025's suite rule).
FROM debian:trixie-slim
COPY homelab-ca.crt /usr/local/share/ca-certificates/homelab-root-ca.crt
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates wget \
 && wget -qO /etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg \
 && echo "deb http://download.proxmox.com/debian/pbs-client trixie main" > /etc/apt/sources.list.d/pbs-client.list \
 && apt-get update && apt-get install -y --no-install-recommends proxmox-backup-client \
 && apt-get purge -y wget && apt-get autoremove -y && rm -rf /var/lib/apt/lists/* \
 && update-ca-certificates
