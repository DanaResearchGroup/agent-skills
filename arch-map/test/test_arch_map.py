"""Tests for arch-map/bin/arch-map. Run via arch-map/test/ci.sh."""

import importlib.machinery
import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent / "bin" / "arch-map"
loader = importlib.machinery.SourceFileLoader("arch_map_tool", str(BIN))
am = importlib.util.module_from_spec(importlib.util.spec_from_loader("arch_map_tool", loader))
sys.modules["arch_map_tool"] = am
loader.exec_module(am)

# app/ : core <-> util form a cycle; api -> core; core/__init__ re-exports Engine from core.engine
FILES = {
    "app/__init__.py": "from app import api, core, util\n\nVERSION = 1\n",
    "app/api/__init__.py": "",
    "app/api/routes.py": "from app.core import Engine\nfrom ..util import helpers\n",
    "app/core/__init__.py": "from .engine import Engine\n",
    "app/core/engine.py": "from app.util.helpers import fmt\n\nclass Engine:\n    pass\n\ndef run(x, y):\n    return go(x, y)\n",
    "app/util/__init__.py": "",
    "app/util/helpers.py": "import app.core.engine\nfrom app import VERSION\n\ndef fmt(s):\n    return s\n",
    "app/util/helpers_test.py": "import app.api.routes\n",
    "app/core/sub/__init__.py": "",
    "app/core/sub/leaf.py": "from app.core import engine\n\nclass Child(Base):\n    def __init__(self, a):\n        super().__init__(a)\n",
}


def run(argv):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        rc = am.main(argv)
    return rc, out.getvalue(), err.getvalue()


