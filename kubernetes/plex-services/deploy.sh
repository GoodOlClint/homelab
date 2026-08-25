#!/usr/bin/env bash
# plex-services stack on the cluster (ADR 0037): the arr suite + postgres + Libation, media via a
# kubelet-mounted NFS PV, one InfisicalSecret on /plex-services (+ /shared for the PBS CronJob),
# UIs through Traefik. The four *arr apps run authenticationMethod=external: Traefik's authentik
# forward-auth is the login, so the in-cluster Services answer unauthenticated — only pods reach them
# (MetalLB exposes Traefik alone). Subcommands:
#   deploy.sh smoke              — NFS PV gate: mount + write test before anything migrates
#   deploy.sh migrate <old ip>   — copy the old guest's /opt/plex-services trees into the PVCs
#   deploy.sh kuma               — repoint the five Kuma rows at the in-cluster Services
source "$(dirname "$0")/../lib.sh"
NS=plex-services
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(inv_env)"   # PBS TZ SERVICE_DOMAIN ...
export DOMAIN="$SERVICE_DOMAIN" REGISTRY="registry.$(j .domain)" HOST_API="$(inf_host_api)" PROJECT_ID="$(inf_project_id)"
export SYNOLOGY_STORAGE="$("$ROOT/.venv/bin/python3" -c "import yaml;print(yaml.safe_load(open('$ROOT/ansible/group_vars/all.yml'))['synology_storage_host'])")"
export PBS_REPOSITORY="backup@pbs!backup-token@${PBS}:synology"
export CONFIG_HASH="$(shasum -a 256 "$HERE/config/recyclarr.yml" | cut -c1-16)"
SUBST='${REGISTRY} ${HOST_API} ${PROJECT_ID} ${DOMAIN} ${TZ} ${SYNOLOGY_STORAGE} ${PBS_REPOSITORY} ${CONFIG_HASH}'
sub() { envsubst "$SUBST"; }
HOSTS=(sonarr radarr lidarr prowlarr bazarr sabnzbd tautulli seerr)

smoke() {
  ns "$NS"
  sub < "$HERE/pv.yaml" | kubectl apply -f -
  kubectl -n "$NS" delete pod nfs-smoke --ignore-not-found >/dev/null
  sub <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: {name: nfs-smoke, namespace: plex-services}
spec:
  restartPolicy: Never
  securityContext: {runAsUser: 2003, runAsGroup: 2000}
  containers:
    - name: smoke
      image: ${REGISTRY}/public.ecr.aws/docker/library/alpine:latest
      command: [sh, -ec, 'ls /data/media >/dev/null && touch /data/usenet/.k8s-nfs-smoke && rm /data/usenet/.k8s-nfs-smoke && echo NFS-SMOKE-PASS']
      volumeMounts:
        - {name: media, mountPath: /data, subPath: data}
  volumes:
    - {name: media, persistentVolumeClaim: {claimName: media}}
EOF
  kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/nfs-smoke --timeout=180s
  kubectl -n "$NS" logs nfs-smoke | grep NFS-SMOKE-PASS
  kubectl -n "$NS" delete pod nfs-smoke >/dev/null
}

migrate() {
  local old=$1 key="$SECRETS/plex-services-migrate-key" tag="plex-services-migrate-p4c"
  [ -n "$old" ] || { echo "usage: deploy.sh migrate <old guest address>" >&2; exit 1; }
  kubectl -n "$NS" scale deploy --all --replicas=0
  kubectl -n "$NS" wait --for=delete pod --all --timeout=180s || true
  ssh "root@$old" 'docker compose -f /opt/plex-services/docker-compose.yml down'
  rm -f "$key" "$key.pub"; ssh-keygen -q -N '' -t ed25519 -C "$tag" -f "$key"
  ssh "root@$old" "cat >> ~/.ssh/authorized_keys" < "$key.pub"
  sub < "$HERE/migrate.yaml" | kubectl apply -f -
  kubectl -n "$NS" wait --for=condition=Ready pod/migrate --timeout=180s
  kubectl -n "$NS" exec -i migrate -- sh -c 'mkdir -p /root/.ssh && cat > /root/.ssh/id_ed25519 && chmod 600 /root/.ssh/id_ed25519' < "$key"
  for s in postgres sonarr radarr lidarr prowlarr bazarr sabnzbd tautulli seerr recyclarr libation backups; do
    echo "== rsync $s"
    kubectl -n "$NS" exec migrate -- sh -c "mkdir -p /$s/data && rsync -a --delete --bwlimit=80m --info=progress2 -e 'ssh -o StrictHostKeyChecking=no' root@$old:/opt/plex-services/$s/ /$s/data/"
  done
  kubectl -n "$NS" delete pod migrate
  ssh "root@$old" "sed -i '/ $tag\$/d' ~/.ssh/authorized_keys"
  rm -f "$key" "$key.pub"
  kubectl -n "$NS" scale deploy --all --replicas=1
  kubectl -n "$NS" rollout status deploy --timeout=600s
}


case "${1:-}" in
  smoke) smoke; exit ;;
  migrate) migrate "${2:-}"; exit ;;
esac

ns "$NS"
kubectl create configmap recyclarr-config -n "$NS" --dry-run=client -o yaml --from-file="$HERE/config/recyclarr.yml" | kubectl apply --server-side --force-conflicts -f -
sub < "$HERE/pv.yaml" | kubectl apply -f -
sub < "$HERE/pvc.yaml" | kubectl apply -f -
sub < "$HERE/secrets.yaml" | kubectl apply -f -
sub < "$HERE/app.yaml" | kubectl apply -f -
for i in $(seq 30); do kubectl -n "$NS" get secret plex-services-secrets >/dev/null 2>&1 && break; sleep 2; done
# Pre-migration the db-backed pods crashloop until their data lands — the rollout wait is advisory.
kubectl -n "$NS" rollout status deploy --timeout=300s || true
# app:port:apiversion — the key is the pod's own config.xml ApiKey; PUT only when the method differs.
for spec in sonarr:8989:v3 radarr:7878:v3 lidarr:8686:v1 prowlarr:9696:v1; do
  IFS=: read -r app port ver <<< "$spec"
  api="K=\$(sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' /config/config.xml); curl -s -H \"X-Api-Key: \$K\" -H 'content-type: application/json' localhost:$port/api/$ver/config/host"
  host="$(kubectl -n "$NS" exec "deploy/$app" -- sh -c "$api")"
  if [ "$(jq -r .authenticationMethod <<< "$host")" = external ]; then echo "$app: auth already external"; continue; fi
  out="$(jq '.authenticationMethod = "external"' <<< "$host" | kubectl -n "$NS" exec -i "deploy/$app" -- sh -c "$api/$(jq -r .id <<< "$host") -X PUT -d @- -w '\n%{http_code}'")"
  case "${out##*$'\n'}" in 2*) echo "$app: auth -> external" ;; *) echo "$app: PUT config/host failed: $out" >&2; exit 1 ;; esac
done
echo "plex-services UIs at https://{sonarr,radarr,lidarr,prowlarr,bazarr,sabnzbd,tautulli,seerr}.$DOMAIN"
