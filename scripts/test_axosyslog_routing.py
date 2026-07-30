#!/usr/bin/env python3
"""Validate axosyslog message routing against the real image, offline.

Renders roles/monitoring/templates/axosyslog.conf.j2, swaps its OpenObserve
destinations for file() destinations, runs it in the real axosyslog container,
fires one datagram per message class, and asserts each landed in the right
stream with its text intact.

    python3 scripts/test_axosyslog_routing.py

Requires Docker. Touches nothing outside a temp dir and a throwaway container.

Why this exists
---------------
Routing here is not obvious. netconsole was first implemented as a parser-free
catch-all channel on the shared 5514 port, on the assumption that raw kernel
printk would fail syslog-parser() and fall through. It does not fail: it parses
as RFC 3164 and the first token is consumed as the program tag. Verified
2026-07-30 — "nvme nvme0: Removing after probe failure" arrived in the syslog
stream as "nvme0: Removing after probe failure", silently losing the word that
names the failing subsystem. Hence the dedicated 5515 port, and hence the
verbatim assertions below: a test that only checked "landed somewhere" passes
the broken design.
"""
import re
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TEMPLATE = REPO / "ansible/roles/monitoring/templates/axosyslog.conf.j2"
IMAGE = "ghcr.io/axoflow/axosyslog:latest"
NAME = "axosyslog-routing-test"

DESTS = {
    "d_openobserve_firewall": "firewall",
    "d_openobserve_syslog": "syslog",
    "d_openobserve_netconsole": "netconsole",
}

PORTS = {15514: 5514, 15515: 5515}

# (label, host port, wire bytes, expected stream, text that must appear verbatim)
CASES = [
    ("pfsense-filterlog", 15514,
     b'<134>1 2026-07-30T12:00:00.000Z pfsense filterlog - - - '
     b'5,,,1000000103,igb0,match,block,in,4,0x0,,64,12345,0,DF,6,tcp,60,'
     b'192.0.2.1,198.51.100.1,54321,443,0,S,1,,,',
     "firewall", "192.0.2.1,198.51.100.1"),
    ("pfsense-filterlog-v6", 15514,
     b'<134>1 2026-07-30T12:00:00.000Z pfsense filterlog - - - '
     b'5,,,1000000103,igb0,match,block,in,6,0x00,0,64,tcp,6,60,'
     b'2001:db8::1,2001:db8::2,54321,443,0,S,1,,,',
     "firewall", "2001:db8::1,2001:db8::2"),
    ("rfc5424-vm", 15514,
     b'<134>1 2026-07-30T12:00:00.000Z somehost someapp - - - ordinary vm log line',
     "syslog", "ordinary vm log line"),
    # Leading token MUST survive on every netconsole case.
    ("netconsole-nvme", 15515,
     b'nvme nvme0: Removing after probe failure status: -19',
     "netconsole", "nvme nvme0: Removing after probe failure status: -19"),
    ("netconsole-oops", 15515,
     b'BUG: unable to handle page fault for address: ffffffffdeadbeef',
     "netconsole", "BUG: unable to handle page fault for address: ffffffffdeadbeef"),
    ("netconsole-ext-format", 15515,
     b'6,845,1234567890,-;EXT4-fs (dm-1): I/O error while writing superblock',
     "netconsole", "6,845,1234567890,-;EXT4-fs (dm-1): I/O error while writing superblock"),
]


def render(dest: Path) -> None:
    """Render the template. Its only Jinja variable is the OpenObserve user."""
    src = TEMPLATE.read_text().replace(
        "{{ openobserve_root_user_email }}", "test@example.com"
    )
    leftover = re.findall(r"\{\{.*?\}\}", src)
    if leftover:
        raise SystemExit(
            f"unhandled Jinja variables in template: {sorted(set(leftover))}\n"
            "Add them to render() before this test can run."
        )
    for name, stream in DESTS.items():
        pattern = re.compile(
            r"(destination\s+" + re.escape(name) + r"\s*\{).*?(\};)", re.DOTALL
        )

        def repl(m, stream=stream):
            body = (
                '    file("/out/' + stream + '.log" '
                'template("${MESSAGE}\\n") create-dirs(yes));'
            )
            return m.group(1) + "\n" + body + "\n" + m.group(2)

        src, n = pattern.subn(repl, src)
        if n != 1:
            raise SystemExit(f"expected exactly 1 '{name}' destination, found {n}")
    if "openobserve-log(" in src:
        raise SystemExit("an openobserve-log() destination survived the rewrite")
    dest.write_text(src)


def run(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)


def main() -> int:
    if run("docker info").returncode != 0:
        print("SKIP: Docker is not available")
        return 0

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        confdir, out = tmp / "conf", tmp / "out"
        confdir.mkdir()
        out.mkdir()
        render(confdir / "syslog-ng.conf")

        run(f"docker rm -f {NAME}")
        pmap = " ".join(f"-p {h}:{c}/udp" for h, c in PORTS.items())
        up = run(
            f"docker run -d --name {NAME} {pmap} "
            f"-e openobserve_root_user_pass=testpass "
            f"-v {confdir}:/etc/syslog-ng:ro -v {out}:/out "
            f"{IMAGE} -F -f /etc/syslog-ng/syslog-ng.conf"
        )
        if up.returncode != 0:
            print("FAIL: container did not start\n" + up.stderr)
            return 1

        try:
            time.sleep(4)
            if not run(f"docker ps -q -f name={NAME}").stdout.strip():
                logs = run(f"docker logs {NAME}")
                print("FAIL: config rejected by axosyslog\n" + logs.stdout + logs.stderr)
                return 1

            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            for _, port, payload, _, _ in CASES:
                sock.sendto(payload, ("127.0.0.1", port))
                time.sleep(0.3)
            sock.close()
            time.sleep(3)

            landed = {}
            for stream in DESTS.values():
                p = out / f"{stream}.log"
                landed[stream] = p.read_text() if p.exists() else ""

            print("=== stream contents ===")
            for stream, body in landed.items():
                lines = [ln for ln in body.splitlines() if ln.strip()]
                print(f"{stream}: {len(lines)} message(s)")
                for ln in lines:
                    print(f"    {ln[:110]}")
            print()

            failures = []
            for label, _, _, expected, verbatim in CASES:
                hits = [s for s, body in landed.items() if verbatim in body]
                if hits != [expected]:
                    failures.append(
                        f"  {label}: {verbatim[:56]!r}\n"
                        f"      expected verbatim in [{expected}], "
                        f"found in {hits or ['NOWHERE']}"
                    )

            if failures:
                print("FAIL: axosyslog routing")
                print("\n".join(failures))
                return 1
            print(f"PASS: {len(CASES)} message classes routed correctly, "
                  "netconsole text preserved byte-for-byte")
            return 0
        finally:
            run(f"docker rm -f {NAME}")


if __name__ == "__main__":
    sys.exit(main())
