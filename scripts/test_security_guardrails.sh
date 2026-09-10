#!/bin/bash
# Offline pins for security_guardrails.sh (#22): the .example exemption is a suffix, not a
# substring; a missing vlans.yaml fails outside CI and warns inside it. Runs in a scratch repo.
set -euo pipefail
GUARD="$(cd "$(dirname "$0")/.." && pwd)/scripts/security_guardrails.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cd "$T" && git init -q && git config user.email t@t && git config user.name t
printf "seed\n" > README.md
git add -A && git commit -qm base
# gitleaks runs after the leak scan; a stub keeps the test hermetic
mkdir -p bin && printf '#!/bin/sh\nexit 0\n' > bin/gitleaks && chmod +x bin/gitleaks
export PATH="$T/bin:$PATH" GUARDRAILS_INTERNAL_DOMAINS="example.test"

stage() { printf '%s\n' "$2" > "$1"; git add "$1"; }
expect() { local want=$1; shift; set +e; "$@" >/dev/null 2>&1; local rc=$?; set -e
  [[ "$rc" -eq "$want" ]] || { echo "FAIL: $* -> rc=$rc, want $want"; exit 1; }; }

stage foo-example.md "host example.test"; expect 1 bash "$GUARD" --staged; git rm -qf --cached foo-example.md; rm foo-example.md
stage vlans.example.yaml 'service_domain: "example.test"'; expect 0 bash "$GUARD" --staged; git rm -qf --cached vlans.example.yaml; rm vlans.example.yaml
stage notes.md "host 10.0.0.$((9))"; expect 1 bash "$GUARD" --staged; git rm -qf --cached notes.md; rm notes.md
stage plain.md "nothing here"
expect 1 env -u GUARDRAILS_INTERNAL_DOMAINS -u CI bash "$GUARD" --staged
expect 0 env -u GUARDRAILS_INTERNAL_DOMAINS CI=1 bash "$GUARD" --staged
echo "PASS: security_guardrails pins"
