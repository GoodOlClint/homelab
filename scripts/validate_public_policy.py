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

    print(f"OK: {target} contains no IP/CIDR literals")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
