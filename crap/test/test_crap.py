"""Tests for crap/bin/crap. Run via crap/test/ci.sh."""

import ast
import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent / "bin" / "crap"
loader = importlib.machinery.SourceFileLoader("crap_tool", str(BIN))
crap = importlib.util.module_from_spec(importlib.util.spec_from_loader("crap_tool", loader))
sys.modules["crap_tool"] = crap  # dataclasses resolve annotations through sys.modules
loader.exec_module(crap)

SAMPLE = textwrap.dedent('''\
    def straight(x):
        return x + 1


    def branchy(x, items):
        if x > 0 and x < 10:
            return 1
        elif x == 0:
            return 0
        for i in items:
            while i:
                i -= 1
        try:
            pass
        except ValueError:
            pass
        return [y for y in items if y if y > 2]


    def matcher(cmd):
        match cmd:
            case "a":
                return 1
            case "b" if cmd:
                return 2
            case _:
                return 0


    def outer(flag):
        def inner(v):
            return v if v else 0
        if flag:
            return inner(1)
        return 0


    class Box:
        def method(self, v):
            return 1 if v else 2
    ''')


def cc_of(source, name):
    tree = ast.parse(source)
    for qual, node, _ in crap.functions(tree):
        if qual == name:
            return crap.complexity(node)
    raise KeyError(name)


def run(argv):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        rc = crap.main(argv)
    return rc, out.getvalue(), err.getvalue()


def write_report(path, files):
    path.write_text(json.dumps({"meta": {"version": "test"}, "files": files}))


class Complexity(unittest.TestCase):
    def test_straight_line_is_one(self):
        self.assertEqual(cc_of(SAMPLE, "straight"), 1)

    def test_counts_every_decision(self):
        # 1 + if + and + elif + for + while + except + comprehension(1 + 2 ifs) = 10
        self.assertEqual(cc_of(SAMPLE, "branchy"), 10)

    def test_match_skips_irrefutable_wildcard(self):
        self.assertEqual(cc_of(SAMPLE, "matcher"), 3)

    def test_match_irrefutable_capture_forms(self):
        for case, cc in (("value", 1), ("_", 1), ("(_ as y)", 1), ("(v as y)", 1), ("1", 2), ("[x, *_]", 2)):
            with self.subTest(case=case):
                src = f"def f(v):\n    match v:\n        case {case}:\n            pass\n"
                self.assertEqual(cc_of(src, "f"), cc)

    def test_nested_function_scored_separately(self):
        self.assertEqual(cc_of(SAMPLE, "outer"), 2)
        self.assertEqual(cc_of(SAMPLE, "outer.inner"), 2)

    def test_lambda_outside_functions_scored_inside_counted(self):
        src = textwrap.dedent('''\
            pick = lambda x, y: 1 if x else 2 if y and x else 3


            class K:
                key = staticmethod(lambda v: v or 0)


            def f(items):
                return sorted(items, key=lambda i: i if i else 0)
            ''')
        found = {qual: crap.complexity(node) for qual, node, _ in crap.functions(ast.parse(src))}
        self.assertEqual(found, {"<lambda>": 4, "K.<lambda>": 2, "f": 2})

    def test_method_qualname(self):
        self.assertEqual(cc_of(SAMPLE, "Box.method"), 2)


class Score(unittest.TestCase):
    def test_formula(self):
        self.assertEqual(crap.crap_score(5, 1.0), 5)
        self.assertEqual(crap.crap_score(5, 0.0), 30)
        self.assertAlmostEqual(crap.crap_score(4, 0.5), 16 * 0.125 + 4)

    def test_region_with_branches_uses_combined_percent(self):
        report = {"functions": {"f": {"summary": {"num_branches": 4, "percent_covered": 75.0,
                                                  "covered_lines": 1, "num_statements": 10}}}}
        self.assertEqual(crap.function_coverage("f", set(), report), (0.75, True))

    def test_line_fallback_without_regions(self):
        report = {"executed_lines": [1, 2, 3], "missing_lines": [4]}
        self.assertEqual(crap.function_coverage("f", {1, 2, 3, 4, 9}, report), (0.75, True))

    def test_line_fallback_counts_missed_branches(self):
        # injection: every line ran but one branch did not; without counting it the fallback reads
        # 100% and a cc=6 function scores exactly 6, passing a gate it should fail
        report = {"executed_lines": list(range(2, 13)), "missing_lines": [],
                  "executed_branches": [[3, 4]], "missing_branches": [[3, 5]]}
        cov, measured = crap.function_coverage("K.m", set(range(2, 13)), report)
        self.assertEqual((cov, measured), (12 / 13, True))
        self.assertGreater(crap.crap_score(6, cov), 6)

    def test_absent_file_is_unmeasured_and_uncovered(self):
        self.assertEqual(crap.function_coverage("f", {1}, None), (0.0, False))


