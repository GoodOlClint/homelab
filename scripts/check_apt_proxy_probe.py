#!/usr/bin/env python3
"""The apt Proxy-Auto-Detect probe exists twice (#39): the apt_proxy role template (Jinja) and the
cloud-init snippet in the VM module (HCL templatefile). CLAUDE.md asserts the two write identical
bytes; this renders both with one host/port and diffs them, so editing either alone fails validate."""
import difflib, pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
host, port = "cache.example.test", "3142"

jinja = (root / "ansible/roles/apt_proxy/templates/apt-proxy-detect.sh.j2").read_text()
ansible = re.sub(r"\{\{\s*apt_proxy_(host|port)\s*\}\}", lambda m: {"host": host, "port": port}[m.group(1)], jinja)

tmpl = (root / "terraform/modules/proxmox-vm/templates/user-data.yaml.tmpl").read_text()
block = re.search(r"path: /usr/local/bin/apt-proxy-detect\n\s*permissions: '0755'\n\s*content: \|\n(.*?)\n  - path:", tmpl, re.S).group(1)
lines = [ln[6:] if ln.startswith("      ") else ln for ln in block.split("\n")]
cloudinit = re.sub(r"\$\{apt_proxy_(host|port)\}", lambda m: {"host": host, "port": port}[m.group(1)], "\n".join(lines)) + "\n"

if ansible != cloudinit:
    sys.stdout.writelines(difflib.unified_diff(ansible.splitlines(True), cloudinit.splitlines(True), "apt_proxy role", "cloud-init snippet"))
    print("apt-proxy-detect: the two copies differ (#39)", file=sys.stderr)
    sys.exit(1)
print("apt-proxy-detect: role and cloud-init copies identical")
