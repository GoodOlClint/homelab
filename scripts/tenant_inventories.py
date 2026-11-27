#!/usr/bin/env python3
"""Tenant Ansible inventories for `make update` (docs/tenant-edges-plan.md step 1.8).

  tenant_inventories.py [--bindings PATH] list    print one bound inventory path per line
  tenant_inventories.py [--bindings PATH] check   validate every bound path, exit 1 on any failure

An absent bindings file or no non-empty `tenants.<t>.inventory` means no tenants. A present
file that is invalid or has no `tenants` map fails. Each inventory is patched in its own
ansible-playbook run; `check` rejects one that shares a host alias or group name with the
fleet inventories or names infisical, proxmox or mcp.
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
            doc = yaml.safe_load(f)
    except (OSError, yaml.YAMLError) as e:
        sys.exit(f"tenant inventories: cannot read {bindings}: {e}")
    tenants = doc.get("tenants") if isinstance(doc, dict) else None
    if not isinstance(tenants, dict):
        sys.exit(f"tenant inventories: {bindings}: 'tenants' must be a map")
    paths = []
    for name, spec in tenants.items():
        path = (spec or {}).get("inventory") or ""
        if str(path).strip():
            paths.append((name, str(path).strip()))
    return paths


FLEET_INVENTORIES = ["ansible/inventory/vms.yaml", "ansible/inventory/proxmox.yaml", "ansible/inventory/vps.yaml"]
RESERVED = {"infisical", "proxmox", "mcp"}


def inventory_names(paths):
    """(host aliases, group names) of the merged inventories."""
    hosts, groups = set(), set()
    for path in paths:
        listing = load_inventory(path)
        hosts |= set(listing.get("_meta", {}).get("hostvars", {}))
        groups |= {g for g in listing if g not in ("_meta", "all", "ungrouped")}
    return hosts, groups


def load_inventory(path):
    exe = os.path.join(os.path.dirname(sys.executable), "ansible-inventory")
    if not os.path.exists(exe):
        exe = shutil.which("ansible-inventory") or sys.exit("tenant inventories: ansible-inventory not found")
    r = subprocess.run([exe, "-i", path, "--list"], capture_output=True, text=True,
                       env={**os.environ, "ANSIBLE_CONFIG": "ansible/ansible.cfg"})
    if r.returncode != 0:
        raise ValueError(f"ansible-inventory failed: {r.stderr.strip() or r.stdout.strip()}")
    return json.loads(r.stdout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bindings", default="network-data/local/tenants.yaml")
    ap.add_argument("--fleet", action="append", help="fleet inventory (repeatable); default vms, proxmox, vps")
    ap.add_argument("mode", choices=["list", "check"])
    a = ap.parse_args()
    paths = bound_paths(a.bindings)
    if a.mode == "list":
        for _, p in paths:
            print(p)
        return
    fleet = [p for p in (a.fleet if a.fleet is not None else FLEET_INVENTORIES) if os.path.exists(p)]
    fleet_hosts, fleet_groups = inventory_names(fleet) if paths else (set(), set())
    bad = []
    for name, p in paths:
        if any(c.isspace() for c in p):
            bad.append(f"tenant '{name}': inventory path contains whitespace: {p}")
        elif not os.path.isabs(p) or not os.path.exists(p):
            bad.append(f"tenant '{name}': inventory path is not an existing absolute path: {p}")
        else:
            try:
                hosts, groups = inventory_names([p])
                if not hosts:
                    bad.append(f"tenant '{name}': inventory has no hosts: {p}")
                for n in sorted((hosts & fleet_hosts) | (groups & fleet_groups) | ((hosts | groups) & RESERVED)):
                    bad.append(f"tenant '{name}': host or group '{n}' is a fleet or reserved name: {p}")
            except (ValueError, OSError) as e:
                bad.append(f"tenant '{name}': inventory unreadable: {p}: {e}")
    if bad:
        sys.exit("make update refused, tenant inventory check failed:\n  " + "\n  ".join(bad))


if __name__ == "__main__":
    main()
