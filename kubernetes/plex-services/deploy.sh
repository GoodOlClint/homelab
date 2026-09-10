#!/bin/bash
# plex-services stack on the cluster (ADR 0037): the arr suite + postgres + Libation, media via a
# kubelet-mounted NFS PV, one InfisicalSecret on /plex-services (+ /shared for the PBS CronJob),
# UIs through Traefik. The four *arr apps run authenticationMethod=external: Traefik's authentik
# forward-auth is the login, so the in-cluster Services answer unauthenticated — only pods reach them
# (MetalLB exposes Traefik alone). Subcommands:
#   deploy.sh smoke              — NFS PV gate: mount + write test
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



[ "${1:-}" = smoke ] && { smoke; exit; }

# Objects are Flux-owned (kubernetes/flux/apps/plex-services.yaml); this script is the in-app API tail until
# it moves into ansible/playbooks/kubernetes.yml (ADR 0048 WP7).
flux reconcile kustomization plex-services --with-source >/dev/null
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
