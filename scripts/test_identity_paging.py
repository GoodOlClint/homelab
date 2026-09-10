#!/usr/bin/env python3
"""Pins ansible/tasks/infisical_identity_page.yml: a mock /api/v1/identities holding 150
identities is walked to the end (a full page of 100, then a short page of 50)."""
import json, os, shutil, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IDS = [{"identity": {"id": str(i), "name": f"id-{i}-vm"}} for i in range(150)]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        q = parse_qs(urlparse(self.path).query)
        off, lim = int(q["offset"][0]), int(q["limit"][0])
        body = json.dumps({"identities": IDS[off:off + lim]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def main():
    srv = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port = srv.server_address[1]
    tmp = tempfile.mkdtemp()
    try:
        os.makedirs(f"{tmp}/tasks")
        os.makedirs(f"{tmp}/playbooks")
        shutil.copy(f"{ROOT}/ansible/tasks/infisical_identity_page.yml", f"{tmp}/tasks/")
        play = [{
            "hosts": "localhost", "connection": "local", "gather_facts": False,
            "vars": {"bootstrap_config": {"infisical_url": f"http://127.0.0.1:{port}", "infisical_org_id": "org"},
                     "_admin_token": "mock"},
            "tasks": [
                {"ansible.builtin.set_fact": {"_all_identities": [], "_page_offset": 0}},
                {"ansible.builtin.include_tasks": "{{ playbook_dir }}/../tasks/infisical_identity_page.yml"},
                {"ansible.builtin.assert": {
                    "that": ["_all_identities | length == 150",
                             "_all_identities | map(attribute='identity.id') | unique | length == 150"],
                    "fail_msg": "walked {{ _all_identities | length }} of 150 identities"}},
            ]}]
        with open(f"{tmp}/playbooks/play.yml", "w") as f:
            json.dump(play, f)
        env = {k: v for k, v in os.environ.items() if k != "ANSIBLE_CONFIG"}
        r = subprocess.run(["ansible-playbook", "-i", "localhost,", f"{tmp}/playbooks/play.yml"],
                           capture_output=True, text=True, env=env, timeout=120)
        if r.returncode != 0 or "offset 100" not in r.stdout:
            sys.stdout.write(r.stdout + r.stderr)
            sys.exit(1)
        print("identity paging: PASS (150 identities over 2 pages)")
    finally:
        shutil.rmtree(tmp)
        srv.shutdown()


if __name__ == "__main__":
    main()
