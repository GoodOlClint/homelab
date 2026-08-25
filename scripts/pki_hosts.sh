#!/usr/bin/env bash
# Fleet-host PKI on Infisical (ADR 0041): certificate policy + profile `fleet-hosts` under the
# `Homelab Root CA` (ADR 0039), one application with ACME (DNS-01, no EAB) and API enrollment.
# Idempotent by name. Publishes the ACME directory URL to Infisical /infrastructure and to
# terraform/hosts/pki.auto.tfvars (gitignored — it carries the service domain).
source "$(dirname "$0")/../kubernetes/lib.sh"
eval "$(inv_env)"   # SERVICE_DOMAIN
PROJ=$(inf /v1/workspace | jq -r '.workspaces[] | select(.type=="cert-manager" and .name=="homelab-pki") | .id')
[ -n "$PROJ" ] || { echo "homelab-pki project missing — run make talos-certs first" >&2; exit 1; }
CA=$(inf "/v1/cert-manager/ca?projectId=$PROJ" | jq -r '.certificateAuthorities[] | select(.name=="homelab-root-ca") | .id')
[ -n "$CA" ] || { echo "homelab-root-ca missing — run make talos-certs first" >&2; exit 1; }

[ "$(inf /v1/cert-manager/instance | jq -r .activeProjectId)" = "$PROJ" ] ||
  inf /v1/cert-manager/instance/active-project -d "{\"projectId\":\"$PROJ\"}" >/dev/null

POL=$(inf "/v1/cert-manager/certificate-policies?projectId=$PROJ" | jq -r '.certificatePolicies[] | select(.name=="fleet-hosts") | .id')
[ -n "$POL" ] || POL=$(inf /v1/cert-manager/certificate-policies -d "$(jq -n --arg p "$PROJ" --arg d "*.$SERVICE_DOMAIN" \
  '{projectId:$p,name:"fleet-hosts",description:"per-host server certs (ADR 0041)",sans:[{type:"dns_name",allowed:[$d]},{type:"ip_address",allowed:["*"]}],validity:{max:"400d"},basicConstraints:{isCA:"denied"}}')" | jq -r .certificatePolicy.id)
[ -n "$POL" ] && [ "$POL" != null ] || { echo "policy create failed" >&2; exit 1; }

PROF=$(inf "/v1/cert-manager/certificate-profiles?projectId=$PROJ" | jq -r '.certificateProfiles[] | select(.slug=="fleet-hosts") | .id')
[ -n "$PROF" ] || PROF=$(inf /v1/cert-manager/certificate-profiles -d "$(jq -n --arg p "$PROJ" --arg ca "$CA" --arg pol "$POL" --arg alg EC_prime256v1 --arg sig ECDSA-SHA384 \
  '{projectId:$p,caId:$ca,certificatePolicyId:$pol,slug:"fleet-hosts",description:"per-host server certs (ADR 0041)",defaults:{ttlDays:365,keyAlgorithm:$alg,signatureAlgorithm:$sig,keyUsages:["digital_signature","key_encipherment"],extendedKeyUsages:["server_auth"]}}')" | jq -r .certificateProfile.id)
[ -n "$PROF" ] && [ "$PROF" != null ] || { echo "profile create failed" >&2; exit 1; }

APP=$(inf "/v1/cert-manager/applications?projectId=$PROJ" | jq -r '.applications[]? | select(.name=="fleet-hosts") | .id')
[ -n "$APP" ] || APP=$(inf /v1/cert-manager/applications -d "$(jq -n --arg p "$PROJ" --arg pr "$PROF" '{projectId:$p,name:"fleet-hosts",description:"PVE nodes, PBS, PDM, Infisical, control (ADR 0041)",profileIds:[$pr]}')" | jq -r .application.id)
[ -n "$APP" ] && [ "$APP" != null ] || { echo "application create failed" >&2; exit 1; }
inf "/v1/cert-manager/applications/$APP/profiles/$PROF/enrollment/acme" -X PUT -d '{"skipEabBinding":true,"skipDnsOwnershipVerification":false}' >/dev/null
inf "/v1/cert-manager/applications/$APP/profiles/$PROF/enrollment/api" -X PUT -d '{"autoRenew":false}' >/dev/null

DIR="https://infisical.$SERVICE_DOMAIN/api/v1/cert-manager/acme/applications/$APP/profiles/$PROF/directory"
put_secret() { # key value comment
  local id; id="$(inf_project_id)"
  local body; body=$(jq -n --arg id "$id" --arg v "$2" --arg c "$3" '{workspaceId:$id,environment:"prod",secretPath:"/infrastructure",secretValue:$v,secretComment:$c}')
  [ "$(inf "/v3/secrets/raw/$1?workspaceId=$id&environment=prod&secretPath=/infrastructure" -o /dev/null -w '%{http_code}')" = 200 ] \
    && inf "/v3/secrets/raw/$1" -X PATCH -d "$body" >/dev/null || inf "/v3/secrets/raw/$1" -d "$body" >/dev/null
}
put_secret acme_directory_url "$DIR" "ACME directory for fleet-host certs (ADR 0041) — written by make pki-hosts"
put_secret acme_application_id "$APP" "Infisical cert-manager application fleet-hosts (ADR 0041)"
put_secret acme_profile_id "$PROF" "Infisical cert-manager profile fleet-hosts (ADR 0041)"
printf 'acme_directory = "%s"\nacme_zone      = "%s"\n' "$DIR" "$SERVICE_DOMAIN" > "$ROOT/terraform/hosts/pki.auto.tfvars"
echo "fleet-hosts: policy $POL profile $PROF application $APP"
echo "directory: $DIR"
