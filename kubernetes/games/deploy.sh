#!/usr/bin/env bash
# games stack on the cluster (ADR 0038): the crossplay Valheim server + its PlayFab status sidecar on a
# MetalLB UDP LB (services offset 67), Kiwix over a read-only NFS PV, one InfisicalSecret on /docker.
#   deploy.sh migrate <old ip>   — player-gated: refuse while 204 reports players > 0, clean stop, rsync
#   deploy.sh kuma               — repoint the "Valheim — PlayFab lobby" row at the in-cluster sidecar
source "$(dirname "$0")/../lib.sh"
NS=games
HERE="$(cd "$(dirname "$0")" && pwd)"
DOMAIN="$(j .domain)"
export DOMAIN REGISTRY="registry.$DOMAIN" HOST_API="$(inf_host_api)" PROJECT_ID="$(inf_project_id)" VALHEIM_IP="$(subnet_ip 67)"
export SYNOLOGY_STORAGE="$("$ROOT/.venv/bin/python3" -c "import yaml;print(yaml.safe_load(open('$ROOT/ansible/group_vars/all.yml'))['synology_storage_host'])")"
eval "$(inv_env)"   # TZ
export CONFIG_HASH="$(shasum -a 256 "$HERE/valheim-playfab-status.mjs" | cut -c1-16)"
SUBST='${REGISTRY} ${HOST_API} ${PROJECT_ID} ${DOMAIN} ${TZ} ${SYNOLOGY_STORAGE} ${VALHEIM_IP} ${CONFIG_HASH}'
sub() { envsubst "$SUBST"; }

migrate() {
  local old=$1 key="$SECRETS/games-migrate-key" tag="games-migrate-p4d" s p
  [ -n "$old" ] || { echo "usage: deploy.sh migrate <old guest address>" >&2; exit 1; }
  kubectl -n "$NS" scale deploy valheim --replicas=0
  kubectl -n "$NS" wait --for=delete pod -l app=valheim --timeout=180s || true
  # Never take the world while someone is in it: the old sidecar's status.json is the only occupancy signal.
  while :; do
    s=$(curl -sf "http://$old:8081/status.json") || { echo "player gate: $old:8081/status.json unreachable — refusing to stop a server of unknown occupancy" >&2; exit 1; }
    p=$(printf '%s' "$s" | jq -r 'if .online then .players else 0 end')
    echo "player gate: $old reports players: $p ($(date -u +%FT%TZ))"
    [ "$p" = "0" ] && break
    sleep 60
  done
  ssh "root@$old" 'docker compose -f /opt/docker/docker-compose.yml stop valheim valheim-status valheim-status-web autoheal && ls -l --time-style=full-iso /opt/docker/valheim/config/worlds_local/'
  rm -f "$key" "$key.pub"; ssh-keygen -q -N '' -t ed25519 -C "$tag" -f "$key"
  ssh "root@$old" "cat >> ~/.ssh/authorized_keys" < "$key.pub"
  sub < "$HERE/migrate.yaml" | kubectl apply -f -
  kubectl -n "$NS" wait --for=condition=Ready pod/migrate --timeout=180s
  kubectl -n "$NS" exec -i migrate -- sh -c 'mkdir -p /root/.ssh && cat > /root/.ssh/id_ed25519 && chmod 600 /root/.ssh/id_ed25519' < "$key"
  for s in config data; do
    echo "== rsync $s"
    kubectl -n "$NS" exec migrate -- sh -c "mkdir -p /valheim/$s && rsync -a --delete --bwlimit=80m --info=progress2 -e 'ssh -o StrictHostKeyChecking=no' root@$old:/opt/docker/valheim/$s/ /valheim/$s/"
  done
  kubectl -n "$NS" exec migrate -- ls -l --time-style=full-iso /valheim/config/worlds_local/
  kubectl -n "$NS" delete pod migrate
  ssh "root@$old" "sed -i '/ $tag\$/d' ~/.ssh/authorized_keys"
  rm -f "$key" "$key.pub"
  kubectl -n "$NS" scale deploy valheim --replicas=1
  kubectl -n "$NS" rollout status deploy valheim --timeout=900s
}

kuma() {
  kubectl -n monitoring scale deploy uptime-kuma --replicas=0
  kubectl -n monitoring wait --for=delete pod -l app=uptime-kuma --timeout=120s || true
  kubectl -n monitoring delete pod kuma-edit --ignore-not-found >/dev/null
  sub <<'EOT' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: {name: kuma-edit, namespace: monitoring}
spec:
  restartPolicy: Never
  containers:
    - name: edit
      image: ${REGISTRY}/public.ecr.aws/docker/library/alpine:latest
      command: [sh, -c, "apk add --no-cache sqlite >/dev/null && touch /ready && sleep infinity"]
      readinessProbe: {exec: {command: [test, -f, /ready]}, periodSeconds: 2}
      volumeMounts:
        - {name: kuma, mountPath: /uptime-kuma}
  volumes:
    - {name: kuma, persistentVolumeClaim: {claimName: uptime-kuma}}
EOT
  kubectl -n monitoring wait --for=condition=Ready pod/kuma-edit --timeout=120s
  kubectl -n monitoring exec kuma-edit -- sqlite3 /uptime-kuma/data/kuma.db "
    update monitor set url='http://valheim-status.games.svc.cluster.local:8081/status.json', json_path='online', json_path_operator='==', expected_value='true' where name='Valheim — PlayFab lobby';
    select name, url, json_path, expected_value from monitor where name='Valheim — PlayFab lobby';"
  kubectl -n monitoring delete pod kuma-edit
  kubectl -n monitoring scale deploy uptime-kuma --replicas=1
  kubectl -n monitoring rollout status deploy uptime-kuma --timeout=180s
}

case "${1:-}" in
  migrate) migrate "${2:-}"; exit ;;
  kuma) kuma; exit ;;
esac

ns "$NS"
# SYS_NICE for the server process is outside PodSecurity baseline (same lift as metallb/ceph-csi).
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
kubectl create configmap valheim-status -n "$NS" --dry-run=client -o yaml --from-file="$HERE/valheim-playfab-status.mjs" | kubectl apply --server-side --force-conflicts -f -
sub < "$HERE/pv.yaml" | kubectl apply -f -
sub < "$HERE/pvc.yaml" | kubectl apply -f -
sub < "$HERE/secrets.yaml" | kubectl apply -f -
sub < "$HERE/app.yaml" | kubectl apply -f -
for i in $(seq 30); do kubectl -n "$NS" get secret valheim-secrets >/dev/null 2>&1 && break; sleep 2; done
kubectl -n "$NS" rollout status deploy kiwix --timeout=300s
LB=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
(cd "$ROOT" && make -s adguard-rewrite DOMAIN="kiwix.$DOMAIN" ANSWER="$LB")
echo "kiwix at https://kiwix.$DOMAIN ($LB); valheim UDP 2456-2458 on $VALHEIM_IP"
