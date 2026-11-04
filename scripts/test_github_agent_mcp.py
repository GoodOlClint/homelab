#!/usr/bin/env python3
"""Pins scripts/github-agent-mcp: the App triple and push mode follow the session repo's origin."""
import json, os, subprocess, sys, tempfile, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WRAPPER = os.path.join(ROOT, "scripts", "github-agent-mcp")
STUB = "#!%s\nimport json, os, sys\nprint(json.dumps({'argv': sys.argv[1:], 'env': {k: v for k, v in os.environ.items() if k.startswith(('GITHUB_', 'GIT_'))}}))\n" % sys.executable


def agent(n):
    return {"app_id": "id-%s" % n, "installation_id": "inst-%s" % n, "key_path": "/keys/%s.pem" % n}


def make_map(tmp, orgs):
    for name in ("gh-stub", "pv-stub"):
        p = os.path.join(tmp, name)
        with open(p, "w") as f:
            f.write(STUB)
        os.chmod(p, 0o755)
    d = os.path.join(tmp, ".config", "github-agent")
    os.makedirs(d)
    with open(os.path.join(d, "identities.json"), "w") as f:
        json.dump({"servers": {"github": os.path.join(tmp, "gh-stub"), "push_verified": os.path.join(tmp, "pv-stub")}, "orgs": orgs}, f)


def git(cwd, *a):
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t"] + list(a), cwd=cwd, check=True, capture_output=True)


