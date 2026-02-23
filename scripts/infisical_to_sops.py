#!/usr/bin/env python3
"""Convert Infisical JSON export to SOPS-compatible YAML format.

Usage: infisical secrets list --env prod --path / --format json | python3 scripts/infisical_to_sops.py
"""

import json
import sys

import yaml


def main():
    data = json.load(sys.stdin)
    secrets = {}

    for secret in data:
        key = secret.get("secretKey", secret.get("key", "")).lower()
        value = secret.get("secretValue", secret.get("value", ""))
        if key and value:
            secrets[key] = value

    output = {"secrets": secrets}
    yaml.dump(output, sys.stdout, default_flow_style=False, allow_unicode=True)


if __name__ == "__main__":
    main()
