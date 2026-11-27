#!/usr/bin/env python3
"""Pins scripts/tenant_inventories.py: bindings loading and the fleet-overlap preflight."""
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "tenant_inventories.py")


def write(path, text):
    with open(path, "w") as f:
        f.write(text)


def inv(path, host, group="tgroup"):
    write(path, f"all:\n  children:\n    {group}:\n      hosts:\n        {host}:\n          ansible_host: 127.0.0.1\n")


def run(mode, bindings, *fleet):
    cmd = [sys.executable, SCRIPT, "--bindings", bindings]
    for f in fleet:
        cmd += ["--fleet", f]
    r = subprocess.run(cmd + [mode], capture_output=True, text=True, cwd=ROOT)
    return r.returncode, r.stdout + r.stderr


def main():
    with tempfile.TemporaryDirectory() as d:
        fleet = f"{d}/fleet.yaml"
        inv(fleet, "fleethost", "fleetgroup")
        good, dup_host, dup_group, reserved = (f"{d}/{n}.yaml" for n in ("good", "duph", "dupg", "res"))
        inv(good, "tenanthost")
        inv(dup_host, "fleethost")
        inv(dup_group, "tenanthost", "fleetgroup")
        inv(reserved, "infisical")
        b = f"{d}/b.yaml"

        rc, _ = run("check", f"{d}/absent.yaml", fleet)
        assert rc == 0, "absent bindings file must be empty and pass"
        for bad in ("tenants: [", "foo: 1\n", "tenants:\n", ""):
            write(b, bad)
            rc, out = run("check", b, fleet)
            assert rc != 0, f"invalid bindings {bad!r} must fail: {out}"
        write(b, f"tenants:\n  a:\n    inventory: {good}\n")
        rc, out = run("check", b, fleet)
        assert rc == 0, out
        rc, out = run("list", b, fleet)
        assert out.split() == [good], out
        for name, path in (("host alias", dup_host), ("group name", dup_group), ("reserved name", reserved)):
            write(b, f"tenants:\n  a:\n    inventory: {path}\n")
            rc, out = run("check", b, fleet)
            assert rc != 0, f"{name} overlap must fail: {out}"
    print("tenant inventories: PASS")


if __name__ == "__main__":
    main()
