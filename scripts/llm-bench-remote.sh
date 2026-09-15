#!/usr/bin/env bash
# Runs ON the llm guest as root: llm-bench-remote.sh <label> [llama-bench args...]
# Stops both llama-servers, runs llama-bench, restarts them, writes a provenance block to
# /var/lib/llm/bench/<utc>.md and echoes it.
# Model/ngl/n-cpu-moe default to the router preset's startup model; LLM_BENCH_* override them so a
# candidate model can be benched without touching the unit. LLM_BENCH_MODEL may list several
# paths (colon-separated, like PATH), one llama-bench run each. LLM_BENCH_NCPU= (empty) drops the
# flag entirely, which is what a dense model needs — it has no MoE tensors to place.
# LLM_BENCH_BASE replaces the default test matrix (llama-bench appends repeated list flags instead of overriding).
set -euo pipefail
LABEL="${1:?label}"; shift || true
BIN=${LLM_BENCH_BIN:-/opt/llama.cpp/bin}
PRESET=/etc/llama-server/models.ini
SERVED=$(awk -F' = ' '/^model = /{m=$2} /^load-on-startup = true/{print m; exit}' "$PRESET")
IFS=: read -ra MODELS <<<"${LLM_BENCH_MODEL:-$SERVED}"
NCPU="${LLM_BENCH_NCPU-$(sed -n 's/^n-cpu-moe = \([0-9]*\)$/\1/p' "$PRESET" | head -1)}"
NGL="${LLM_BENCH_NGL:-99}"
for MODEL in "${MODELS[@]}"; do [[ -f "$MODEL" ]] || { echo "model not found: $MODEL" >&2; exit 1; }; done
OUT=/var/lib/llm/bench/$(date -u +%Y%m%dT%H%M%SZ).md
mkdir -p "$(dirname "$OUT")"
MESA=$(dpkg-query -W -f='${Version}' mesa-vulkan-drivers)
{
  echo; echo "## $LABEL — $(date -u +%FT%TZ)"
  for MODEL in "${MODELS[@]}"; do
    echo "- build: $(cat $BIN/.commit) · mesa: $MESA · model: $(basename "$MODEL") sha256:$(sha256sum "$MODEL" | cut -c1-64) · threads: $(nproc) · ngl: $NGL · n-cpu-moe: ${NCPU:-n/a (dense)} · extra args: ${*:-none} · ram: host-measured (guest dmidecode shows QEMU DIMMs)"
  done
} > "$OUT"
trap 'cat "$OUT"; systemctl reset-failed llama-server llama-embed 2>/dev/null || true; systemctl start llama-server llama-embed' EXIT
systemctl stop llama-server llama-embed
for MODEL in "${MODELS[@]}"; do
  read -ra BASE <<<"${LLM_BENCH_BASE:--fa 1 -p 512,8192 -n 128 -r 3 -o md}"
  ARGS=(-m "$MODEL" -ngl "$NGL" "${BASE[@]}")
  if [[ -n "$NCPU" ]]; then ARGS+=(--n-cpu-moe "$NCPU"); fi
  cd /var/lib/llm && sudo -u llm "$BIN/llama-bench" "${ARGS[@]}" "$@" >> "$OUT" 2>&1 || echo "- **FAILED** ($?): $(basename "$MODEL")" >> "$OUT"
done
