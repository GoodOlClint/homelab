#!/usr/bin/env bash
# Usage: scripts/llm-bench.sh <label> [llama-bench args]; copies llm-bench-remote.sh to the guest,
# runs it over ssh, appends the result block to docs/llm-bench-results.md.
# `scripts/llm-bench.sh suite <label>` benches the served model plus every llm_bench_models entry.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == suite ]]; then
  shift
  LLM_BENCH_MODEL="$("$ROOT/.venv/bin/python3" -c '
import yaml; d = yaml.safe_load(open("ansible/roles/llm/defaults/main.yml"))
print(":".join(d["llm_models_dir"] + "/" + f for f in [d["llm_model_file"]] + [m["file"] for m in d["llm_bench_models"]]))' )"
  export LLM_BENCH_MODEL LLM_BENCH_NCPU=
fi
HOST="$("$ROOT/.venv/bin/ansible-inventory" -i "$ROOT/ansible/inventory/vms.yaml" --host llm | python3 -c 'import json,sys;print(json.load(sys.stdin)["ansible_host"])')"
USER="$(grep -o 'virtual_machine_username *= *"[^"]*"' "$ROOT/terraform/vars.auto.tfvars" | cut -d'"' -f2)"
SSH=(ssh -o BatchMode=yes "$USER@$HOST")
scp -q -o BatchMode=yes "$ROOT/scripts/llm-bench-remote.sh" "$USER@$HOST:/tmp/llm-bench-remote.sh"
ENVS="$(env | grep '^LLM_BENCH_' | tr '\n' ' ' || true)"
"${SSH[@]}" sudo env $ENVS bash /tmp/llm-bench-remote.sh "$(printf '%q ' "$@")" | tee -a "$ROOT/docs/llm-bench-results.md"
