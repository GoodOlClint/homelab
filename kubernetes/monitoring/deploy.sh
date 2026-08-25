#!/usr/bin/env bash
# Monitoring stack on the cluster (ADR 0036): configs translated from the old role with
# ${VAR} placeholders filled from the inventory, one InfisicalSecret on /monitoring,
# axosyslog on a MetalLB address at services offset 66, UIs through Traefik.
# `deploy.sh migrate <old guest ip>` copies the old guest's /var/lib/monitoring trees into the PVCs.
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

migrate() {
  local old=$1 key="$SECRETS/monitoring-migrate-key" tag="monitoring-migrate-p4b"
  [ -n "$old" ] || { echo "usage: deploy.sh migrate <old guest address>" >&2; exit 1; }
  kubectl -n "$NS" scale deploy --all --replicas=0
  kubectl -n "$NS" wait --for=delete pod -l 'app in (openobserve,prometheus,grafana,uptime-kuma,alertmanager)' --timeout=120s || true
  ssh "root@$old" 'docker compose -f /opt/monitoring/docker-compose.yml down'
  rm -f "$key" "$key.pub"; ssh-keygen -q -N '' -t ed25519 -C "$tag" -f "$key"
  ssh "root@$old" "cat >> ~/.ssh/authorized_keys" < "$key.pub"
  sub < "$HERE/migrate.yaml" | kubectl apply -f -
  kubectl -n "$NS" wait --for=condition=Ready pod/migrate --timeout=180s
  kubectl -n "$NS" exec -i migrate -- sh -c 'mkdir -p /root/.ssh && cat > /root/.ssh/id_ed25519 && chmod 600 /root/.ssh/id_ed25519' < "$key"
  for s in openobserve prometheus grafana uptime-kuma alertmanager; do
    echo "== rsync $s"
    kubectl -n "$NS" exec migrate -- sh -c "mkdir -p /$s/data && rsync -a --delete --bwlimit=80m --info=progress2 -e 'ssh -o StrictHostKeyChecking=no' root@$old:/var/lib/monitoring/$s/ /$s/data/"
  done
  kubectl -n "$NS" delete pod migrate
  ssh "root@$old" "sed -i '/ $tag\$/d' ~/.ssh/authorized_keys"
  rm -f "$key" "$key.pub"
  kubectl -n "$NS" scale deploy --all --replicas=1
  kubectl -n "$NS" rollout status deploy --timeout=300s
  (cd "$ROOT" && make -s uptime-kuma)
}
[ "${1:-}" = migrate ] && { migrate "${2:-}"; exit; }

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