class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "pkg").mkdir()
        (self.root / "pkg" / "mod.py").write_text(SAMPLE)
        (self.root / "pkg" / "mod_test.py").write_text("def test_x():\n    assert True\n")
        self.cov = self.root / "cov.json"

    def tearDown(self):
        self.tmp.cleanup()

    def regions(self, **percent):
        return {"functions": {name: {"summary": {"num_branches": 2, "percent_covered": pct,
                                                 "covered_lines": 0, "num_statements": 1}}
                              for name, pct in percent.items()}}

    def test_clean_report_exits_zero(self):
        write_report(self.cov, {"pkg/mod.py": self.regions(
            straight=100, branchy=100, matcher=100, outer=100, **{"outer.inner": 100, "Box.method": 100})})
        rc, out, _ = run(["--coverage", str(self.cov), "--root", str(self.root), "--threshold", "10"])
        self.assertEqual(rc, 0, out)
        self.assertIn("6 function(s) scored, 0 above 10", out)

    def test_uncovered_complex_function_fails_the_gate(self):
        # injection: branchy (cc=10) with zero coverage scores 110 and must trip the gate
        write_report(self.cov, {"pkg/mod.py": self.regions(
            straight=100, branchy=0, matcher=100, outer=100, **{"outer.inner": 100, "Box.method": 100})})
        rc, out, _ = run(["--coverage", str(self.cov), "--root", str(self.root)])
        self.assertEqual(rc, 1, out)
        self.assertRegex(out, r"FAIL crap=\s*110\.00 cc= 10 .*pkg/mod.py:5 branchy")

    def test_threshold_compares_unrounded_score(self):
        # cc=6 at 95.2% coverage scores 6.004, which rounds to 6.00 but is still above 6
        (self.root / "pkg" / "six.py").write_text(
            "def six(a, b, c, d, e):\n" + "".join(f"    if {v}:\n        pass\n" for v in "abcde"))
        write_report(self.cov, {"pkg/six.py": self.regions(six=95.2)})
        rc, out, _ = run(["--coverage", str(self.cov), "--root", str(self.root), "pkg/six.py"])
        self.assertEqual(rc, 1, out)
        self.assertIn("FAIL crap=    6.00 cc=  6", out)

    def test_untested_module_lambda_fails_the_gate(self):
        # injection: a module-level lambda (cc=4, uncovered) scores 20 and must not be skipped
        # its line is reported executed, as coverage.py does on import, though the body never ran
        (self.root / "pkg" / "lam.py").write_text("pick = lambda x, y: 1 if x else 2 if y and x else 3\n")
        write_report(self.cov, {"pkg/lam.py": {"executed_lines": [1], "missing_lines": []}})
        rc, out, _ = run(["--coverage", str(self.cov), "--root", str(self.root), "pkg/lam.py"])
        self.assertEqual(rc, 1, out)
        self.assertRegex(out, r"FAIL crap=\s*20\.00 cc=  4 .*pkg/lam.py:1 <lambda>")

    def test_test_files_excluded_by_default(self):
        write_report(self.cov, {"pkg/mod_test.py": {"executed_lines": [], "missing_lines": [2]}})
        rc, out, _ = run(["--coverage", str(self.cov), "--root", str(self.root), "pkg/mod_test.py"])
        self.assertEqual(rc, 0, out)
        self.assertIn("0 function(s) scored", out)

    def test_file_absent_from_report_is_scored_uncovered(self):
        # injection: pkg/mod.py is on disk but the report names only another file; branchy
        # (cc=10, uncovered) scores 110 and must trip the gate rather than be skipped
        (self.root / "pkg" / "other.py").write_text("def ok():\n    return 1\n")
        write_report(self.cov, {"pkg/other.py": self.regions(ok=100)})
        for in_git in (False, True):
            with self.subTest(in_git=in_git):
                if in_git:
                    subprocess.run(["git", "-C", str(self.root), "init", "-q"], check=True)
                rc, out, _ = run(["--coverage", str(self.cov), "--root", str(self.root)])
                self.assertEqual(rc, 1, out)
                self.assertRegex(out, r"FAIL crap=\s*110\.00 cc= 10 cov=  n/a .*pkg/mod.py:5 branchy")

    def test_json_output(self):
        write_report(self.cov, {"pkg/mod.py": self.regions(straight=100)})
        rc, out, _ = run(["--coverage", str(self.cov), "--root", str(self.root), "--json", "pkg/mod.py"])
        data = json.loads(out)
        by_name = {s["name"]: s for s in data["scores"]}
        self.assertEqual(by_name["straight"]["crap"], 1)
        # full coverage cannot rescue complexity: at cov=1 CRAP == cc, so branchy (cc=10) still fails
        self.assertEqual(by_name["branchy"]["crap"], 10)
        self.assertEqual((rc, data["violations"]), (1, 1))

    def test_non_finite_threshold_is_usage_error(self):
        # injection: with nan every `crap > threshold` is false, so branchy (CRAP 110) would pass
        write_report(self.cov, {"pkg/mod.py": self.regions(branchy=0)})
        for bad in ("nan", "inf", "-inf", "six"):
            with self.subTest(threshold=bad):
                with self.assertRaises(SystemExit) as ctx:
                    run(["--coverage", str(self.cov), "--root", str(self.root), "--threshold", bad])
                self.assertEqual(ctx.exception.code, 2)

    def test_malformed_input_is_usage_error(self):
        (self.root / "pkg" / "latin.py").write_bytes(b'def f():\n    return "\xff"\n')
        cases = {"non-UTF-8 report": (b'{"files": {}}\xff', "pkg/mod.py"),
                 "non-UTF-8 source": (b'{"files": {}}', "pkg/latin.py"),
                 "region without summary": (b'{"files": {"pkg/mod.py": {"functions": {"straight": {}}}}}',
                                            "pkg/mod.py"),
                 "top level not an object": (b'"files"', "pkg/mod.py"),
                 "files not an object": (b'{"files": []}', "pkg/mod.py"),
                 "file entry not an object": (b'{"files": {"pkg/mod.py": []}}', "pkg/mod.py"),
                 "functions not an object": (b'{"files": {"pkg/mod.py": {"functions": []}}}', "pkg/mod.py"),
                 "region not an object": (b'{"files": {"pkg/mod.py": {"functions": {"straight": []}}}}',
                                          "pkg/mod.py")}
        for label, (report, path) in cases.items():
            with self.subTest(label):
                self.cov.write_bytes(report)
                rc, _, err = run(["--coverage", str(self.cov), "--root", str(self.root), path])
                self.assertEqual(rc, 2, err)
                self.assertTrue(err.startswith("crap: "), err)

    def test_missing_report_is_usage_error(self):
        rc, _, err = run(["--coverage", str(self.root / "nope.json"), "--root", str(self.root)])
        self.assertEqual(rc, 2)
        self.assertIn("cannot read coverage report", err)

    def test_diff_scopes_to_touched_functions(self):
        git = lambda *a: subprocess.run(["git", "-C", str(self.root), *a], check=True,
                                        capture_output=True)
        git("init", "-q")
        git("-c", "user.email=t@t", "-c", "user.name=t", "add", "pkg/mod.py")
        git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base")
        source = SAMPLE.replace("return x + 1", "return x + 2")  # touch only `straight`
        (self.root / "pkg" / "mod.py").write_text(source)
        write_report(self.cov, {"pkg/mod.py": {"executed_lines": [], "missing_lines": list(range(1, 60))}})
        rc, out, _ = run(["--coverage", str(self.cov), "--root", str(self.root), "--diff", "HEAD", "--json"])
        names = [s["name"] for s in json.loads(out)["scores"]]
        self.assertEqual(names, ["straight"])
        self.assertEqual(rc, 0)  # straight uncovered: 1*1*1 + 1 = 2 <= 6

    def test_bad_diff_base_is_usage_error(self):
        subprocess.run(["git", "-C", str(self.root), "init", "-q"], check=True)
        write_report(self.cov, {})
        rc, _, err = run(["--coverage", str(self.cov), "--root", str(self.root), "--diff", "no-such-rev"])
        self.assertEqual(rc, 2)
        self.assertIn("git diff against 'no-such-rev' failed", err)


