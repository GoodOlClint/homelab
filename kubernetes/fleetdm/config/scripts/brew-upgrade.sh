#!/bin/bash
# Fleet runs scripts as root; brew refuses root, so it runs as the owner of the prefix. omlx has its own script.
set -euo pipefail
# Fleet starts scripts in a root-only directory, which brew cannot read as the prefix owner.
cd /
brew=/opt/homebrew/bin/brew
owner=$(stat -f %Su /opt/homebrew)
as_owner() { sudo -u "$owner" -H "$brew" "$@"; }
as_owner update --quiet
outdated=$(as_owner outdated --quiet | grep -vxE '(.+/)?omlx' || true)
if [ -z "$outdated" ]; then echo "nothing outdated"; exit 0; fi
echo "upgrading: $(tr "\n" " " <<<"$outdated")"
# shellcheck disable=SC2086
as_owner upgrade $outdated
# A brew Python upgrade moves Python.app to a new Cellar path, which the application firewall treats as a
# new app and blocks behind an on-screen prompt; omlx serves through it. A firewall profile would lock these
# command-line rules out, so the firewall stays locally managed.
for app in /opt/homebrew/Cellar/python@*/*/Frameworks/Python.framework/Versions/*/Resources/Python.app; do
  [ -d "$app" ] || continue
  /usr/libexec/ApplicationFirewall/socketfilterfw --add "$app" >/dev/null
  /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "$app" >/dev/null
done
