#!/usr/bin/env bash
# Usage: scripts/llm-bench.sh <label> [extra llama-bench args]; appends a provenance block to docs/llm-bench-results.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="${1:?label}"; shift || true
HOST="$("$ROOT/.venv/bin/ansible-inventory" -i "$ROOT/ansible/inventory/vms.yaml" --host llm | python3 -c 'import json,sys;print(json.load(sys.stdin)["ansible_host"])')"
USER="$(grep -o 'virtual_machine_username *= *"[^"]*"' "$ROOT/terraform/vars.auto.tfvars" | cut -d'"' -f2)"
OUT="$ROOT/docs/llm-bench-results.md"
ARGS="$(printf '%q ' "$LABEL" "$@")"
ssh "$USER@$HOST" "bash -s -- $ARGS" <<'REMOTE' | tee -a "$OUT"
set -euo pipefail
LABEL="$1"; shift
MODEL="$(systemctl cat llama-server | sed -n 's/.* -m \([^ ]*\).*/\1/p' | head -1)"
NCPU="$(systemctl cat llama-server | sed -n 's/.*--n-cpu-moe \([0-9]*\).*/\1/p' | head -1)"
echo; echo "## $LABEL — $(date -u +%FT%TZ)"
echo "- build: $(cat /opt/llama.cpp/bin/.commit) · driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader) · model: $(basename "$MODEL") sha256:$(sha256sum "$MODEL" | cut -c1-64) · ram: $(sudo dmidecode -t memory | grep -m1 'Configured Memory Speed' | awk '{print $4,$5}') · threads: $(nproc) · n-cpu-moe: $NCPU · args: $*"
trap 'sudo systemctl start llama-server' EXIT
sudo systemctl stop llama-server
sudo -u llm /opt/llama.cpp/bin/llama-bench -m "$MODEL" -ngl 99 --n-cpu-moe "$NCPU" -fa 1 -p 512,8192 -n 128 -r 3 -o md "$@"
REMOTE
