#!/usr/bin/env python3
"""Convert Infisical per-folder JSON export to the secrets.sops.yml structure.

Reads a JSON object from stdin where keys are folder paths and values are
arrays of secrets (null allowed for empty folders):

  {"/": [...], "/docker": [...], "/plex-services": null}

Produces YAML that round-trips through scripts/seed_infisical.sh:

  secrets:
    stray_root_key: value    # from / (root should be empty — flagged on stderr)
    docker:
      key: value             # nested dict per folder, seeded back to /docker
    plex_services:           # hyphens → underscores (seed reverses this)
      key: value

Exits non-zero if the export contains zero secrets total — that means auth or
the CLI is silently broken, and an empty file must never replace a real backup.

Usage: (see scripts/infisical_backup.sh)
"""

import json
import sys

import yaml


def parse(data):
    root = {}
    folders = {}
    for path, secrets in data.items():
        folder = path.strip("/").replace("-", "_")
        for secret in secrets or []:
            key = secret.get("secretKey", secret.get("key", ""))
            value = secret.get("secretValue", secret.get("value", ""))
            if not key or value is None:
                continue
            if not folder:
                root[key] = value
            else:
                folders.setdefault(folder, {})[key] = value
    return root, folders


def main():
    data = json.load(sys.stdin)
    root, folders = parse(data)

    for path in sorted(data):
        folder = path.strip("/").replace("-", "_")
        n = len(root) if not folder else len(folders.get(folder, {}))
        print(f"  {path or '/'}: {n} secrets", file=sys.stderr)

    if root:
        print(f"WARNING: root / holds {len(root)} secrets — it should be empty "
              "(see CLAUDE.md: never write to Infisical root)", file=sys.stderr)

    output = dict(root)
    for folder in sorted(folders):
        output[folder] = folders[folder]

    total = len(root) + sum(len(v) for v in folders.values())
    if total == 0:
        print("ERROR: export contains zero secrets — refusing to write an "
              "empty backup (auth or CLI likely broken)", file=sys.stderr)
        sys.exit(1)

    yaml.dump(
        {"secrets": output},
        sys.stdout,
        default_flow_style=False,
        allow_unicode=True,
        sort_keys=False,
    )


if __name__ == "__main__":
    main()
