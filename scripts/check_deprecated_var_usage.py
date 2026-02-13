#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fnmatch
import pathlib
import re
import sys


DEPRECATED_VARS = [
    "openobserve_root_user_pass",
    "grafana_admin_password",
    "proxmox_token_value",
    "unifi_admin_password",
    "unifi_password",
    "synology_admin_password",
    "cloudflared_tunnel_token",
    "pbs_admin_password",
    "pbs_backup_user_password",
    "pbs_backup_token",
    "pbs_api_token",
    "pbs_monitoring_token",
    "postgres_password",
    "plex_smb_pass",
]

INCLUDE_SUFFIXES = {".yml", ".yaml", ".j2", ".py", ".md", ".sh", ".tf", ""}

ALLOWED_GLOBS = [
    "ansible/group_vars/all.yml",
    "ansible/group_vars/secrets.sops.example.yml",
    "ansible/group_vars/secrets.sops.yml",
    "ansible/roles/juju4.openobserve/**",
    "docs/**",
    "scripts/audit_deprecated_vars.py",
    "scripts/check_deprecated_var_usage.py",
]


def is_allowed(path: pathlib.Path, root: pathlib.Path) -> bool:
    rel = path.relative_to(root).as_posix()
    for pattern in ALLOWED_GLOBS:
        if fnmatch.fnmatch(rel, pattern):
            return True
    return False


def iter_files(root: pathlib.Path):
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        if any(part in rel for part in [".git/", ".venv/", "node_modules/", "terraform/.terraform/"]):
            continue
        if path.suffix.lower() not in INCLUDE_SUFFIXES and path.name not in {"Makefile"}:
            continue
        yield path


def main() -> int:
    parser = argparse.ArgumentParser(description="Fail if deprecated variables are used outside allowed legacy paths")
    parser.add_argument("--root", default=".", help="Repository root")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero on findings")
    args = parser.parse_args()

    root = pathlib.Path(args.root).resolve()
    violations: list[str] = []

    patterns = {name: re.compile(rf"\b{re.escape(name)}\b") for name in DEPRECATED_VARS}

    for file_path in iter_files(root):
        rel_path = file_path.relative_to(root).as_posix()
        if not rel_path.startswith("ansible/"):
            continue
        if is_allowed(file_path, root):
            continue
        content = file_path.read_text(encoding="utf-8", errors="ignore")
        lines = content.splitlines()
        for line_no, line in enumerate(lines, start=1):
            for var_name, pattern in patterns.items():
                if f"secrets.{var_name}" in line:
                    continue
                if pattern.search(line):
                    violations.append(f"{rel_path}:{line_no}: {var_name}")

    if violations:
        label = "ERROR" if args.strict else "WARN"
        print(f"{label}: deprecated variable usage found in disallowed paths:")
        for item in violations:
            print(f"  - {item}")
        if args.strict:
            return 1
        return 0

    print("OK: deprecated variable usage is constrained to allowed legacy paths")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
