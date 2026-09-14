#!/usr/bin/env bash
# Runs ON the llm guest as root: llm-spec-ab-remote.sh <model.gguf> [extra args for the MTP arm, e.g. --spec-draft-n-max 2]
# llama-bench cannot drive speculative decoding, so this stops the unit, serves the model twice
# (plain, then --spec-type draft-mtp) at the router preset's [*] -c/-t/extra args, and reports
# /completion timings for a fixed prompt, 3 runs each. Restarts both servers on exit.
set -euo pipefail
MODEL="${1:?model}"; shift || true
BIN=/opt/llama.cpp/bin
GLOBAL=$(awk '/^\[\*\]/{on=1; next} /^\[/{on=0} on && / = /' /etc/llama-server/models.ini)
CTX=$(sed -n 's/^ctx-size = //p' <<<"$GLOBAL")
THREADS=$(sed -n 's/^threads = //p' <<<"$GLOBAL")
EXTRA=$(grep -vE '^(ctx-size|threads|n-gpu-layers|metrics) = ' <<<"$GLOBAL" | awk -F' = ' '{printf "--%s", $1; if ($2 != "true") printf " %s", $2; printf " "}')
PORT=8083
PROMPT="Write a detailed, step-by-step explanation of how a TCP three-way handshake works, then describe what happens when a segment is lost, including retransmission timers and congestion window behaviour."
trap 'kill $PID 2>/dev/null || true; systemctl reset-failed llama-server llama-embed 2>/dev/null || true; systemctl start llama-server llama-embed' EXIT
systemctl stop llama-server llama-embed
serve() {
  sudo -u llm "$BIN/llama-server" --host 127.0.0.1 --port $PORT -m "$MODEL" -ngl 99 -c "$CTX" -t "$THREADS" $EXTRA "$@" >/tmp/spec-ab.log 2>&1 &
  PID=$!
  for _ in $(seq 120); do curl -sf localhost:$PORT/health >/dev/null 2>&1 && return; sleep 2; done
  echo "server did not come up:"; tail -20 /tmp/spec-ab.log; exit 1
}
run() {
  echo "### $1 ($(grep -c "draft" /tmp/spec-ab.log) draft log lines)"
  for i in 1 2 3; do
    curl -s localhost:$PORT/completion -H 'Content-Type: application/json' \
      -d "$(jq -cn --arg p "$PROMPT" '{prompt:$p,n_predict:256,temperature:0,cache_prompt:false}')" \
      | jq -r --arg i "$i" '"run \($i): tg \(.timings.predicted_per_second|floor) t/s · pp \(.timings.prompt_per_second|floor) t/s · \(.timings.predicted_n) tok · draft \(.timings.draft_n // 0) / accepted \(.timings.draft_n_accepted // 0)"'
  done
  kill $PID; wait $PID 2>/dev/null || true
}
echo "## spec-decoding A/B — $(basename "$MODEL") · build $(cat $BIN/.commit) · mesa $(dpkg-query -W -f='${Version}' mesa-vulkan-drivers) · -c $CTX -t $THREADS $EXTRA · $(date -u +%FT%TZ)"
serve; run "plain"
serve --spec-type draft-mtp "$@"; run "--spec-type draft-mtp ${*:-}"
