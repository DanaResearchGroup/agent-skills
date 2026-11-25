"""Tests for factory-machine/bin/factory-machine.

Every test builds its own fake machine.env and planes file in a temp dir and
points the helper at them with FACTORY_MACHINE_ENV and FACTORY_PLANES. HOME is
also a temp dir, so no test reads the real ~/.config/factory.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HELPER = Path(__file__).resolve().parent.parent / "bin" / "factory-machine"

PLANES = """\
# slug  repo              owning_persona  zone
alpha   example/alpha-pm  persona-one     any
beta    example/beta-pm   persona-two     hl-only
"""


class Box:
    """One fake machine: a temp HOME, a machine.env and a planes file."""

    def __init__(self, tmp: Path, machine: str | None, extra: str = "") -> None:
        self.home = tmp / "home"
        self.home.mkdir(parents=True, exist_ok=True)
        self.env_file = tmp / "machine.env"
        self.planes_file = tmp / "planes"
        self.planes_file.write_text(PLANES)
        self.exchange = self.home / "exchange"
        if machine == "HL":
            body = (
                "MACHINE=HL\n"
                "HAS_DISPLAY=1\n"
                f"EXCHANGE_ROOT={self.exchange}\n"
                'PEERS="LMF OL"\n'
                "HAS_VAULT=1\n"
                "HAS_SLACK=1\n"
                "HAS_HERDR=1\n"
            )
        elif machine in ("LMF", "OL"):
            body = (
                f"MACHINE={machine}\n"
                "HAS_DISPLAY=0\n"
                f"EXCHANGE_ROOT={self.exchange}/hl\n"
                "PEERS=HL\n"
                f"HL_EXCHANGE_ROOT=/srv/hl-home/exchange/{machine.lower()}\n"
                "HAS_HERDR=1\n"
            )
        else:
            body = ""
        if machine is not None:
            self.env_file.write_text(body + extra)

    def run(self, *args: str, cwd: Path | None = None,
            extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(self.home),
            "FACTORY_MACHINE_ENV": str(self.env_file),
            "FACTORY_PLANES": str(self.planes_file),
        }
        env.update(extra_env or {})
        return subprocess.run(
            [sys.executable, str(HELPER), *args],
            capture_output=True, text=True, env=env, cwd=cwd, timeout=30,
        )


class Base(unittest.TestCase):
    machine: str | None = "HL"
    extra = ""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.box = Box(Path(self._tmp.name), self.machine, self.extra)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def ok(self, *args: str, **kw) -> str:
        r = self.box.run(*args, **kw)
        self.assertEqual(r.returncode, 0, f"{args}: rc={r.returncode} err={r.stderr!r}")
        self.assertEqual(r.stderr, "")
        return r.stdout

    def refused(self, *args: str, needles: tuple[str, ...] = (), **kw) -> str:
        r = self.box.run(*args, **kw)
        self.assertEqual(r.returncode, 2, f"{args}: rc={r.returncode} out={r.stdout!r}")
        self.assertEqual(r.stdout, "")
        lines = r.stderr.splitlines()
        self.assertEqual(len(lines), 1, f"want one line, got {r.stderr!r}")
        for n in needles:
            self.assertIn(n, lines[0])
        return lines[0]


class HLTest(Base):
    machine = "HL"

    def test_get(self):
        self.assertEqual(self.ok("get", "MACHINE"), "HL\n")
        self.assertEqual(self.ok("get", "PEERS"), "LMF OL\n")
        self.assertEqual(self.ok("get", "EXCHANGE_ROOT"), f"{self.box.exchange}\n")

    def test_get_hl_exchange_root_refused_on_hl(self):
        self.refused("get", "HL_EXCHANGE_ROOT",
                     needles=(str(self.box.env_file), "HL_EXCHANGE_ROOT"))

    def test_show(self):
        self.assertEqual(self.ok("show"), (
            "MACHINE=HL\n"
            "HAS_DISPLAY=1\n"
            f"EXCHANGE_ROOT={self.box.exchange}\n"
            "PEERS=LMF OL\n"
            "HAS_VAULT=1\n"
            "HAS_SLACK=1\n"
            "HAS_HERDR=1\n"
        ))

    def test_may_open_browser(self):
        self.assertEqual(self.box.run("may-open-browser").returncode, 0)

    def test_artifact_dir_is_show_me_folder(self):
        want = f"{self.box.home}/Dropbox/remote-work/show-me\n"
        self.assertEqual(self.ok("artifact-dir", "alpha"), want)
        # an hl-only plane stays on HL, so HL may place its artifacts
        self.assertEqual(self.ok("artifact-dir", "beta", "show-me"), want)

    def test_artifact_dir_honours_show_me_dir(self):
        out = self.ok("artifact-dir", "alpha", extra_env={"SHOW_ME_DIR": "/srv/elsewhere"})
        self.assertEqual(out, "/srv/elsewhere\n")
        # an empty SHOW_ME_DIR falls back, as ${SHOW_ME_DIR:-...} does
        out = self.ok("artifact-dir", "alpha", extra_env={"SHOW_ME_DIR": ""})
        self.assertEqual(out, f"{self.box.home}/Dropbox/remote-work/show-me\n")

    def test_artifact_dir_unknown_plane_refused(self):
        self.refused("artifact-dir", "gamma", needles=("gamma", str(self.box.planes_file)))

    def test_exchange_dir(self):
        self.assertEqual(self.ok("exchange-dir", "LMF"), f"{self.box.exchange}/LMF\n")
        self.assertEqual(self.ok("exchange-dir", "OL"), f"{self.box.exchange}/OL\n")

    def test_exchange_dir_unknown_peer_refused(self):
        self.refused("exchange-dir", "XYZ", needles=("XYZ",))
        self.refused("exchange-dir", "HL", needles=("HL",))

    def test_hl_path_refused_on_hl(self):
        self.refused("hl-path", f"{self.box.exchange}/LMF/x", needles=("hl-path",))

    def test_has(self):
        for cap in ("vault", "slack", "herdr", "display"):
            self.assertEqual(self.box.run("has", cap).returncode, 0, cap)

    def test_has_unknown_cap_refused(self):
        self.refused("has", "teleport", needles=("teleport",))

    def test_planes(self):
        self.assertEqual(self.ok("planes"), "alpha\nbeta\n")
        self.assertEqual(self.ok("planes", "--zone", "any"), "alpha\n")
        self.assertEqual(self.ok("planes", "--zone", "hl-only"), "beta\n")

    def test_planes_bad_zone_refused(self):
        self.refused("planes", "--zone", "anywhere", needles=("anywhere",))

    def test_plane(self):
        self.assertEqual(self.ok("plane", "alpha"), "alpha example/alpha-pm persona-one any\n")
        self.assertEqual(self.ok("plane", "beta"), "beta example/beta-pm persona-two hl-only\n")

    def test_plane_deny_by_default(self):
        self.refused("plane", "gamma", needles=("gamma", str(self.box.planes_file)))
        self.refused("plane", "alph", needles=("alph",))

    def test_unknown_subcommand_refused(self):
        self.refused("teleport")
        self.refused()


class PeerMixin:
    def test_get(self):
        self.assertEqual(self.ok("get", "MACHINE"), f"{self.machine}\n")
        self.assertEqual(self.ok("get", "PEERS"), "HL\n")
        self.assertEqual(self.ok("get", "HL_EXCHANGE_ROOT"),
                         f"/srv/hl-home/exchange/{self.machine.lower()}\n")

    def test_get_optional_missing_means_zero(self):
        self.assertEqual(self.ok("get", "HAS_VAULT"), "0\n")
        self.assertEqual(self.ok("get", "HAS_HERDR"), "1\n")

    def test_show(self):
        self.assertEqual(self.ok("show"), (
            f"MACHINE={self.machine}\n"
            "HAS_DISPLAY=0\n"
            f"EXCHANGE_ROOT={self.box.exchange}/hl\n"
            "PEERS=HL\n"
            f"HL_EXCHANGE_ROOT=/srv/hl-home/exchange/{self.machine.lower()}\n"
            "HAS_VAULT=0\n"
            "HAS_SLACK=0\n"
            "HAS_HERDR=1\n"
        ))

    def test_may_open_browser_no(self):
        self.assertEqual(self.box.run("may-open-browser").returncode, 1)

    def test_artifact_dir(self):
        root = f"{self.box.exchange}/hl/to-hl/artifacts"
        self.assertEqual(self.ok("artifact-dir", "alpha"), f"{root}/alpha/show-me\n")
        self.assertEqual(self.ok("artifact-dir", "alpha", "report"), f"{root}/alpha/report\n")

    def test_artifact_dir_hl_only_plane_refused(self):
        self.refused("artifact-dir", "beta", needles=("beta", "hl-only"))

    def test_artifact_dir_unknown_plane_refused(self):
        self.refused("artifact-dir", "gamma", needles=("gamma",))

    def test_artifact_dir_bad_segments_refused(self):
        self.refused("artifact-dir", "alpha", "../x")
        self.refused("artifact-dir", "alpha", "a/b")
        self.refused("artifact-dir", "alpha", "")

    def test_exchange_dir_refused_on_peer(self):
        self.refused("exchange-dir", "HL", needles=("exchange-dir",))
        self.refused("exchange-dir", "LMF", needles=("exchange-dir",))

    def test_hl_path(self):
        p = f"{self.box.exchange}/hl/to-hl/artifacts/alpha/show-me/x.html"
        self.assertEqual(self.ok("hl-path", p),
                         f"/srv/hl-home/exchange/{self.machine.lower()}"
                         "/to-hl/artifacts/alpha/show-me/x.html\n")
        self.assertEqual(self.ok("hl-path", f"{self.box.exchange}/hl"),
                         f"/srv/hl-home/exchange/{self.machine.lower()}\n")

    def test_hl_path_relative_resolves_from_cwd(self):
        cwd = self.box.exchange / "hl" / "to-hl"
        cwd.mkdir(parents=True)
        self.assertEqual(self.ok("hl-path", "notes.md", cwd=cwd),
                         f"/srv/hl-home/exchange/{self.machine.lower()}/to-hl/notes.md\n")

    def test_hl_path_outside_root_refused(self):
        self.refused("hl-path", f"{self.box.exchange}/hl-other/x", needles=("EXCHANGE_ROOT",))
        self.refused("hl-path", f"{self.box.exchange}/hl/../secret", needles=("EXCHANGE_ROOT",))
        self.refused("hl-path", "/etc/passwd", needles=("EXCHANGE_ROOT",))

    def test_has(self):
        self.assertEqual(self.box.run("has", "herdr").returncode, 0)
        for cap in ("vault", "slack", "display"):
            self.assertEqual(self.box.run("has", cap).returncode, 1, cap)

    def test_planes_and_plane(self):
        self.assertEqual(self.ok("planes"), "alpha\nbeta\n")
        self.assertEqual(self.ok("plane", "beta"), "beta example/beta-pm persona-two hl-only\n")
        self.refused("plane", "gamma", needles=("gamma",))


class LMFTest(PeerMixin, Base):
    machine = "LMF"


class OLTest(PeerMixin, Base):
    machine = "OL"


class RoundTripTest(unittest.TestCase):
    """A file a peer writes under its exchange root is the file HL finds
    under exchange-dir for that peer."""

    def test_round_trip(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            hl = Box(tmp / "hl", "HL")
            lmf = Box(tmp / "lmf", None)
            lmf.env_file.write_text(
                "MACHINE=LMF\nHAS_DISPLAY=0\n"
                f"EXCHANGE_ROOT={lmf.exchange}/hl\nPEERS=HL\n"
                f"HL_EXCHANGE_ROOT={hl.exchange}/LMF\n"
            )
            art = lmf.run("artifact-dir", "alpha").stdout.strip()
            self.assertTrue(art.startswith(f"{lmf.exchange}/hl/"), art)
            on_hl = lmf.run("hl-path", f"{art}/page.html").stdout.strip()
            hl_side = hl.run("exchange-dir", "LMF").stdout.strip()
            rel = os.path.relpath(f"{art}/page.html", f"{lmf.exchange}/hl")
            self.assertEqual(on_hl, os.path.join(hl_side, rel))
            self.assertEqual(rel, "to-hl/artifacts/alpha/show-me/page.html")


class MalformedTest(unittest.TestCase):
    """Each fault: exit 2, nothing on stdout, one stderr line naming the file."""

    def check(self, body: str | None, *needles: str, args=("show",)) -> None:
        with tempfile.TemporaryDirectory() as t:
            box = Box(Path(t), None)
            if body is not None:
                box.env_file.write_text(body)
            r = box.run(*args)
            self.assertEqual(r.returncode, 2, f"{body!r}: rc={r.returncode} out={r.stdout!r}")
            self.assertEqual(r.stdout, "")
            lines = r.stderr.splitlines()
            self.assertEqual(len(lines), 1, r.stderr)
            self.assertIn(str(box.env_file), lines[0])
            for n in needles:
                self.assertIn(n, lines[0])

    HL_OK = 'MACHINE=HL\nHAS_DISPLAY=1\nEXCHANGE_ROOT=/srv/x/exchange\nPEERS="LMF OL"\n'
    PEER_OK = "MACHINE=OL\nHAS_DISPLAY=0\nEXCHANGE_ROOT=/srv/x/exchange/hl\nPEERS=HL\n"

    def test_missing_file(self):
        self.check(None, "missing")
        # every subcommand that reads the file fails the same way
        for args in (("get", "MACHINE"), ("may-open-browser",), ("has", "display"),
                     ("artifact-dir", "alpha"), ("exchange-dir", "LMF"), ("hl-path", "/x")):
            self.check(None, "missing", args=args)

    def test_bad_lines(self):
        for bad in ("MACHINE HL\n", "machine=HL\n", "PEERS=LMF OL\n", "MACHINE=$(echo HL)\n",
                    "MACHINE=`echo HL`\n", 'MACHINE="HL\n', "MACHINE=HL # c\n",
                    "MACHINE=HL; rm -rf x\n", "=HL\n", "EXCHANGE_ROOT=$OTHER/x\n"):
            with self.subTest(bad=bad):
                self.check(self.HL_OK.replace("MACHINE=HL\n", "") + bad, "line")

    def test_unknown_machine(self):
        self.check(self.HL_OK.replace("MACHINE=HL", "MACHINE=HOME"), "MACHINE", "HOME")
        self.check(self.HL_OK.replace("MACHINE=HL", "MACHINE=hl"), "MACHINE")

    def test_missing_machine(self):
        self.check(self.HL_OK.replace("MACHINE=HL\n", ""), "MACHINE")

    def test_peer_without_hl_exchange_root(self):
        self.check(self.PEER_OK, "HL_EXCHANGE_ROOT")
        self.check(self.PEER_OK, "HL_EXCHANGE_ROOT", args=("artifact-dir", "alpha"))

    def test_hl_with_hl_exchange_root(self):
        self.check(self.HL_OK + "HL_EXCHANGE_ROOT=/srv/x\n", "HL_EXCHANGE_ROOT")

    def test_unknown_key_in_file(self):
        self.check(self.HL_OK + "HAS_JETPACK=1\n", "HAS_JETPACK")

    def test_unknown_key_get(self):
        with tempfile.TemporaryDirectory() as t:
            box = Box(Path(t), "HL")
            r = box.run("get", "HAS_JETPACK")
            self.assertEqual(r.returncode, 2)
            self.assertEqual(r.stdout, "")
            self.assertIn("HAS_JETPACK", r.stderr)
            self.assertIn(str(box.env_file), r.stderr)
            self.assertEqual(len(r.stderr.splitlines()), 1)

    def test_duplicate_key(self):
        self.check(self.HL_OK + "MACHINE=HL\n", "MACHINE")

    def test_bad_flags(self):
        self.check(self.HL_OK.replace("HAS_DISPLAY=1", "HAS_DISPLAY=yes"), "HAS_DISPLAY")
        self.check(self.HL_OK + "HAS_VAULT=2\n", "HAS_VAULT")

    def test_bad_peers(self):
        self.check(self.HL_OK.replace('"LMF OL"', '"LMF HL"'), "PEERS")
        self.check(self.HL_OK.replace('"LMF OL"', '""'), "PEERS")
        self.check(self.PEER_OK.replace("PEERS=HL", "PEERS=LMF") + "HL_EXCHANGE_ROOT=/srv/y\n",
                   "PEERS")

    def test_relative_path(self):
        self.check(self.HL_OK.replace("/srv/x/exchange", "exchange"), "EXCHANGE_ROOT")

    def test_never_guesses_from_host(self):
        # an empty FACTORY_MACHINE_ENV falls back to the default path under
        # HOME, which does not exist in the temp HOME: still a fault
        with tempfile.TemporaryDirectory() as t:
            box = Box(Path(t), None)
            r = box.run("get", "MACHINE", extra_env={"FACTORY_MACHINE_ENV": ""})
            self.assertEqual(r.returncode, 2)
            self.assertIn(f"{box.home}/.config/factory/machine.env", r.stderr)


class ShellSyntaxTest(Base):
    machine = None

    def test_comments_export_quotes_and_tilde(self):
        self.box.env_file.write_text(
            "# written by the owner's install\n"
            "\n"
            "export MACHINE='OL'\n"
            'HAS_DISPLAY="0"\n'
            "EXCHANGE_ROOT=~/exchange/hl\n"
            "PEERS=HL\n"
            'HL_EXCHANGE_ROOT="$HOME/elsewhere/ol"\n'
        )
        self.assertEqual(self.ok("get", "MACHINE"), "OL\n")
        self.assertEqual(self.ok("get", "EXCHANGE_ROOT"), f"{self.box.home}/exchange/hl\n")
        self.assertEqual(self.ok("get", "HL_EXCHANGE_ROOT"), f"{self.box.home}/elsewhere/ol\n")


class PlanesFileTest(Base):
    machine = "OL"

    def test_missing_planes_file(self):
        self.box.planes_file.unlink()
        self.refused("planes", needles=(str(self.box.planes_file), "missing"))
        self.refused("plane", "alpha", needles=(str(self.box.planes_file),))
        self.refused("artifact-dir", "alpha", needles=(str(self.box.planes_file),))

    def test_malformed_planes(self):
        for bad in ("gamma example/g persona any extra\n", "gamma example/g persona\n",
                    "gamma example/g persona everywhere\n", "alpha example/a2 p any\n",
                    "../g example/g persona any\n"):
            with self.subTest(bad=bad):
                self.box.planes_file.write_text(PLANES + bad)
                self.refused("planes", needles=(str(self.box.planes_file), "line"))

    def test_planes_does_not_need_machine_env(self):
        self.box.env_file.unlink()
        self.assertEqual(self.ok("planes"), "alpha\nbeta\n")


class NoWritesTest(Base):
    machine = "LMF"

    def test_no_writes(self):
        before = sorted(p for p in Path(self._tmp.name).rglob("*"))
        for args in (("show",), ("artifact-dir", "alpha"), ("hl-path", f"{self.box.exchange}/hl/x"),
                     ("planes",), ("plane", "alpha"), ("may-open-browser",)):
            self.box.run(*args)
        after = sorted(p for p in Path(self._tmp.name).rglob("*"))
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
