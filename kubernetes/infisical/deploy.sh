#!/usr/bin/env bash
# Infisical Kubernetes operator (ADR 0035): the cluster's secret path. The only
# out-of-band secret is `infisical-universal-auth` (the bootstrap.sops.yml
# machine identity); every runtime secret is an InfisicalSecret in its
# component's tree. `deploy.sh smoke` syncs one key from /shared and deletes it.
source "$(dirname "$0")/../lib.sh"
NS=infisical-operator
HERE="$(cd "$(dirname "$0")" && pwd)"
B="$ROOT/ansible/group_vars/bootstrap.sops.yml"
export HOST_API="$(sops -d --extract '["bootstrap_config"]["infisical_url"]' "$B")/api" REGISTRY="registry.$(j .domain)"

smoke() {
  kubectl apply -f - <<EOT
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata: {name: smoke, namespace: $NS}
spec:
  hostAPI: $HOST_API
  authentication:
    universalAuth:
      credentialsRef: {secretName: infisical-universal-auth, secretNamespace: $NS}
      secretsScope: {projectId: "$(inf_project_id)", envSlug: prod, secretsPath: /shared}
  managedKubeSecretReferences:
    - {secretName: smoke, secretNamespace: $NS, creationPolicy: Owner}
EOT
  for i in $(seq 30); do kubectl -n "$NS" get secret smoke >/dev/null 2>&1 && break; sleep 2; done
  kubectl -n "$NS" get secret smoke -o jsonpath='{.data}' | jq -r 'keys[]' | grep -q pbs_backup_token && echo "infisical operator smoke: PASS"
  kubectl -n "$NS" delete infisicalsecret smoke >/dev/null
}
[ "${1:-}" = smoke ] && { smoke; exit; }

helm repo add infisical-helm-charts https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/ >/dev/null 2>&1 || true
helm repo update infisical-helm-charts >/dev/null
ns "$NS"
kubectl create configmap homelab-root-ca -n "$NS" --from-file="$SECRETS/homelab-ca.crt" --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl -n "$NS" get secret infisical-universal-auth >/dev/null 2>&1; then
  kubectl -n "$NS" create secret generic infisical-universal-auth \
    --from-literal=clientId="$(sops -d --extract '["bootstrap"]["infisical_client_id"]' "$B")" \
    --from-literal=clientSecret="$(sops -d --extract '["bootstrap"]["infisical_client_secret"]' "$B")"
fi
helm_apply infisical-operator infisical-helm-charts/secrets-operator "$NS" -f <(envsubst < "$HERE/values.yaml")
kubectl -n "$NS" rollout status deploy --timeout=300s