class T(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.tmp = os.path.realpath(self._td.name)
        self.addCleanup(self._td.cleanup)
        self.orgs = {
            "GoodOlClint": {"agents": {"claude": agent("gc-claude"), "codex": agent("gc-codex")}, "repos": {"plainrepo": "plain"}},
            "Other-Org": {"agents": {"claude": agent("oo-claude")}, "push_mode": "plain", "repos": {"openrepo": "push_verified"}},
        }
        self.write_map()

    def write_map(self):
        d = os.path.join(self.tmp, ".config")
        if os.path.exists(d):
            import shutil
            shutil.rmtree(d)
        make_map(self.tmp, self.orgs)

    def repo(self, origin, name="r"):
        p = os.path.join(self.tmp, name)
        os.makedirs(p)
        git(p, "init", "-q")
        if origin:
            git(p, "remote", "add", "origin", origin)
        return p

    def run_w(self, cwd, a="claude", m="github", env=None, direct=True):
        e = {"HOME": self.tmp} if env is None else env
        return subprocess.run([WRAPPER, a, m], cwd=cwd, env=e, capture_output=True, text=True)

    def ok(self, r):
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)

    def refuses(self, r):
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assertTrue(r.stderr.strip())

    def test_each_org_picks_its_own_app(self):
        a = self.repo("git@github.com:GoodOlClint/foo.git", "a")
        b = self.repo("https://github.com/Other-Org/bar", "b")
        self.assertEqual(self.ok(self.run_w(a))["env"]["GITHUB_APP_ID"], "id-gc-claude")
        self.assertEqual(self.ok(self.run_w(a, "codex"))["env"]["GITHUB_APP_ID"], "id-gc-codex")
        e = self.ok(self.run_w(b))["env"]
        self.assertEqual((e["GITHUB_APP_ID"], e["GITHUB_APP_INSTALLATION_ID"], e["GITHUB_APP_PRIVATE_KEY_PATH"]), ("id-oo-claude", "inst-oo-claude", "/keys/oo-claude.pem"))
        self.assertEqual(self.ok(self.run_w(a))["argv"], ["stdio"])

    def test_url_forms_and_case(self):
        for i, u in enumerate(["git@github.com:goodolclint/x.git", "ssh://git@github.com/GOODOLCLINT/x", "https://github.com/GoodOlClint/x.git", "https://tok@github.com/GoodOlClint/x/"]):
            self.assertEqual(self.ok(self.run_w(self.repo(u, "f%d" % i)))["env"]["GITHUB_APP_ID"], "id-gc-claude", u)

    def test_refuse_unknown_org(self):
        self.refuses(self.run_w(self.repo("git@github.com:Nobody/x.git")))

    def test_refuse_no_origin(self):
        self.refuses(self.run_w(self.repo(None)))

    def test_refuse_no_repo(self):
        p = os.path.join(self.tmp, "plain-dir")
        os.makedirs(p)
        self.refuses(self.run_w(p))
        self.refuses(self.run_w(p, env={}))

    def test_refuse_other_host(self):
        for i, u in enumerate(["https://gitlab.com/GoodOlClint/x.git", "git@gitlab.com:GoodOlClint/x.git", "https://github.com.evil.example/GoodOlClint/x", "https://evilgithub.com/GoodOlClint/x", "ssh://git@github.com.evil/GoodOlClint/x"]):
            self.refuses(self.run_w(self.repo(u, "h%d" % i)))

    def test_refuse_missing_agent(self):
        self.refuses(self.run_w(self.repo("git@github.com:Other-Org/x.git"), "codex"))

    def test_refuse_bad_usage(self):
        r = self.repo("git@github.com:GoodOlClint/x.git")
        self.refuses(self.run_w(r, "gpt"))
        self.refuses(self.run_w(r, "claude", "shell"))

    def test_plain_repo_refuses_push_but_serves_github(self):
        p = self.repo("git@github.com:GoodOlClint/plainrepo.git")
        self.refuses(self.run_w(p, m="push"))
        self.ok(self.run_w(p))
        self.refuses(self.run_w(self.repo("git@github.com:Other-Org/zzz.git", "q"), m="push"))

    def test_silent_repo_gets_push_verified(self):
        p = self.repo("git@github.com:GoodOlClint/foo.git")
        o = self.ok(self.run_w(p, m="push"))
        self.assertEqual(o["argv"], ["--repo-root", p, "--bind-repo", "GoodOlClint/foo"])
        self.assertEqual(o["env"]["GITHUB_APP_ID"], "id-gc-claude")
        q = self.ok(self.run_w(self.repo("git@github.com:Other-Org/openrepo.git", "o"), m="push"))
        self.assertEqual(q["argv"][-1], "Other-Org/openrepo")

    def test_linked_worktree_resolves_to_main_tree(self):
        p = self.repo("git@github.com:GoodOlClint/foo.git")
        git(p, "commit", "-q", "--allow-empty", "-m", "x")
        wt = os.path.join(self.tmp, "wt")
        git(p, "worktree", "add", "-q", wt, "-b", "side")
        o = self.ok(self.run_w(wt, m="push"))
        self.assertEqual(o["argv"][:2], ["--repo-root", p])
        sub = os.path.join(wt, "sub")
        os.makedirs(sub)
        self.assertEqual(self.ok(self.run_w(sub, m="push"))["argv"][1], p)

    def test_empty_environment(self):
        p = self.repo("git@github.com:GoodOlClint/foo.git")
        self.assertEqual(self.ok(self.run_w(p, env={"HOME": self.tmp}))["env"]["GITHUB_APP_ID"], "id-gc-claude")

    def test_inherited_git_dir_ignored(self):
        a = self.repo("git@github.com:GoodOlClint/foo.git", "a")
        b = self.repo("git@github.com:Other-Org/bar.git", "b")
        e = {"HOME": self.tmp, "GIT_DIR": os.path.join(b, ".git"), "GIT_WORK_TREE": b, "GIT_CONFIG_COUNT": "0"}
        o = self.ok(self.run_w(a, env=e))
        self.assertEqual(o["env"]["GITHUB_APP_ID"], "id-gc-claude")
        self.assertFalse([k for k in o["env"] if k.startswith("GIT_")])

    def test_global_insteadof_ignored(self):
        with open(os.path.join(self.tmp, ".gitconfig"), "w") as f:
            f.write('[url "https://github.com/Other-Org/"]\n\tinsteadOf = https://github.com/GoodOlClint/\n')
        p = self.repo("https://github.com/GoodOlClint/foo.git")
        self.assertEqual(self.ok(self.run_w(p))["env"]["GITHUB_APP_ID"], "id-gc-claude")

    def test_bad_push_mode_refuses_both_servers(self):
        for bad in ("push-verified", "Plain", "", True, 1, ["plain"], None):
            for where in ("org", "repo"):
                orgs = {"GoodOlClint": {"agents": {"claude": agent("x")}}}
                if where == "org":
                    orgs["GoodOlClint"]["push_mode"] = bad
                else:
                    orgs["GoodOlClint"]["repos"] = {"foo": bad}
                self.orgs = orgs
                self.write_map()
                p = os.path.join(self.tmp, "br")
                if not os.path.exists(p):
                    self.repo("git@github.com:GoodOlClint/foo.git", "br")
                for m in ("github", "push"):
                    with self.subTest(bad=bad, where=where, mode=m):
                        self.refuses(self.run_w(p, m=m))


if __name__ == "__main__":
    unittest.main(verbosity=1)
