#!/bin/bash
# Monitoring stack on the cluster (ADR 0036): configs translated from the old role with
# ${VAR} placeholders filled from the inventory, one InfisicalSecret on /monitoring,
# axosyslog on a MetalLB address at services offset 66, UIs through Traefik.
source "$(dirname "$0")/../lib.sh"
NS=monitoring
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(inv_env)"   # ADGUARD BIND PLEX PBS UNIFI SYNOLOGY TZ SERVICE_DOMAIN ...
export DOMAIN="$SERVICE_DOMAIN"
export REGISTRY="registry.$(j .domain)" HOST_API="$(inf_host_api)" PROJECT_ID="$(inf_project_id)" SYSLOG_IP="$(subnet_ip 66)"
export AUTH_HOST="auth.$DOMAIN" GRAFANA_HOST="grafana.$DOMAIN" OO_HOST="openobserve.$DOMAIN" PROM_HOST="prometheus.$DOMAIN" AM_HOST="alertmanager.$DOMAIN" KUMA_HOST="uptime-kuma.$DOMAIN"
export PVE_API_HOST="$(sed -n 's/^virtual_environment_endpoint *= *"https\{0,1\}:\/\/\([^:"/]*\).*/\1/p' "$ROOT/terraform/vars.auto.tfvars")"
GEN="$(mktemp -d)"; trap 'rm -rf "$GEN"' EXIT
eval "$("$ROOT/.venv/bin/python3" "$HERE/render.py" "$ROOT" "$GEN")"   # OO_EMAIL UNIFI_PORT SYNOLOGY_SNMP_COMMUNITY SMOKEPING_ARGS + $GEN/*.json
export CONFIG_HASH="$(cat "$HERE"/config/* "$GEN"/*.json | shasum -a 256 | cut -c1-16)"
# Only these are substituted — the configs carry $-syntax of their own (Grafana, Prometheus templates, syslog-ng macros).
SUBST='${REGISTRY} ${HOST_API} ${PROJECT_ID} ${SYSLOG_IP} ${AUTH_HOST} ${GRAFANA_HOST} ${OO_HOST} ${PROM_HOST} ${AM_HOST} ${KUMA_HOST} ${PVE_API_HOST} ${DOMAIN} ${ADGUARD} ${BIND} ${PLEX} ${PBS} ${UNIFI} ${UNIFI_PORT} ${SYNOLOGY} ${SYNOLOGY_SNMP_COMMUNITY} ${SMOKEPING_ARGS} ${OO_EMAIL} ${TZ} ${MEDIA_DOMAIN} ${CONFIG_HASH}'
sub() { envsubst "$SUBST"; }


ns "$NS"
cm() { local n=$1; shift; kubectl create configmap "$n" -n "$NS" --dry-run=client -o yaml "$@" | sub | kubectl apply --server-side --force-conflicts -f -; }   # server-side: the dashboards exceed the last-applied annotation cap
cm prometheus-config --from-file="$HERE/config/prometheus.yml" --from-file="$HERE/config/alert.rules.yml"
cm prometheus-targets --from-file="$GEN/telegraf.json" --from-file="$GEN/blackbox-dns.json"
cm alertmanager-config --from-file="$HERE/config/alertmanager.yml"
cm blackbox-config --from-file="$HERE/config/blackbox.yml"
cm homelab-root-ca --from-file="$SECRETS/homelab-ca.crt"
cm snmp-config --from-file="$HERE/config/snmp.yml"
cm axosyslog-config --from-file=syslog-ng.conf="$HERE/config/axosyslog.conf"
cm grafana-provisioning --from-file="$HERE/config/grafana-datasource.yml" --from-file="$HERE/config/grafana-dashboards.yml"
cm grafana-dashboards $(for f in "$HERE"/dashboards/*.json; do printf -- '--from-file=%s ' "$f"; done) --from-file=smokeping.json="$GEN/smokeping.json"
sub < "$HERE/pvc.yaml" | kubectl apply -f -
sub < "$HERE/secrets.yaml" | kubectl apply -f -
sub < "$HERE/app.yaml" | kubectl apply -f -
for s in monitoring-secrets authentik-oidc; do for i in $(seq 30); do kubectl -n "$NS" get secret "$s" >/dev/null 2>&1 && break; sleep 2; done; done
kubectl -n "$NS" rollout status deploy --timeout=600s
echo "monitoring UIs at https://{$GRAFANA_HOST,$OO_HOST,$PROM_HOST,$AM_HOST,$KUMA_HOST}; syslog/netconsole at $(kubectl -n "$NS" get svc syslog -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
