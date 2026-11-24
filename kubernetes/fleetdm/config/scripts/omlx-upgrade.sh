#!/bin/bash
# Run only when no inference is running: the restart drops in-flight requests.
set -euo pipefail
# Fleet starts scripts in a root-only directory, which brew cannot read as the prefix owner.
cd /
brew=/opt/homebrew/bin/brew
owner=$(stat -f %Su /opt/homebrew)
before=$(sudo -u "$owner" -H "$brew" list --versions omlx)
sudo -u "$owner" -H "$brew" update --quiet
sudo -u "$owner" -H "$brew" upgrade omlx
after=$(sudo -u "$owner" -H "$brew" list --versions omlx)
if [ "$before" = "$after" ]; then echo "$after already current; no restart"; exit 0; fi
echo "$before -> $after"
# A brew Python upgrade moves Python.app to a new Cellar path, which the application firewall treats as a
# new app and blocks behind an on-screen prompt; omlx serves through it. A firewall profile would lock these
# command-line rules out, so the firewall stays locally managed.
for app in /opt/homebrew/Cellar/python@*/*/Frameworks/Python.framework/Versions/*/Resources/Python.app; do
  [ -d "$app" ] || continue
  /usr/libexec/ApplicationFirewall/socketfilterfw --add "$app" >/dev/null
  /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "$app" >/dev/null
done
launchctl kickstart -k system/local.omlx
for _ in $(seq 1 60); do
  if curl -fsS -m 2 http://127.0.0.1:8000/health >/dev/null; then echo "omlx healthy"; exit 0; fi
  sleep 2
done
echo "omlx did not answer /health within 120 s" >&2
exit 1
