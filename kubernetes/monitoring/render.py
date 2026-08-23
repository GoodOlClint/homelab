#!/usr/bin/env python3
"""deploy.sh helper: prints `export` lines for the monitoring configs and writes the
generated files (Prometheus file_sd targets, the smokeping dashboard) into OUT.

usage: render.py <repo root> <out dir>   (run with the repo .venv python — needs yaml + jinja2)
"""
import json
import os
import shlex
import sys

import jinja2
import yaml

root, out = sys.argv[1], sys.argv[2]
here = os.path.dirname(os.path.abspath(__file__))
g = yaml.safe_load(open(f"{root}/ansible/group_vars/all.yml"))
net = yaml.safe_load(open(f"{root}/network-data/vlans.yaml"))
hosts = yaml.safe_load(open(f"{root}/ansible/inventory/vms.yaml"))["all"]["hosts"]

# Guests that never run the telegraf role (management/hypervisor-plane guests).
TELEGRAF_SKIP = {"control", "pdm", "pxe"}

targets = [
    {"targets": [f"{v['service_ip']}:9273"], "labels": {"instance": h}}
    for h, v in sorted(hosts.items())
    if h not in TELEGRAF_SKIP and v.get("service_ip")
]
json.dump(targets, open(f"{out}/telegraf.json", "w"), indent=1)

dns = net["dns_server"]
json.dump(
    [{"targets": [dns["dns_ipv4"]],
      "labels": {"zone": f"{net['vlans'][v]['domain_prefix']}.{net['domain_suffix']}",
                 "vlan": f"vlan{net['vlans'][v]['id']}"}}
     for v in dns["zone_vlans"]],
    open(f"{out}/blackbox-dns.json", "w"), indent=1)

tpl = jinja2.Template(open(f"{here}/dashboards/smokeping.json.j2").read())
open(f"{out}/smokeping.json", "w").write(tpl.render(smokeping_targets=g["smokeping_targets"]))

print(f"export OO_EMAIL={shlex.quote(g['openobserve_root_user_email'])}")
print(f"export UNIFI_PORT={g['unifi_controller_port']}")
print(f"export SYNOLOGY_SNMP_COMMUNITY={shlex.quote(str(g['synology_snmp_community']))}")
print("export SMOKEPING_ARGS=" + shlex.quote(json.dumps([t["ip"] for t in g["smokeping_targets"]])))