class ArchMap(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for rel, text in FILES.items():
            (self.root / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.root / rel).write_text(text)
        self.out = self.root / "out"

    def tearDown(self):
        self.tmp.cleanup()

    def data(self, *argv):
        rc, out, err = run(["--root", str(self.root), "--out", str(self.out), *argv])
        self.assertIn(rc, (0, 1), err)
        return rc, json.loads((self.out / "arch-map.json").read_text()), out

    def test_edges_resolve_relative_absolute_and_reexported(self):
        _, d, _ = self.data("app")
        edges = {tuple(e) for e in d["module_edges"]}
        self.assertIn(("app.api.routes", "app.core.engine"), edges)  # via the core/__init__ re-export
        self.assertNotIn(("app.api.routes", "app.core"), edges)
        self.assertIn(("app.api.routes", "app.util.helpers"), edges)  # relative `from ..util import`
        self.assertIn(("app.util.helpers", "app.core.engine"), edges)  # plain `import a.b.c`
        self.assertIn(("app.core.sub.leaf", "app.core.engine"), edges)  # `from pkg import submodule`

    def test_reexported_submodule_resolves_to_the_submodule(self):
        # injection: `from .sub import child` in pkg/__init__ named the package pkg.sub, so
        # `from pkg import child` counted against pkg.sub and a rule on pkg.sub.child passed
        files = {"pkg/__init__.py": "from .sub import child\n", "pkg/sub/__init__.py": "",
                 "pkg/sub/child.py": "X = 1\n", "pkg/client.py": "from pkg import child\n"}
        for rel, text in files.items():
            (self.root / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.root / rel).write_text(text)
        _, d, _ = self.data("pkg")
        edges = {tuple(e) for e in d["module_edges"]}
        self.assertIn(("pkg.client", "pkg.sub.child"), edges)
        self.assertNotIn(("pkg.client", "pkg.sub"), edges)
        path = self.root / "arch-rules.toml"
        path.write_text('forbid = ["pkg.client -> pkg.sub.child"]\n')
        rc, out, _ = run(["--root", str(self.root), "pkg", "--rules", str(path)])
        self.assertEqual(rc, 1, out)

    def test_test_files_are_excluded(self):
        _, d, _ = self.data("app")
        self.assertNotIn("app.util.helpers_test", d["modules"])

    def test_cycle_found_and_root_hub_left_out(self):
        _, d, _ = self.data("app")
        # app/__init__ imports every package; counting it would put them all in one cycle
        self.assertEqual(d["cycles"], [["app.core", "app.util"]])

    def test_subpackage_resolves_absolute_imports(self):
        _, d, _ = self.data("app.core")
        self.assertEqual(sorted(d["modules"]), ["app.core", "app.core.engine", "app.core.sub", "app.core.sub.leaf"])
        self.assertIn(["app.core.sub.leaf", "app.core.engine"], d["module_edges"])
        self.assertEqual(d["groups"], ["app.core", "app.core.engine", "app.core.sub"])

    def test_depth_report(self):
        _, d, _ = self.data("app")
        rows = {r["module"]: r for r in d["depth"]}
        self.assertEqual(rows["app.core.engine"]["fan_in"], 4)  # routes, helpers, leaf, core/__init__
        self.assertEqual(rows["app.core.engine"]["public"], 2)
        self.assertEqual(rows["app.core.engine"]["pass_through"], ["run"])
        self.assertEqual(rows["app.core.sub.leaf"]["pass_through"], [])  # super().__init__ is not shallow

    def test_outputs_written(self):
        self.data("app")
        mmd = (self.out / "arch-map.mmd").read_text()
        self.assertTrue(mmd.startswith("graph LR"))
        self.assertIn("classDef cycle", mmd)
        html = (self.out / "arch-map.html").read_text()
        self.assertNotIn("/*__DATA__*/null", html)
        for loader in ("src=", "<link", "fetch(", "import(", "XMLHttpRequest"):
            self.assertNotIn(loader, html, "the viewer must load nothing over the network")

    def rules(self, text):
        path = self.root / "arch-rules.toml"
        path.write_text(text)
        return run(["--root", str(self.root), "app", "--rules", str(path)])

    def test_forbidden_edge_fails(self):
        rc, out, _ = self.rules('forbid = ["app.util -> app.core"]\n')
        self.assertEqual(rc, 1)
        self.assertIn("FAIL forbidden edge app.util.helpers -> app.core.engine", out)
        rc, _, _ = self.rules('forbid = ["app.core -> app.api"]\n')
        self.assertEqual(rc, 0)

    @unittest.skipUnless(shutil.which("node"), "needs node to run the viewer's script")
    def test_viewer_renders_report_strings_as_text(self):
        # injection: a forbid glob reaches the violation list; `[a<img …>]` still matches `app`, and
        # `</script>` would close the tag the report is embedded in
        hostile = "[a<img src=x onerror=alert(1)></script>]pp.util -> app.core"
        rc, _, err = self.rules(f'forbid = ["{hostile}"]\n')
        self.assertEqual(rc, 1, err)
        run(["--root", str(self.root), "--out", str(self.out), "app", "--rules", str(self.root / "arch-rules.toml")])
        page = (self.out / "arch-map.html").read_text()
        script = page.split("<script>", 1)[1].split("</script>", 1)[0]
        stub = """
            const writes = [];
            const mk = () => ({attrs: {}, classList: {add() {}, remove() {}}, appendChild() {},
              setAttribute(k, v) { this.attrs[k] = v; }, addEventListener() {},
              set innerHTML(v) { writes.push(v); }, set textContent(v) {}});
            const els = {};
            globalThis.document = {getElementById: id => els[id] || (els[id] = mk()), createElementNS: mk};
            globalThis.location = {hash: ""};
        """ + script + "\nD.groups.forEach(g => { select(g); select(g); });\nconsole.log(JSON.stringify(writes));"
        proc = subprocess.run(["node", "-e", stub], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        html = "".join(json.loads(proc.stdout))
        self.assertIn("&lt;img src=x onerror=alert(1)&gt;&lt;/script&gt;", html)  # the rule is shown...
        self.assertNotIn("<img", html)  # ...as text, never as markup
        self.assertNotIn("onclick=", html)

    def test_cycles_modes(self):
        self.assertEqual(self.rules('cycles = "none"\n')[0], 1)
        self.assertEqual(self.rules('cycles = "allow"\n')[0], 0)
        self.assertEqual(self.rules('cycles = "no-new"\nknown_cycles = [["app.core", "app.util"]]\n')[0], 0)
        rc, out, _ = self.rules('cycles = "no-new"\nknown_cycles = []\n')
        self.assertEqual(rc, 1)
        self.assertIn("FAIL package cycle: app.core <-> app.util", out)

    def test_bad_input_exits_two(self):
        self.assertEqual(self.rules('forbid = ["nonsense"]\n')[0], 2)
        self.assertEqual(self.rules('cycles = "maybe"\n')[0], 2)
        self.assertEqual(run(["--root", str(self.root), "nope"])[0], 2)

    def test_root_inside_a_package_is_refused(self):
        rc, _, err = run(["--root", str(self.root / "app"), "core"])
        self.assertEqual(rc, 2)
        self.assertIn("inside a package", err)


if __name__ == "__main__":
    unittest.main()
