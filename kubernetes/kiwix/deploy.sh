#!/usr/bin/env bash
# Kiwix ZIM library. Split out of the games namespace 2026-08-27: it only shared one
# with Valheim because both came off the same pre-cluster guest (ADR 0038), and games
# is pod-security enforce=privileged for Valheim's SYS_NICE, which Kiwix must not inherit.
source "$(dirname "$0")/../lib.sh"
NS=kiwix
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(inv_env)"   # TZ SERVICE_DOMAIN
export DOMAIN="$SERVICE_DOMAIN" REGISTRY="registry.$(j .domain)"
export SYNOLOGY_STORAGE="$("$ROOT/.venv/bin/python3" -c "import yaml;print(yaml.safe_load(open('$ROOT/ansible/group_vars/all.yml'))['synology_storage_host'])")"
SUBST='${REGISTRY} ${DOMAIN} ${TZ} ${SYNOLOGY_STORAGE}'
sub() { envsubst "$SUBST"; }

ns "$NS"
# An unlabelled namespace inherits the cluster default (privileged), so the split only
# tightens anything if the label is set: kiwix serves static files and needs no lift.
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=baseline --overwrite >/dev/null
sub < "$HERE/pv.yaml" | kubectl apply -f -
sub < "$HERE/app.yaml" | kubectl apply -f -
kubectl -n "$NS" rollout status deploy kiwix --timeout=300s
echo "kiwix at https://kiwix.$DOMAIN"
