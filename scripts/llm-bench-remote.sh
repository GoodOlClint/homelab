#!/usr/bin/env bash
# Runs ON the llm guest as root: llm-bench-remote.sh <label> [llama-bench args...]
# Stops llama-server, runs llama-bench, restarts the server, writes a provenance block to
# /var/lib/llm/bench/<utc>.md and echoes it.
set -euo pipefail
LABEL="${1:?label}"; shift || true
BIN=/opt/llama.cpp/bin
UNIT=$(systemctl cat llama-server)
MODEL=$(sed -n 's/.* -m \([^ ]*\).*/\1/p' <<<"$UNIT" | head -1)
NCPU=$(sed -n 's/.*--n-cpu-moe \([0-9]*\).*/\1/p' <<<"$UNIT" | head -1)
OUT=/var/lib/llm/bench/$(date -u +%Y%m%dT%H%M%SZ).md
mkdir -p "$(dirname "$OUT")"
{
  echo; echo "## $LABEL — $(date -u +%FT%TZ)"
  echo "- build: $(cat $BIN/.commit) · driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader) · model: $(basename "$MODEL") sha256:$(sha256sum "$MODEL" | cut -c1-64) · threads: $(nproc) · n-cpu-moe: $NCPU · extra args: ${*:-none} · ram: host-measured (guest dmidecode shows QEMU DIMMs)"
} > "$OUT"
trap 'systemctl start llama-server' EXIT
systemctl stop llama-server
cd /var/lib/llm && sudo -u llm "$BIN/llama-bench" -m "$MODEL" -ngl 99 --n-cpu-moe "$NCPU" -fa 1 -p 512,8192 -n 128 -r 3 -o md "$@" >> "$OUT" 2>&1
cat "$OUT"
