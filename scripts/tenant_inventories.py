#!/usr/bin/env python3
"""Tenant Ansible inventories for `make update` (docs/tenant-edges-plan.md step 1.8).

  tenant_inventories.py [--bindings PATH] args    print "-i <path> ..." (nothing when none bound)
  tenant_inventories.py [--bindings PATH] check   validate every bound path, exit 1 on any failure

An absent bindings file or no non-empty `tenants.<t>.inventory` means no tenants.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys

import yaml


def bound_paths(bindings):
    if not os.path.exists(bindings):
        return []
    try:
        with open(bindings) as f:
            doc = yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError) as e:
        sys.exit(f"tenant inventories: cannot read {bindings}: {e}")
    tenants = doc.get("tenants") or {}
    if not isinstance(tenants, dict):
        sys.exit(f"tenant inventories: {bindings}: 'tenants' must be a map")
    paths = []
    for name, spec in tenants.items():
        path = (spec or {}).get("inventory") or ""
        if str(path).strip():
            paths.append((name, str(path).strip()))
    return paths


def host_count(path):
    exe = os.path.join(os.path.dirname(sys.executable), "ansible-inventory")
    if not os.path.exists(exe):
        exe = shutil.which("ansible-inventory") or sys.exit("tenant inventories: ansible-inventory not found")
    r = subprocess.run([exe, "-i", path, "--list"], capture_output=True, text=True,
                       env={**os.environ, "ANSIBLE_CONFIG": "ansible/ansible.cfg"})
    if r.returncode != 0:
        raise ValueError(f"ansible-inventory failed: {r.stderr.strip() or r.stdout.strip()}")
    return len(json.loads(r.stdout).get("_meta", {}).get("hostvars", {}))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bindings", default="network-data/local/tenants.yaml")
    ap.add_argument("mode", choices=["args", "check"])
    a = ap.parse_args()
    paths = bound_paths(a.bindings)
    if a.mode == "args":
        print(" ".join(f"-i {p}" for _, p in paths))
        return
    bad = []
    for name, p in paths:
        if any(c.isspace() for c in p):
            bad.append(f"tenant '{name}': inventory path contains whitespace: {p}")
        elif not os.path.isabs(p) or not os.path.exists(p):
            bad.append(f"tenant '{name}': inventory path is not an existing absolute path: {p}")
        else:
            try:
                if host_count(p) == 0:
                    bad.append(f"tenant '{name}': inventory has no hosts: {p}")
            except (ValueError, OSError) as e:
                bad.append(f"tenant '{name}': inventory unreadable: {p}: {e}")
    if bad:
        sys.exit("make update refused, tenant inventory check failed:\n  " + "\n  ".join(bad))


if __name__ == "__main__":
    main()