class NoSilentOmission(unittest.TestCase):
    """Injection: each case hides an uncovered cc=8 function (CRAP 72) where an earlier version
    scored nothing and exited 0. Every one must trip the gate."""

    BAD = "def bad(a, b, c, d, e, f, g):\n" + "".join(f"    if {v}:\n        pass\n" for v in "abcdefg")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.cov = self.root / "cov.json"
        write_report(self.cov, {})
        self.git("init", "-q")
        (self.root / "base.py").write_text(self.BAD)
        self.git("add", "base.py")
        self.git("commit", "-qm", "base")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "-C", str(self.root), *args],
                       check=True, capture_output=True)

    def assert_fails(self, rel, *argv):
        rc, out, err = run(["--coverage", str(self.cov), "--root", str(self.root), *argv])
        self.assertEqual(rc, 1, out + err)
        self.assertIn(f"{rel}:1 bad", out)

    def test_unusual_names_in_full_scan_and_diff(self):
        for name in ("sp ace.py", "naïve.py"):
            (self.root / name).write_text(self.BAD)
            self.git("add", name)
            with self.subTest(name=name):
                self.assert_fails(name)
                self.assert_fails(name, "--diff", "HEAD")

    def test_untracked_file_counts_as_changed(self):
        (self.root / "new.py").write_text(self.BAD)
        self.assert_fails("new.py", "--diff", "HEAD")

    def test_pure_deletion_rescores_the_function(self):
        (self.root / "base.py").write_text(self.BAD.replace("    if g:\n        pass\n", ""))
        self.assert_fails("base.py", "--diff", "HEAD")

    def test_deletion_at_either_end_rescores_the_function(self):
        (self.root / "dec.py").write_text("@cache\n" + self.BAD)
        self.git("add", "dec.py")
        self.git("commit", "-qm", "decorated")
        cases = {"dec.py": self.BAD,  # decorator deleted: hunk +0,0, before the def
                 "base.py": self.BAD.removesuffix("    if g:\n        pass\n")}  # last block deleted
        for rel, text in cases.items():
            with self.subTest(rel=rel):
                (self.root / rel).write_text(text)
                self.assert_fails(rel, "--diff", "HEAD", rel)

    def test_diff_prefix_config_cannot_empty_the_scope(self):
        # injection: diff.mnemonicPrefix turns `+++ b/x` into `+++ w/x`, which matched no file
        (self.root / "base.py").write_text(self.BAD.replace("if a:", "if a or b:"))
        for key, value in (("diff.mnemonicPrefix", "true"), ("diff.noprefix", "true"), ("diff.dstPrefix", "y/")):
            env = {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": key, "GIT_CONFIG_VALUE_0": value}
            with self.subTest(key=key), mock.patch.dict(os.environ, env):
                self.assert_fails("base.py", "--diff", "HEAD")

    def test_name_pattern_spares_source_under_test_prefixed_dir(self):
        (self.root / "test_utils").mkdir()
        (self.root / "test_utils" / "helper.py").write_text(self.BAD)
        self.assert_fails("test_utils/helper.py", "test_utils")

    def test_path_argument_forms(self):
        for arg in ("./base.py", str(self.root / "base.py"), "."):
            with self.subTest(arg=arg):
                self.assert_fails("base.py", arg)

    def test_top_level_tests_dir_is_excluded(self):
        (self.root / "tests").mkdir()
        (self.root / "tests" / "helpers.py").write_text(self.BAD)
        rc, out, _ = run(["--coverage", str(self.cov), "--root", str(self.root), "tests"])
        self.assertEqual((rc, out.splitlines()[-1]), (0, "0 function(s) scored, 0 above 6"))


if __name__ == "__main__":
    unittest.main()
