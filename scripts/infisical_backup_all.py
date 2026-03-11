#!/usr/bin/env python3
"""Export ALL Infisical secrets (all folders) to SOPS-compatible nested YAML.

Iterates all known Infisical folders and produces a nested dict structure
matching what infisical_login.yml expects for restore via seed_infisical.sh.

Usage: python3 scripts/infisical_backup_all.py > ansible/group_vars/secrets.sops.yml.bak
Then encrypt: sops --encrypt --in-place ansible/group_vars/secrets.sops.yml.bak
"""
import json
import subprocess
import sys
import yaml

FOLDERS = [
    "shared", "monitoring", "plex", "plex-services",
    "docker", "vps", "pfsense", "pbs", "infrastructure",
    "homepage",
]


def export_folder(path):
    """Export secrets from a single Infisical folder."""
    result = subprocess.run(
        ["infisical", "secrets", "list", "--env", "prod",
         "--path", f"/{path}", "--format", "json"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"WARNING: Failed to export /{path}: {result.stderr.strip()}", file=sys.stderr)
        return {}
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {}
    secrets = {}
    for secret in data:
        key = secret.get("secretKey", secret.get("key", ""))
        value = secret.get("secretValue", secret.get("value", ""))
        if key and value:
            secrets[key] = value
    return secrets


def main():
    output = {"secrets": {}}
    for folder in FOLDERS:
        secrets = export_folder(folder)
        if secrets:
            # Use underscore key names matching infisical_login.yml convention
            dict_key = folder.replace("-", "_")
            output["secrets"][dict_key] = secrets
    yaml.dump(output, sys.stdout, default_flow_style=False, allow_unicode=True)


if __name__ == "__main__":
    main()
