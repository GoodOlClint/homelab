#!/usr/bin/env bash
# Usage: scripts/llm-bench.sh <label> [llama-bench args]; copies llm-bench-remote.sh to the guest,
# runs it over ssh, appends the result block to docs/llm-bench-results.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$("$ROOT/.venv/bin/ansible-inventory" -i "$ROOT/ansible/inventory/vms.yaml" --host llm | python3 -c 'import json,sys;print(json.load(sys.stdin)["ansible_host"])')"
USER="$(grep -o 'virtual_machine_username *= *"[^"]*"' "$ROOT/terraform/vars.auto.tfvars" | cut -d'"' -f2)"
SSH=(ssh -o BatchMode=yes "$USER@$HOST")
scp -q -o BatchMode=yes "$ROOT/scripts/llm-bench-remote.sh" "$USER@$HOST:/tmp/llm-bench-remote.sh"
"${SSH[@]}" sudo bash /tmp/llm-bench-remote.sh "$(printf '%q ' "$@")" | tee -a "$ROOT/docs/llm-bench-results.md"
