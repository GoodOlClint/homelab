#!/usr/bin/env python3
"""Pins ansible/tasks/infisical_identity_page.yml: a mock /api/v1/identities holding 150
identities is walked to the end (a full page of 100, then a short page of 50). Also pins
ansible/tasks/infisical_project_member_page.yml: the project holds members 0-119 (two pages), so an
orphan on page two (110) is found and an identity in another project only (130) is not."""
import json, os, shutil, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IDS = [{"identity": {"id": str(i), "name": f"id-{i}-vm"}} for i in range(150)]


MEMBERS = [{"identity": {"id": str(i)}} for i in range(120)]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        off, lim = int(q["offset"][0]), int(q["limit"][0])
        if u.path.endswith("/identity-memberships"):
            body = json.dumps({"identityMemberships": MEMBERS[off:off + lim], "totalCount": len(MEMBERS)}).encode()
        else:
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
        for t in ("infisical_identity_page.yml", "infisical_project_member_page.yml"):
            shutil.copy(f"{ROOT}/ansible/tasks/{t}", f"{tmp}/tasks/")
        play = [{
            "hosts": "localhost", "connection": "local", "gather_facts": False,
            "vars": {"bootstrap_config": {"infisical_url": f"http://127.0.0.1:{port}", "infisical_org_id": "org",
                                         "infisical_project_id": "proj"},
                     "_admin_token": "mock"},
            "tasks": [
                {"ansible.builtin.set_fact": {"_all_identities": [], "_page_offset": 0}},
                {"ansible.builtin.include_tasks": "{{ playbook_dir }}/../tasks/infisical_identity_page.yml"},
                {"ansible.builtin.assert": {
                    "that": ["_all_identities | length == 150",
                             "_all_identities | map(attribute='identity.id') | unique | length == 150"],
                    "fail_msg": "walked {{ _all_identities | length }} of 150 identities"}},
                {"ansible.builtin.set_fact": {"_project_members_all": [], "_member_offset": 0}},
                {"ansible.builtin.include_tasks": "{{ playbook_dir }}/../tasks/infisical_project_member_page.yml"},
                {"ansible.builtin.set_fact": {
                    "_member_ids": "{{ _project_members_all | map(attribute='identity.id') | list }}",
                    "_expected_names": [f"id-{i}-vm" for i in range(150) if i not in (110, 130)]}},
                {"ansible.builtin.set_fact": {
                    "_orphaned": "{{ _all_identities | selectattr('identity.id', 'in', _member_ids) "
                                 "| selectattr('identity.name', 'match', '.*-vm$') "
                                 "| rejectattr('identity.name', 'in', _expected_names) | list }}"}},
                {"ansible.builtin.assert": {
                    "that": ["_member_ids | length == 120",
                             "_orphaned | map(attribute='identity.id') | list == ['110']"],
                    "fail_msg": "members {{ _member_ids | length }}, orphans {{ _orphaned | map(attribute='identity.id') | list }}"}},
            ]}]
        with open(f"{tmp}/playbooks/play.yml", "w") as f:
            json.dump(play, f)
        env = {k: v for k, v in os.environ.items() if k != "ANSIBLE_CONFIG"}
        r = subprocess.run(["ansible-playbook", "-i", "localhost,", f"{tmp}/playbooks/play.yml"],
                           capture_output=True, text=True, env=env, timeout=120)
        if r.returncode != 0 or "offset 100" not in r.stdout or r.stdout.count("offset 100") < 2:
            sys.stdout.write(r.stdout + r.stderr)
            sys.exit(1)
        print("identity paging: PASS (150 identities and 120 project members over 2 pages each)")
    finally:
        shutil.rmtree(tmp)
        srv.shutdown()


if __name__ == "__main__":
    main()
