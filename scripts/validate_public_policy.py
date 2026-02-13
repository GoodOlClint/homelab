#!/usr/bin/env python3
"""Validate that publishable network policy files do not contain IP/CIDR literals."""

from __future__ import annotations

import pathlib
import re
import sys

IPV4_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
CIDR_V4_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}/(?:[0-9]|[1-2][0-9]|3[0-2])\b")
IPV6_RE = re.compile(r"\b(?:[0-9a-fA-F]{0,4}:){2,}[0-9a-fA-F]{0,4}\b")
CIDR_V6_RE = re.compile(r"\b(?:[0-9a-fA-F]{0,4}:){2,}[0-9a-fA-F]{0,4}/(?:\d|[1-9]\d|1[01]\d|12[0-8])\b")


def extract_zones(text: str) -> set[str]:
    zones: set[str] = set()
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
                zones.add(match.group(1))
    return zones


def extract_service_groups(text: str) -> set[str]:
    services: set[str] = set()
    in_aliases = False
    in_service_groups = False

    for line in text.splitlines():
        stripped = line.strip()
        if stripped == "aliases:":
            in_aliases = True
            in_service_groups = False
            continue
        if in_aliases and re.match(r"^[a-zA-Z0-9_-]+:\s*$", line):
            in_aliases = False
            in_service_groups = False
        if in_aliases and stripped == "service_groups:":
            in_service_groups = True
            continue
        if in_service_groups and re.match(r"^\s{2}[a-zA-Z0-9_-]+:\s*$", line):
            in_service_groups = False
        if in_service_groups:
            match = re.match(r"^\s{4}([a-zA-Z0-9_-]+):\s*$", line)
            if match:
                services.add(match.group(1))
    return services


def validate_rule_structure(text: str, zones: set[str], services: set[str]) -> list[str]:
    errors: list[str] = []
    rule_ids: set[str] = set()

    current_rule: dict[str, str] | None = None

    def finalize_rule(rule: dict[str, str] | None) -> None:
        if not rule:
            return

        required_fields = ("id", "action", "from_zone", "to_zone", "service", "state")
        missing = [field for field in required_fields if field not in rule]
        if missing:
            errors.append(f"rule missing required fields: {', '.join(missing)}")
            return

        rule_id = rule["id"]
        if rule_id in rule_ids:
            errors.append(f"duplicate rule id: {rule_id}")
        else:
            rule_ids.add(rule_id)

        action = rule["action"]
        if action not in {"pass", "block"}:
            errors.append(f"rule {rule_id}: invalid action '{action}'")

        state = rule["state"]
        if state not in {"keep", "none"}:
            errors.append(f"rule {rule_id}: invalid state '{state}'")

        from_zone = rule["from_zone"]
        to_zone = rule["to_zone"]
        if from_zone not in zones:
            errors.append(f"rule {rule_id}: unknown from_zone '{from_zone}'")
        if to_zone not in zones:
            errors.append(f"rule {rule_id}: unknown to_zone '{to_zone}'")

        service = rule["service"]
        if service != "any" and service not in services:
            errors.append(f"rule {rule_id}: unknown service '{service}'")

    for line in text.splitlines():
        match_rule_start = re.match(r"^\s{2}-\s+id:\s+([a-zA-Z0-9_-]+)\s*$", line)
        if match_rule_start:
            finalize_rule(current_rule)
            current_rule = {"id": match_rule_start.group(1)}
            continue

        if current_rule is None:
            continue

        for key in ("action", "from_zone", "to_zone", "service", "state"):
            match_key = re.match(rf"^\s{{4}}{key}:\s+([a-zA-Z0-9_-]+)\s*$", line)
            if match_key:
                current_rule[key] = match_key.group(1)
                break

    finalize_rule(current_rule)
    return errors


def scan_text(text: str) -> list[str]:
    findings: list[str] = []
    findings.extend(match.group(0) for match in CIDR_V4_RE.finditer(text))
    findings.extend(match.group(0) for match in CIDR_V6_RE.finditer(text))

    for match in IPV4_RE.finditer(text):
        value = match.group(0)
        octets = value.split(".")
        if all(octet.isdigit() and 0 <= int(octet) <= 255 for octet in octets):
            findings.append(value)

    for match in IPV6_RE.finditer(text):
        value = match.group(0)
        if "::" in value or any(part for part in value.split(":") if part):
            findings.append(value)

    return sorted(set(findings))


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: validate_public_policy.py <path>")
        return 2

    target = pathlib.Path(sys.argv[1])
    if not target.exists():
        print(f"ERROR: file not found: {target}")
        return 2

    content = target.read_text(encoding="utf-8")
    findings = scan_text(content)

    if findings:
        print(f"ERROR: found address-like literals in {target}:")
        for item in findings:
            print(f"  - {item}")
        return 1

    zones = extract_zones(content)
    services = extract_service_groups(content)
    structure_errors = validate_rule_structure(content, zones, services)

    if not zones:
        structure_errors.append("zones section is empty or missing")
    if not services:
        structure_errors.append("aliases.service_groups section is empty or missing")

    if structure_errors:
        print(f"ERROR: policy structure validation failed for {target}:")
        for error in structure_errors:
            print(f"  - {error}")
        return 1

    print(f"OK: {target} passed literal and structure validation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
