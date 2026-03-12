#!/usr/bin/env python3
"""Convert Infisical per-folder JSON export to nested YAML format.

Reads a JSON object from stdin where keys are folder paths and values are
arrays of secrets:

  {"/": [...], "/docker": [...], "/plex": [...]}

Produces YAML matching the infisical-backup.yml structure:

  root:
    KEY: value           # from /
    docker:
      KEY: value         # from /docker

Usage: (see scripts/infisical_backup.sh)
"""

import json
import sys

import yaml


def main():
    data = json.load(sys.stdin)
    root = {}
    folders = {}

    for path, secrets in data.items():
        folder = path.strip("/")
        for secret in secrets:
            key = secret.get("secretKey", secret.get("key", ""))
            value = secret.get("secretValue", secret.get("value", ""))
            if not key or value is None:
                continue
            if not folder:
                root[key] = value
            else:
                folders.setdefault(folder, {})[key] = value

    # Build output: root keys first, then folder dicts sorted
    output = dict(root)
    for folder in sorted(folders):
        if folders[folder]:  # skip empty folders
            output[folder] = folders[folder]

    yaml.dump(
        {"root": output},
        sys.stdout,
        default_flow_style=False,
        allow_unicode=True,
        sort_keys=False,
    )


if __name__ == "__main__":
    main()
