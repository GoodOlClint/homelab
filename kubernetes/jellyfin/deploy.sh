#!/usr/bin/env bash
# Jellyfin on the cluster (ADR 0040 P5d): config + transcode cache on ceph-rbd, the NAS media export
# read-only at /data, jellyfin.<media domain> through Traefik, auth = the LDAP-Auth plugin against the
# authentik external realm's outpost. The first-run wizard, the plugin install + config and the libraries
# are driven through the API from inside the pod — never the UI — and a second run changes nothing.
source "$(dirname "$0")/../lib.sh"
NS=jellyfin FOLDER=jellyfin
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(inv_env)"   # TZ MEDIA_DOMAIN
export DOMAIN="$MEDIA_DOMAIN" REGISTRY="registry.$(j .domain)" HOST_API="$(inf_host_api)" PROJECT_ID="$(inf_project_id)" TZ
export SYNOLOGY_STORAGE="$("$ROOT/.venv/bin/python3" -c "import yaml;print(yaml.safe_load(open('$ROOT/ansible/group_vars/all.yml'))['synology_storage_host'])")"
SUBST='${REGISTRY} ${HOST_API} ${PROJECT_ID} ${DOMAIN} ${TZ} ${SYNOLOGY_STORAGE}'
sub() { envsubst "$SUBST"; }
LDAP_PLUGIN=958aad66-3784-4d2a-b89a-a7b6fab6e25c   # /Plugins lists the Id without dashes
LDAP_BASE='dc=ldap,dc=goauthentik,dc=io'

ensure_folder "$FOLDER"
ensure_secret admin_password 16 "Jellyfin: local admin password (deploy.sh drives the API with it)"
ns "$NS"
sub < "$HERE/pv.yaml" | kubectl apply -f -
sub < "$HERE/secrets.yaml" | kubectl apply -f -
sub < "$HERE/app.yaml" | kubectl apply -f -
for i in $(seq 30); do kubectl -n "$NS" get secret jellyfin-admin jellyfin-ldap >/dev/null 2>&1 && break; sleep 2; done
kubectl -n "$NS" rollout status deploy/jellyfin --timeout=600s

jf() { # path [curl args...] — from inside the pod, so neither DNS nor the ingress is in the loop
  kubectl -n "$NS" exec -i deploy/jellyfin -- curl -sSf -H 'content-type: application/json' "http://localhost:8096$1" "${@:2}"
}
secret() { kubectl -n "$NS" get secret "$1" -o "jsonpath={.data.$2}" | base64 -d; }
ADMIN_PW="$(secret jellyfin-admin ADMIN_PASSWORD)"

if [ "$(jf /System/Info/Public | jq -r .StartupWizardCompleted)" != true ]; then
  jf /Startup/Configuration -X POST -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}'
  jf /Startup/User >/dev/null   # initializes the first user; the POST 404s without it
  jf /Startup/User -X POST -d @- <<<"$(jq -n --arg p "$ADMIN_PW" '{Name:"admin",Password:$p}')"
  jf /Startup/RemoteAccess -X POST -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}'
  jf /Startup/Complete -X POST
fi
TOKEN="$(jf /Users/AuthenticateByName -X POST -H 'Authorization: MediaBrowser Client="deploy.sh", Device="deploy", DeviceId="deploy", Version="1"' \
  -d @- <<<"$(jq -n --arg p "$ADMIN_PW" '{Username:"admin",Pw:$p}')" | jq -r .AccessToken)"
A=(-H "Authorization: MediaBrowser Token=\"$TOKEN\"")

if ! jf /Plugins "${A[@]}" | jq -e --arg id "${LDAP_PLUGIN//-/}" 'any(.[]; .Id==$id)' >/dev/null; then
  jf "/Packages/Installed/LDAP%20Authentication" "${A[@]}" -X POST
  jf /System/Restart "${A[@]}" -X POST || true
  sleep 10
  for i in $(seq 60); do jf /Plugins "${A[@]}" 2>/dev/null | jq -e --arg id "${LDAP_PLUGIN//-/}" 'any(.[]; .Id==$id)' >/dev/null && break; sleep 5; done
fi

want="$(jq -n --arg pw "$(secret jellyfin-ldap LDAP_BIND_PASSWORD)" --arg b "$LDAP_BASE" '{
  LdapServer: "ak-outpost-ldap.authentik-ext.svc", LdapPort: 389, UseSsl: false, UseStartTls: false, SkipSslVerify: false,
  LdapBindUser: ("cn=ldapsvc,ou=users," + $b), LdapBindPassword: $pw, LdapBaseDn: $b,
  LdapSearchFilter: ("(|(memberOf=cn=family,ou=groups," + $b + ")(memberOf=cn=admins,ou=groups," + $b + "))"),
  LdapAdminBaseDn: "", LdapAdminFilter: ("(memberOf=cn=admins,ou=groups," + $b + ")"), EnableLdapAdminFilterMemberUid: false,
  LdapSearchAttributes: "uid, cn, mail, displayName", LdapUidAttribute: "uid", LdapUsernameAttribute: "cn", LdapPasswordAttribute: "userPassword",
  CreateUsersFromLdap: true, AllowPassChange: false, EnableAllFolders: true, EnabledFolders: []}')"
have="$(jf "/Plugins/$LDAP_PLUGIN/Configuration" "${A[@]}")"
if [ "$(jq -S . <<<"$have")" != "$(jq -S --argjson w "$want" '. + $w' <<<"$have")" ]; then
  jq --argjson w "$want" '. + $w' <<<"$have" | jf "/Plugins/$LDAP_PLUGIN/Configuration" "${A[@]}" -X POST -d @-
  echo "LDAP plugin configured"
fi

libs="$(jf /Library/VirtualFolders "${A[@]}" | jq -r '.[].Name')" added=
for lib in Movies:movies TV:tvshows Music:music; do
  name=${lib%%:*} type=${lib##*:}
  grep -qx "$name" <<<"$libs" && continue
  # refreshLibrary=true blocks the request on the scan; scan once, asynchronously, below
  jf "/Library/VirtualFolders?name=$name&collectionType=$type&paths=/data/media/$name&refreshLibrary=false" "${A[@]}" -X POST -d '{"LibraryOptions":{"EnableRealtimeMonitor":false}}'
  added=1; echo "library $name added"
done
[ -z "$added" ] || jf /Library/Refresh "${A[@]}" -X POST
echo "jellyfin at https://jellyfin.$DOMAIN ($NS; admin password = Infisical /$FOLDER/admin_password)"
