#!/bin/bash
# Run only when no inference is running: the restart drops in-flight requests.
set -euo pipefail
brew=/opt/homebrew/bin/brew
owner=$(stat -f %Su /opt/homebrew)
before=$(sudo -u "$owner" -H "$brew" list --versions omlx)
sudo -u "$owner" -H "$brew" update --quiet
sudo -u "$owner" -H "$brew" upgrade omlx
after=$(sudo -u "$owner" -H "$brew" list --versions omlx)
echo "$before -> $after"
launchctl kickstart -k system/local.omlx
for _ in $(seq 1 60); do
  if curl -fsS -m 2 http://127.0.0.1:8000/health >/dev/null; then echo "omlx healthy"; exit 0; fi
  sleep 2
done
echo "omlx did not answer /health within 120 s" >&2
exit 1
