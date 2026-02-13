#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys


REQUIRED_PRIVATE_FIELDS = {"vlan_id", "interface", "cidr_v4"}


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def parse_public_zones(text: str) -> list[str]:
    zones: list[str] = []
    in_zones = False
    for line in text.splitlines():
        if line.strip() == "zones:":
            in_zones = True
            continue
        if in_zones and re.match(r"^[a-zA-Z0-9_-]+:\s*$", line):
            break
        if in_zones:
            match = re.match(r"^\s{2}([a-zA-Z0-9_-]+):\s*\{\}\s*$", line)
            if match:
                zones.append(match.group(1))
    return sorted(set(zones))


def parse_service_groups(text: str) -> list[str]:
    groups: list[str] = []
    in_aliases = False
    in_service_groups = False

    for line in text.splitlines():
        if line.strip() == "aliases:":
            in_aliases = True
            in_service_groups = False
            continue
        if in_aliases and re.match(r"^[a-zA-Z0-9_-]+:\s*$", line):
            in_aliases = False
            in_service_groups = False
        if in_aliases and line.strip() == "service_groups:":
            in_service_groups = True
            continue
        if in_service_groups and re.match(r"^\s{2}[a-zA-Z0-9_-]+:\s*$", line):
            in_service_groups = False
        if in_service_groups:
            match = re.match(r"^\s{4}([a-zA-Z0-9_-]+):\s*$", line)
            if match:
                groups.append(match.group(1))
    return sorted(set(groups))


def parse_rules(text: str) -> list[dict[str, object]]:
    rules: list[dict[str, object]] = []
    current: dict[str, object] | None = None

    for line in text.splitlines():
        start = re.match(r"^\s{2}-\s+id:\s+([a-zA-Z0-9_-]+)\s*$", line)
        if start:
            if current:
                rules.append(current)
            current = {"id": start.group(1)}
            continue

        if current is None:
            continue

        field_match = re.match(r"^\s{4}(action|from_zone|to_zone|service|state|note):\s+(.+?)\s*$", line)
        if field_match:
            key = field_match.group(1)
            value = field_match.group(2).strip()
            if value.startswith('"') and value.endswith('"') and len(value) >= 2:
                value = value[1:-1]
            current[key] = value
            continue

        log_match = re.match(r"^\s{4}log:\s+(true|false)\s*$", line)
        if log_match:
            current["log"] = log_match.group(1) == "true"

    if current:
        rules.append(current)

    return sorted(rules, key=lambda item: str(item.get("id", "")))


def parse_private_zone_fields(text: str) -> dict[str, set[str]]:
    fields_by_zone: dict[str, set[str]] = {}
    in_zones = False
    current_zone: str | None = None

    for line in text.splitlines():
        if line.strip() == "zones:":
            in_zones = True
            continue
        if in_zones and re.match(r"^[a-zA-Z0-9_-]+:\s*$", line):
            break

        if not in_zones:
            continue

        zone_match = re.match(r"^\s{2}([a-zA-Z0-9_-]+):\s*$", line)
        if zone_match:
            current_zone = zone_match.group(1)
            fields_by_zone.setdefault(current_zone, set())
            continue

        if current_zone is None:
            continue

        field_match = re.match(r"^\s{4}([a-zA-Z0-9_-]+):\s+.*$", line)
        if field_match:
            fields_by_zone[current_zone].add(field_match.group(1))

    return fields_by_zone


def build_artifact(public_path: pathlib.Path, private_path: pathlib.Path) -> dict[str, object]:
    public_text = public_path.read_text(encoding="utf-8")
    private_text = private_path.read_text(encoding="utf-8") if private_path.exists() else ""

    zones = parse_public_zones(public_text)
    service_groups = parse_service_groups(public_text)
    rules = parse_rules(public_text)
    private_fields = parse_private_zone_fields(private_text) if private_text else {}

    zone_entries: list[dict[str, object]] = []
    for zone in zones:
        fields = private_fields.get(zone, set())
        missing_required = sorted(REQUIRED_PRIVATE_FIELDS - fields)
        zone_entries.append(
            {
                "name": zone,
                "has_private_binding": bool(fields),
                "private_required_fields_missing": missing_required,
            }
        )

    return {
        "artifact_version": 1,
        "inputs": {
            "public_policy_path": str(public_path),
            "public_policy_sha256": sha256_text(public_text),
            "private_bindings_path": str(private_path),
            "private_bindings_sha256": sha256_text(private_text) if private_text else None,
        },
        "summary": {
            "zone_count": len(zones),
            "service_group_count": len(service_groups),
            "rule_count": len(rules),
            "private_zone_bindings_found": sum(1 for item in zone_entries if item["has_private_binding"]),
        },
        "zones": zone_entries,
        "service_groups": service_groups,
        "rules": rules,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Render deterministic policy artifact from policy inputs")
    parser.add_argument("--public", default="network-data/public_policy.yaml", help="Path to public policy YAML")
    parser.add_argument(
        "--private",
        default="network-data/private_bindings.example.yaml",
        help="Path to private bindings YAML",
    )
    parser.add_argument(
        "--output",
        default="network-data/generated/policy_render.public.json",
        help="Output artifact path",
    )
    parser.add_argument("--check", action="store_true", help="Check output is up to date instead of writing")
    args = parser.parse_args()

    public_path = pathlib.Path(args.public)
    private_path = pathlib.Path(args.private)
    output_path = pathlib.Path(args.output)

    if not public_path.exists():
        print(f"ERROR: missing public policy file: {public_path}")
        return 2
    if not private_path.exists():
        print(f"ERROR: missing private bindings file: {private_path}")
        return 2

    artifact = build_artifact(public_path, private_path)
    rendered = json.dumps(artifact, indent=2, sort_keys=True) + "\n"

    if args.check:
        if not output_path.exists():
            print(f"ERROR: missing artifact file: {output_path}")
            return 1
        current = output_path.read_text(encoding="utf-8")
        if current != rendered:
            print(f"ERROR: artifact is stale, rerun renderer: {output_path}")
            return 1
        print(f"OK: artifact is up to date: {output_path}")
        return 0

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(rendered, encoding="utf-8")
    print(f"Wrote artifact: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
