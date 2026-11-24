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
