#!/usr/bin/env bash
# Runs ON the llm guest as root: llm-bench-remote.sh <label> [llama-bench args...]
# Stops llama-server, runs llama-bench, restarts the server, writes a provenance block to
# /var/lib/llm/bench/<utc>.md and echoes it.
# Model/ngl/n-cpu-moe default to what the live unit serves; LLM_BENCH_* override them so a
# candidate model can be benched without touching the unit. LLM_BENCH_NCPU= (empty) drops the
# flag entirely, which is what a dense model needs — it has no MoE tensors to place.
set -euo pipefail
LABEL="${1:?label}"; shift || true
BIN=/opt/llama.cpp/bin
UNIT=$(systemctl cat llama-server)
MODEL="${LLM_BENCH_MODEL:-$(sed -n 's/.* -m \([^ ]*\).*/\1/p' <<<"$UNIT" | head -1)}"
NCPU="${LLM_BENCH_NCPU-$(sed -n 's/.*--n-cpu-moe \([0-9]*\).*/\1/p' <<<"$UNIT" | head -1)}"
NGL="${LLM_BENCH_NGL:-99}"
[[ -f "$MODEL" ]] || { echo "model not found: $MODEL" >&2; exit 1; }
ARGS=(-m "$MODEL" -ngl "$NGL" -fa 1 -p 512,8192 -n 128 -r 3 -o md)
if [[ -n "$NCPU" ]]; then ARGS+=(--n-cpu-moe "$NCPU"); fi
OUT=/var/lib/llm/bench/$(date -u +%Y%m%dT%H%M%SZ).md
mkdir -p "$(dirname "$OUT")"
{
  echo; echo "## $LABEL — $(date -u +%FT%TZ)"
  echo "- build: $(cat $BIN/.commit) · driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader) · model: $(basename "$MODEL") sha256:$(sha256sum "$MODEL" | cut -c1-64) · threads: $(nproc) · ngl: $NGL · n-cpu-moe: ${NCPU:-n/a (dense)} · extra args: ${*:-none} · ram: host-measured (guest dmidecode shows QEMU DIMMs)"
} > "$OUT"
trap 'systemctl reset-failed llama-server 2>/dev/null || true; systemctl start llama-server' EXIT
systemctl stop llama-server
cd /var/lib/llm && sudo -u llm "$BIN/llama-bench" "${ARGS[@]}" "$@" >> "$OUT" 2>&1
cat "$OUT"
