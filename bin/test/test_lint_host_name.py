"""Tests for bin/lint-host-name.

Each test builds a throwaway tree (not a git repo, so the lint walks it) with
its own allow-list and baseline files, plus one test that runs the lint on this
repository as CI does.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent
LINT = BIN / "lint-host-name"

# One fixture per refused form: (file name, content, form named in the finding).
REFUSED = [
    ("a.sh", 'if [ "$(hostname)" = box ]; then echo hub; fi\n', "hostname"),
    ("b.sh", "h=`hostname -s`\n", "hostname"),
    ("c.md", "Run `hostname` and pick the setup that matches.\n", "hostname"),
    ("d.sh", "case $(uname -n) in box) :;; esac\n", "uname -n"),
    ("e.sh", "uname --nodename\n", "uname -n"),
    ("f.sh", '[ "$HOSTNAME" = box ] && exit 0\n', "$HOSTNAME"),
    ("g.sh", 'echo "${HOSTNAME%%.*}"\n', "$HOSTNAME"),
    ("h.py", 'import os\nif os.environ.get("HOSTNAME") == "box":\n    pass\n', "$HOSTNAME"),
    ("i.py", "import socket\nif socket.gethostname() == 'box':\n    pass\n", "socket.gethostname"),
    ("j.py", "from socket import gethostname\n", "socket.gethostname"),
    ("k.py", "import platform\nhub = platform.node() == 'box'\n", "platform.node"),
    ("l.py", "import os\nhub = os.uname().nodename == 'box'\n", "platform.node"),
    ("m.sh", "read -r h < /etc/hostname\n", "/etc/hostname"),
    ("n.sh", "hostnamectl --static\n", "hostname"),
    ("o.py", "import subprocess\nh = subprocess.run(['hostname'], text=True)\n", "hostname"),
    ("p.sh", "true && hostname | grep -q box\n", "hostname"),
]

# Uses of the word that do not read this machine's host name.
NOT_HOST_NAME = (
    "host = urllib.parse.urlsplit(url).hostname or ''\n"
    "- Hardcoded URLs, ports, or hostnames that should be config\n"
    "docker run --hostname box image\n"
    "Never fall back to the host name.\n"
    "uname -s\n"
    "hostname = parsed.hostname\n"
    "    if not hostname:\n"
    "print('ssh: Could not resolve hostname box: Name or service not known')\n"
    "printf 'stub (hostname=%s)' \"$h\"\n"
    'record = {"hostname": h}\n'
    "for tool in bash basename hostname env; do :; done\n"
    "ssh -o BatchMode=yes box hostname\n"
    "a Dropbox copy named `x (hostname's conflicted copy).ext`\n"
)


class LintTree(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.root = self.tmp / "tree"
        (self.root / "skill").mkdir(parents=True)
        self.allow = self.tmp / "allow"
        self.baseline = self.tmp / "baseline"
        self.allow.write_text("# path | needle | reason\n")
        self.baseline.write_text("# path | needle | reason\n")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def lint(self) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(LINT), "--root", str(self.root),
             "--allow", str(self.allow), "--baseline", str(self.baseline)],
            capture_output=True, text=True, timeout=60,
        )

    def put(self, name: str, text: str) -> None:
        (self.root / "skill" / name).write_text(text)

    def test_each_form_refused(self):
        for name, text, form in REFUSED:
            with self.subTest(name=name):
                for old in (self.root / "skill").iterdir():
                    old.unlink()
                self.put(name, text)
                r = self.lint()
                self.assertEqual(r.returncode, 1, f"{name}: {r.stdout}{r.stderr}")
                self.assertIn(f"skill/{name}:", r.stdout)
                self.assertIn(f"[{form}]", r.stdout)

    def test_other_uses_pass(self):
        self.put("ok.md", NOT_HOST_NAME)
        r = self.lint()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_allow_listed_use_passes(self):
        self.put("note.sh", 'echo "sent from $(hostname)"\n')
        self.allow.write_text("skill/note.sh | sent from $(hostname) | records the sender\n")
        r = self.lint()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_allow_entry_does_not_cover_a_new_branch_in_the_same_file(self):
        self.put("note.sh", 'echo "sent from $(hostname)"\n[ "$(hostname)" = box ] && x\n')
        self.allow.write_text("skill/note.sh | sent from $(hostname) | records the sender\n")
        r = self.lint()
        self.assertEqual(r.returncode, 1)
        self.assertIn("skill/note.sh:2:", r.stdout)
        self.assertNotIn("skill/note.sh:1:", r.stdout)

    def test_baseline_use_passes_and_is_reported(self):
        self.put("gate.py", "import socket\nok = socket.gethostname() == 'box'\n")
        self.baseline.write_text("skill/gate.py | gethostname() | publish gate branches on host\n")
        r = self.lint()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("known", r.stdout)
        self.assertIn("skill/gate.py:2:", r.stdout)

    def test_stale_entry_fails(self):
        self.put("clean.sh", "echo hi\n")
        self.allow.write_text("skill/clean.sh | hostname | no longer used\n")
        r = self.lint()
        self.assertEqual(r.returncode, 1)
        self.assertIn("stale", r.stdout)

    def test_entry_for_a_file_not_in_this_tree_is_skipped(self):
        self.baseline.write_text("other-skill/SKILL.md | hostname | lives in another repo\n")
        r = self.lint()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_entry_without_reason_is_malformed(self):
        self.allow.write_text("skill/x.sh | hostname |\n")
        r = self.lint()
        self.assertEqual(r.returncode, 2)
        self.assertIn(str(self.allow), r.stderr)

    def test_entry_without_needle_is_malformed(self):
        self.allow.write_text("skill/x.sh | | a reason\n")
        r = self.lint()
        self.assertEqual(r.returncode, 2)

    def test_whole_file_entry(self):
        self.put("table.py", "FORMS = ['hostname', 'gethostname']\n")
        self.allow.write_text("skill/table.py | * | the pattern table itself\n")
        r = self.lint()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


class ThisRepo(unittest.TestCase):
    def test_repo_is_clean(self):
        r = subprocess.run([sys.executable, str(LINT)], capture_output=True, text=True,
                           timeout=120)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
