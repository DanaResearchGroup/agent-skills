"""Tests for mutation-test/bin/mutation-test. Run via mutation-test/test/ci.sh (needs cosmic-ray)."""

import fcntl
import importlib.machinery
import json
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent / "bin" / "mutation-test"

CALC = textwrap.dedent("""\
    def add(a, b):
        return a + b


    def sign(x):
        if x > 0:
            return 1
        return -1
    """)

TESTS = textwrap.dedent("""\
    import unittest
    from calc import add, sign


    class T(unittest.TestCase):
        def test_add(self):
            self.assertEqual(add(2, 3), 5)

        def test_sign(self):
            self.assertEqual((sign(5), sign(-5)), (1, -1))
    """)

UNTESTED = "\n\ndef double(x):\n    return x * 2\n"


class Gate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "calc.py").write_text(CALC)
        (self.root / "calc_test.py").write_text(TESTS)
        self.git("init", "-q")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.test_command = f"{sys.executable} -m unittest -q calc_test"

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "-C", str(self.root), *args],
                       check=True, capture_output=True)

    def run_gate(self, *argv, command=None, env=None):
        before = {p: p.read_bytes() for p in self.root.glob("*.py")}
        proc = subprocess.run([sys.executable, str(BIN), "--root", str(self.root), "--json",
                               "--test-command", command or self.test_command, *argv],
                              capture_output=True, text=True, cwd=self.root,
                              env=None if env is None else {**os.environ, **env})
        for path, data in before.items():
            self.assertEqual(path.read_bytes(), data, f"{path.name} left mutated")
        data = json.loads(proc.stdout) if proc.stdout.strip().startswith("{") else None
        return proc.returncode, data, proc.stderr

    def test_tested_change_kills_every_mutant(self):
        (self.root / "calc.py").write_text(CALC.replace("return a + b", "return b + a"))
        rc, data, err = self.run_gate("--diff", "HEAD")
        self.assertEqual(rc, 0, err)
        self.assertGreater(data["mutants"], 0)
        self.assertEqual((data["survived"], data["errors"]), (0, 0))

    def test_untested_function_survives_and_fails_the_gate(self):
        # injection: a new function no test calls must produce survivors, each with its diff
        (self.root / "calc.py").write_text(CALC + UNTESTED)
        rc, data, err = self.run_gate("--diff", "HEAD")
        self.assertEqual(rc, 1, err)
        self.assertGreater(data["survived"], 0)
        for row in data["survivors"]:
            self.assertRegex(row["where"], r"^calc\.py:1[12] ")
            self.assertIn("x * 2", row["diff"])

    def test_only_changed_lines_are_mutated(self):
        _, full, err = self.run_gate("calc.py")
        self.assertIsNotNone(full, err)
        (self.root / "calc.py").write_text(CALC.replace("return a + b", "return b + a"))
        _, scoped, _ = self.run_gate("--diff", "HEAD")
        self.assertLess(scoped["mutants"], full["mutants"])
        self.assertEqual({r["where"].split(":")[1].split()[0] for r in scoped["survivors"]} - {"2"}, set())

    def test_deletion_at_either_end_of_file_keeps_a_neighbour_in_scope(self):
        # git reports `@@ -1 +0,0 @@` at the top (scoping only line 0 mutated nothing and exited 0)
        # and `@@ -2 +1,0 @@` at the end, where the line before the cut is still there to mutate
        for before in ("UNUSED = 0\nFACTOR = 2\n", "FACTOR = 2\nUNUSED = 0\n"):
            with self.subTest(before=before):
                (self.root / "extra.py").write_text(before)
                self.git("add", "extra.py")
                self.git("commit", "-qm", "extra")
                (self.root / "extra.py").write_text("FACTOR = 2\n")
                rc, data, err = self.run_gate("--diff", "HEAD")
                self.assertEqual(rc, 1, err)
                self.assertTrue(any(r["where"].startswith("extra.py:1") for r in data["survivors"]), data)

    def test_diff_prefix_config_cannot_empty_the_scope(self):
        # injection: diff.mnemonicPrefix turns `+++ b/x` into `+++ w/x`, which matched no file
        (self.root / "calc.py").write_text(CALC + UNTESTED)
        for key, value in (("diff.mnemonicPrefix", "true"), ("diff.noprefix", "true"), ("diff.dstPrefix", "y/")):
            with self.subTest(key=key):
                env = {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": key, "GIT_CONFIG_VALUE_0": value}
                rc, data, err = self.run_gate("--diff", "HEAD", env=env)
                self.assertEqual(rc, 1, err)
                self.assertTrue(data["survivors"], data)

    def test_sigterm_mid_run_restores_the_source(self):
        # injection: Python's default SIGTERM exit skips `finally`, leaving the mutant in calc.py
        original = (self.root / "calc.py").read_bytes()
        proc = subprocess.Popen([sys.executable, str(BIN), "--root", str(self.root),
                                 "--test-command", self.test_command + " && sleep 30", "calc.py"],
                                cwd=self.root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 60
            while (self.root / "calc.py").read_bytes() == original:
                self.assertLess(time.monotonic(), deadline, "no mutant was ever applied")
                self.assertIsNone(proc.poll(), "the gate exited before applying a mutant")
                time.sleep(0.05)
            proc.send_signal(signal.SIGTERM)
            self.assertEqual(proc.wait(timeout=30), 128 + signal.SIGTERM)
        finally:
            if proc.poll() is None:
                proc.kill()
        self.assertEqual((self.root / "calc.py").read_bytes(), original)

    def lock_path(self):
        gitdir = subprocess.run(["git", "-C", str(self.root), "rev-parse", "--absolute-git-dir"],
                                check=True, capture_output=True, text=True).stdout.strip()
        return Path(gitdir) / "mutation-test.lock"

    def test_concurrent_run_on_the_same_tree_is_refused(self):
        # injection: a live run holds the tree; a second run would snapshot its mutant as the original
        (self.root / "calc.py").write_text(CALC + UNTESTED)
        with open(self.lock_path(), "a+") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            held.write("4242\n")
            held.flush()
            rc, data, err = self.run_gate("--diff", "HEAD")
        self.assertEqual((rc, data), (2, None))
        self.assertIn("another mutation-test run (pid 4242)", err)

    def test_lock_file_left_by_a_dead_run_does_not_block(self):
        self.lock_path().write_text("4242\n")  # file present, nobody holds the flock
        (self.root / "calc.py").write_text(CALC + UNTESTED)
        rc, data, err = self.run_gate("--diff", "HEAD")
        self.assertEqual(rc, 1, err)

    def test_linked_worktree_is_not_blocked_by_a_run_on_the_main_tree(self):
        # each linked worktree has its own git dir, so the lock covers one tree, not the repository
        (self.root / "calc.py").write_text(CALC + UNTESTED)
        self.git("commit", "-qam", "untested")
        other = tempfile.TemporaryDirectory()
        self.addCleanup(other.cleanup)
        tree = Path(other.name) / "linked"
        self.git("worktree", "add", "-q", str(tree))
        with open(self.lock_path(), "a+") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            proc = subprocess.run([sys.executable, str(BIN), "--root", str(tree), "--json",
                                   "--test-command", self.test_command, "--diff", "HEAD~1"],
                                  capture_output=True, text=True, cwd=tree)
        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertNotIn("another mutation-test run", proc.stderr)

    def test_planted_lock_link_outside_git_is_refused_and_its_target_kept(self):
        # injection: outside git the lock is in the tree, so an untrusted archive can plant it as a
        # link; following it would write the pid over the target
        other = tempfile.TemporaryDirectory()
        self.addCleanup(other.cleanup)
        tree = Path(other.name) / "tree"
        tree.mkdir()
        for name in ("calc.py", "calc_test.py"):
            (tree / name).write_bytes((self.root / name).read_bytes())
        victim = Path(other.name) / "victim.txt"
        for plant in (os.symlink, os.link):
            with self.subTest(plant=plant.__name__):
                victim.write_text("precious\n")
                plant(victim, tree / ".mutation-test.lock")
                proc = subprocess.run([sys.executable, str(BIN), "--root", str(tree), "--json",
                                       "--test-command", self.test_command, "calc.py"],
                                      capture_output=True, text=True, cwd=tree)
                (tree / ".mutation-test.lock").unlink()
                self.assertEqual(proc.returncode, 2, proc.stderr)
                self.assertIn("lock file", proc.stderr)
                self.assertEqual(victim.read_text(), "precious\n")

    def test_compiled_module_shadowing_source_is_refused(self):
        (self.root / "calc.py").write_text(CALC + UNTESTED)
        (self.root / ("calc" + importlib.machinery.EXTENSION_SUFFIXES[0])).write_bytes(b"")
        rc, data, err = self.run_gate("--diff", "HEAD")
        self.assertEqual((rc, data), (2, None))
        self.assertIn("compiled modules shadow their source", err)
        self.assertIn("calc.py", err)

    def test_red_baseline_is_refused_before_any_mutant(self):
        (self.root / "calc.py").write_text(CALC + UNTESTED)
        rc, data, err = self.run_gate("--diff", "HEAD", command="exit 1")
        self.assertEqual((rc, data), (2, None))
        self.assertIn("baseline is red", err)

    def test_untracked_file_with_space_in_name_is_in_scope(self):
        (self.root / "new mod.py").write_text("def triple(x):\n    return x * 3\n")
        rc, data, err = self.run_gate("--diff", "HEAD")
        self.assertEqual(rc, 1, err)
        self.assertTrue(all(r["where"].startswith("new mod.py:2 ") for r in data["survivors"]))

    def test_tracked_file_with_space_in_name_is_in_scope(self):
        # git diff appends a tab to a +++ name containing a space; the parser must strip it
        (self.root / "old mod.py").write_text("def triple(x):\n    return x\n")
        self.git("add", ".")
        self.git("commit", "-qm", "space")
        (self.root / "old mod.py").write_text("def triple(x):\n    return x * 3\n")
        rc, data, err = self.run_gate("--diff", "HEAD")
        self.assertEqual(rc, 1, err)
        self.assertTrue(data["survivors"])
        self.assertTrue(all(r["where"].startswith("old mod.py:2 ") for r in data["survivors"]))

    def test_test_files_are_never_mutated(self):
        # injection: an --exclude of its own must not drop the default test-file exclusions
        (self.root / "calc_test.py").write_text(TESTS + "\n# touched\n")
        for extra in ((), ("--exclude", "generated.py")):
            with self.subTest(extra=extra):
                rc, data, err = self.run_gate("--diff", "HEAD", *extra)
                self.assertEqual((rc, data["mutants"], data["note"]), (0, 0, "no Python source in scope"), err)


if __name__ == "__main__":
    unittest.main()
