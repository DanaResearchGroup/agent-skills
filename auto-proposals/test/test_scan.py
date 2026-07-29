import json
import os
import shutil
import subprocess
import sys
import unittest
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from test._env import make_test_root  # noqa: E402

from lib.paths import PathRefused  # noqa: E402
from lib.publish import _compose_content  # noqa: E402
from lib.scan import (  # noqa: E402
    CallInfo,
    bootstrap_states_path,
    days_until,
    find_calls,
    load_bootstrap_states,
    read_states,
    render_open_md,
    resolve_states,
    skip_reasons,
    workable,
)


def _owned_frontmatter(**overrides):
    d = {
        "artifact": "topics",
        "call": "NSF-2027",
        "generated_by": "auto-proposals",
        "generated_at": "27/07/2026 10:00",
        "version": 1,
    }
    d.update(overrides)
    return d


def _write_agent_owned_topics(call_dir: Path, *, call_name: str, complete: bool = True) -> None:
    content = _compose_content(
        _owned_frontmatter(call=call_name, complete=complete), "some agent-written topics\n"
    )
    (call_dir / "topics.md").write_text(content, encoding="utf-8")


class _EnvMixin(unittest.TestCase):
    """Env-var handling shared by the scan test cases: every case gets its
    own throwaway root and pins AUTO_PROPOSALS_BOOTSTRAP_STATES to a path
    inside it, so no test can ever read a real per-machine bootstrap file
    (or a file left behind by another test)."""

    def setUp(self):
        self.root = make_test_root()
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.today = date(2026, 7, 27)
        self.bootstrap_path = self.root / "_auto-proposals" / "bootstrap-states.json"
        self._set_env("AUTO_PROPOSALS_BOOTSTRAP_STATES", str(self.bootstrap_path))

    def _set_env(self, key: str, value: str | None) -> None:
        prev = os.environ.get(key)

        def restore():
            if prev is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = prev

        self.addCleanup(restore)
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value

    def _mkcall(self, name: str) -> Path:
        p = self.root / name
        p.mkdir(parents=True, exist_ok=True)
        return p

    def _write_bootstrap(self, payload) -> None:
        """Write the bootstrap-states file; a dict is serialised as JSON, a
        str is written verbatim (for malformed-content tests)."""
        self.bootstrap_path.parent.mkdir(parents=True, exist_ok=True)
        text = payload if isinstance(payload, str) else json.dumps(payload)
        self.bootstrap_path.write_text(text, encoding="utf-8")


class ScanTestCase(_EnvMixin):
    # -- deadline parsing ---------------------------------------------------

    def test_deadline_day_precision(self):
        self._mkcall("2026.04.21 SampleProg CALL-XX-2026-01-TOPIC-AREA-04")
        calls = find_calls(self.root)
        self.assertEqual(len(calls), 1)
        c = calls[0]
        self.assertEqual(c.deadline, date(2026, 4, 21))
        self.assertEqual(c.deadline_precision, "day")
        self.assertEqual(c.funder, "SampleProg")

    def test_deadline_month_precision_resolves_to_end_of_month(self):
        self._mkcall("2026.10 ExampleFund")
        calls = find_calls(self.root)
        c = calls[0]
        self.assertEqual(c.deadline, date(2026, 10, 31))
        self.assertEqual(c.deadline_precision, "month")
        self.assertEqual(c.funder, "ExampleFund")

    def test_deadline_month_precision_february(self):
        self._mkcall("2026.02 Some Fund")
        calls = find_calls(self.root)
        c = calls[0]
        # 2026 is not a leap year -> Feb has 28 days.
        self.assertEqual(c.deadline, date(2026, 2, 28))

    def test_unparseable_date_does_not_crash(self):
        self._mkcall("No Date Here Fund")
        calls = find_calls(self.root)
        c = calls[0]
        self.assertIsNone(c.deadline)
        self.assertEqual(c.deadline_precision, "none")
        self.assertEqual(c.funder, "No")

    def test_invalid_date_components_treated_as_unparseable(self):
        self._mkcall("2026.13.40 Bad Date Fund")
        calls = find_calls(self.root)
        c = calls[0]
        self.assertIsNone(c.deadline)
        self.assertEqual(c.deadline_precision, "none")

    def test_days_until_negative_when_past(self):
        self._mkcall("2020.01.01 Old Fund")
        calls = find_calls(self.root)
        c = calls[0]
        self.assertLess(days_until(c, self.today), 0)

    def test_days_until_none_when_unparseable(self):
        self._mkcall("No Date Fund")
        calls = find_calls(self.root)
        c = calls[0]
        self.assertIsNone(days_until(c, self.today))

    def test_names_with_spaces_parens_and_hebrew(self):
        self._mkcall("2027.10.15 Smart Widgets (Coordinator Name)")
        self._mkcall("2026.09 מענק מיוחד")
        calls = find_calls(self.root)
        names = {c.name for c in calls}
        self.assertIn("2027.10.15 Smart Widgets (Coordinator Name)", names)
        self.assertIn("2026.09 מענק מיוחד", names)

    # -- exclusions -----------------------------------------------------

    def test_underscore_and_dot_prefixed_dirs_excluded(self):
        self._mkcall("2026.10 ExampleFund")
        (self.root / "_Granted").mkdir()
        (self.root / "_resources").mkdir()
        (self.root / "_auto-proposals").mkdir()
        (self.root / ".obsidian").mkdir()
        calls = find_calls(self.root)
        names = {c.name for c in calls}
        self.assertEqual(names, {"2026.10 ExampleFund"})

    def test_material_excludes_topics_dotfiles_and_conflicted_copies(self):
        call_dir = self._mkcall("2026.10 ExampleFund")
        (call_dir / "call.pdf").write_text("material")
        (call_dir / "topics.md").write_text("not agent owned")
        (call_dir / ".DS_Store").write_text("junk")
        (call_dir / "call (Alon's conflicted copy 2026-07-27).pdf").write_text("dup")
        calls = find_calls(self.root)
        c = calls[0]
        material_names = {p.name for p in c.material}
        self.assertEqual(material_names, {"call.pdf"})

    # -- has_topics -------------------------------------------------------

    def test_has_topics_false_for_human_written_topics_without_frontmatter(self):
        call_dir = self._mkcall("2026.10 ExampleFund")
        (call_dir / "topics.md").write_text("# my own notes\nno frontmatter here\n")
        calls = find_calls(self.root)
        self.assertFalse(calls[0].has_topics)

    def test_has_topics_false_when_missing_completion_sentinel(self):
        call_dir = self._mkcall("2026.10 ExampleFund")
        _write_agent_owned_topics(call_dir, call_name="2026.10 ExampleFund", complete=True)
        # Truncate the file so the trailing completion marker is gone -
        # simulates a write interrupted after the frontmatter/body but
        # before the sentinel landed.
        text = (call_dir / "topics.md").read_text()
        truncated = text.split("<!-- auto-proposals:end -->")[0]
        (call_dir / "topics.md").write_text(truncated)
        calls = find_calls(self.root)
        self.assertFalse(calls[0].has_topics)

    def test_has_topics_true_for_complete_agent_owned_file(self):
        call_dir = self._mkcall("2026.10 ExampleFund")
        _write_agent_owned_topics(call_dir, call_name="2026.10 ExampleFund", complete=True)
        calls = find_calls(self.root)
        self.assertTrue(calls[0].has_topics)

    def test_undecodable_topics_md_does_not_abort_scan(self):
        good_dir = self._mkcall("2026.10 GoodFund")
        _write_agent_owned_topics(good_dir, call_name="2026.10 GoodFund", complete=True)
        bad_dir = self._mkcall("2026.11 BadFund")
        (bad_dir / "topics.md").write_bytes(b"\xff\xfe\x00bad")

        calls = find_calls(self.root)

        names = {c.name for c in calls}
        self.assertEqual(names, {"2026.10 GoodFund", "2026.11 BadFund"})
        by_name = {c.name: c for c in calls}
        self.assertTrue(by_name["2026.10 GoodFund"].has_topics)
        # The undecodable file must not abort the scan - it's simply
        # reported as not agent-owned, same as any other unreadable
        # topics.md.
        self.assertFalse(by_name["2026.11 BadFund"].has_topics)

    def test_topics_versions_collected(self):
        call_dir = self._mkcall("2026.10 ExampleFund")
        (call_dir / "topics-v1.md").write_text("v1")
        (call_dir / "topics-v2.md").write_text("v2")
        calls = find_calls(self.root)
        self.assertEqual(calls[0].topics_versions, [1, 2])

    # -- frozen / workable --------------------------------------------------

    def test_frozen_populated_by_conflicted_topics_copy_and_excluded_from_workable(self):
        call_dir = self._mkcall("2026.10 ExampleFund")
        conflicted = call_dir / "topics (Alon's conflicted copy 2026-07-27).md"
        conflicted.write_text("ambiguous")
        calls = find_calls(self.root)
        c = calls[0]
        self.assertEqual([p.name for p in c.frozen], [conflicted.name])

        resolve_states(calls, None)
        # No bootstrap-states file exists -> defaults to "new", which would
        # normally be workable, except it's frozen.
        self.assertNotIn(c, workable(calls))

    def test_has_topics_true_excludes_from_workable(self):
        call_dir = self._mkcall("2026.10 ExampleFund")
        _write_agent_owned_topics(call_dir, call_name="2026.10 ExampleFund", complete=True)
        calls = find_calls(self.root)
        resolve_states(calls, None)
        self.assertNotIn(calls[0], workable(calls))

    def test_workable_excludes_submitted_ignore_blocked_states(self):
        for name, state in (
            ("2026.01 Submitted Fund", "submitted"),
            ("2026.02 Ignored Fund", "ignore"),
            ("2026.03 Blocked Fund", "blocked"),
            ("2026.04 Open Fund", "open"),
        ):
            self._mkcall(name)
        calls = find_calls(self.root)
        existing = "\n".join(
            f"| {c.name} | ? | ? | {s} | no |  |"
            for c, s in zip(
                calls, ("submitted", "ignore", "blocked", "open")
            )
        )
        resolve_states(calls, existing)
        workable_names = {c.name for c in workable(calls)}
        self.assertEqual(workable_names, {"2026.04 Open Fund"})

    # -- state model ----------------------------------------------------

    def test_bootstrap_states_used_only_when_open_md_absent(self):
        seeded = {
            "2026.10 ExampleFund": "open",
            "2026.07.15 DemoLab": "submitted",
            "2026.11.15 GenericTrust": "blocked",
            "2026.11.11 Placeholder Foundation": "ignore",
        }
        self._write_bootstrap(seeded)
        for name in seeded:
            self._mkcall(name)
        calls = find_calls(self.root)
        resolve_states(calls, None)
        by_name = {c.name: c.state for c in calls}
        for name, state in seeded.items():
            self.assertEqual(by_name[name], state)

    def test_bootstrap_states_never_override_existing_open_md(self):
        name = "2026.10 ExampleFund"
        self._write_bootstrap({name: "open"})
        self._mkcall(name)
        calls = find_calls(self.root)
        # The bootstrap file says "open"; existing OPEN.md says the human
        # moved it to "submitted" - that must win.
        existing = f"| {name} | 2026-10-31 | 10 | submitted | no |  |\n"
        resolve_states(calls, existing)
        self.assertEqual(calls[0].state, "submitted")

    def test_calls_without_bootstrap_or_open_md_row_default_to_new(self):
        self._mkcall("2099.01 Brand New Fund")
        calls = find_calls(self.root)
        resolve_states(calls, None)
        self.assertEqual(calls[0].state, "new")

    def test_calls_without_bootstrap_or_open_md_row_default_to_new_even_with_other_rows(self):
        self._mkcall("2099.01 Brand New Fund")
        self._mkcall("2026.10 ExampleFund")
        calls = find_calls(self.root)
        existing = "| 2026.10 ExampleFund | 2026-10-31 | 10 | submitted | no |  |\n"
        resolve_states(calls, existing)
        by_name = {c.name: c.state for c in calls}
        self.assertEqual(by_name["2099.01 Brand New Fund"], "new")
        self.assertEqual(by_name["2026.10 ExampleFund"], "submitted")

    def test_resolve_states_raises_on_corrupt_bootstrap_file(self):
        # A corrupt file must be loud all the way up through resolve_states:
        # silently treating it as "no states" would silently change which
        # calls get worked on.
        self._write_bootstrap("{not valid json")
        self._mkcall("2026.10 ExampleFund")
        calls = find_calls(self.root)
        with self.assertRaises(PathRefused):
            resolve_states(calls, None)

    # -- read_states / render_open_md round trip -----------------------

    def test_read_states_round_trips_through_render_open_md(self):
        names_states = [
            ("2026.10 ExampleFund", "open"),
            ("2026.11.11 Placeholder Foundation", "ignore"),
            ("2027.10.15 Smart Widgets (Coordinator Name)", "submitted"),
            ("No Date Fund", "blocked"),
        ]
        for name, _ in names_states:
            self._mkcall(name)
        calls = find_calls(self.root)
        by_name_state = dict(names_states)
        for c in calls:
            c.state = by_name_state[c.name]

        rendered = render_open_md(calls, today=self.today)
        round_tripped = read_states(rendered)
        for name, state in names_states:
            self.assertEqual(round_tripped[name], state)

    def test_read_states_tolerates_hand_mangled_open_md(self):
        text = (
            "# Notes\n"
            "Some prose the human added by hand up here.\n\n"
            "| call | deadline | days | state | topics | note |\n"
            "|---|---|---|---|---|---|\n"
            "| 2026.11.11 Placeholder Foundation | 2026-11-11 | 100 | ignore | no |  |\n"
            "More random prose in the middle of the file.\n"
            "| 2026.10 ExampleFund | 2026-10-31 | 60 | mystery-state | no |  |\n"
            "| 2026.08.10 GenericAgency POC | 2026-08-10 | 10 | open | no |  |\n"
            "\n"
            "Trailing human commentary.\n"
        )
        states = read_states(text)
        self.assertEqual(
            states,
            {
                "2026.11.11 Placeholder Foundation": "ignore",
                "2026.10 ExampleFund": "mystery-state",
                "2026.08.10 GenericAgency POC": "open",
            },
        )

    def test_render_open_md_lists_frozen_and_undated_sections(self):
        frozen_dir = self._mkcall("2026.10 ExampleFund")
        conflicted = frozen_dir / "topics (Alon's conflicted copy 2026-07-27).md"
        conflicted.write_text("dup")
        self._mkcall("No Date Fund")

        calls = find_calls(self.root)
        resolve_states(calls, None)
        rendered = render_open_md(calls, today=self.today)

        self.assertIn("## Frozen calls", rendered)
        self.assertIn("2026.10 ExampleFund", rendered)
        self.assertIn(conflicted.name, rendered)
        self.assertIn("## Calls with no parseable date", rendered)
        self.assertIn("No Date Fund", rendered)

    def test_render_open_md_body_has_no_frontmatter(self):
        self._mkcall("2026.10 ExampleFund")
        calls = find_calls(self.root)
        resolve_states(calls, None)
        rendered = render_open_md(calls, today=self.today)
        self.assertFalse(rendered.startswith("---"))


class BootstrapStatesFileTestCase(_EnvMixin):
    """load_bootstrap_states() / bootstrap_states_path() contract."""

    def test_env_override_wins(self):
        self.assertEqual(bootstrap_states_path(), self.bootstrap_path)

    def test_default_location_under_root_when_env_var_unset(self):
        self._set_env("AUTO_PROPOSALS_BOOTSTRAP_STATES", None)
        self._set_env("AUTO_PROPOSALS_ROOT", str(self.root))
        self.assertEqual(
            bootstrap_states_path(),
            self.root / "_auto-proposals" / "bootstrap-states.json",
        )

    def test_missing_file_returns_empty_mapping(self):
        # The normal case on a machine without the (private, unsynced-here)
        # file: no seed states, no error - OPEN.md stays authoritative.
        self.assertFalse(self.bootstrap_path.exists())
        self.assertEqual(load_bootstrap_states(), {})

    def test_valid_file_is_loaded(self):
        seeded = {"2026.10 ExampleFund": "open", "2026.06.30 SampleFund 3": "submitted"}
        self._write_bootstrap(seeded)
        self.assertEqual(load_bootstrap_states(), seeded)

    def test_malformed_json_raises_and_names_the_file(self):
        self._write_bootstrap("{not valid json")
        with self.assertRaises(PathRefused) as ctx:
            load_bootstrap_states()
        self.assertIn(str(self.bootstrap_path), str(ctx.exception))

    def test_non_object_json_raises_and_names_the_file(self):
        self._write_bootstrap('["2026.10 ExampleFund"]')
        with self.assertRaises(PathRefused) as ctx:
            load_bootstrap_states()
        self.assertIn(str(self.bootstrap_path), str(ctx.exception))

    def test_invalid_state_value_raises_and_names_the_file(self):
        self._write_bootstrap({"2026.10 ExampleFund": "banana"})
        with self.assertRaises(PathRefused) as ctx:
            load_bootstrap_states()
        self.assertIn(str(self.bootstrap_path), str(ctx.exception))
        self.assertIn("banana", str(ctx.exception))

    def test_non_string_state_value_raises(self):
        self._write_bootstrap('{"2026.10 ExampleFund": 1}')
        with self.assertRaises(PathRefused):
            load_bootstrap_states()

    def test_every_valid_state_is_accepted(self):
        seeded = {
            f"2026.0{i} Fund {i}": state
            for i, state in enumerate(
                ("new", "open", "submitted", "ignore", "blocked"), start=1
            )
        }
        self._write_bootstrap(seeded)
        self.assertEqual(load_bootstrap_states(), seeded)

    def test_invalid_utf8_raises_and_names_the_file(self):
        # A bootstrap-states file that isn't valid UTF-8 must be a loud
        # refusal naming the path, not a bare UnicodeDecodeError and not a
        # silent degrade to "no states".
        self.bootstrap_path.parent.mkdir(parents=True, exist_ok=True)
        self.bootstrap_path.write_bytes(b"\xff\xfe\x00bad")

        try:
            with self.assertRaises(PathRefused) as ctx:
                load_bootstrap_states()
        except UnicodeDecodeError:
            self.fail(
                "load_bootstrap_states() leaked a UnicodeDecodeError instead of "
                "raising PathRefused"
            )

        self.assertIn(str(self.bootstrap_path), str(ctx.exception))

    def test_no_caching_between_calls(self):
        # Deliberately uncached: a re-read must see the file's current
        # content, so no state can bleed between test cases (or between a
        # human's edit and the next run).
        self._write_bootstrap({"2026.10 ExampleFund": "open"})
        self.assertEqual(load_bootstrap_states(), {"2026.10 ExampleFund": "open"})
        self._write_bootstrap({"2026.10 ExampleFund": "blocked"})
        self.assertEqual(load_bootstrap_states(), {"2026.10 ExampleFund": "blocked"})


class SkipReasonsTestCase(_EnvMixin):
    """skip_reasons() and workable() must never disagree - the roster's
    stated reason for skipping a call has to be the reason the filter
    actually applied."""

    def test_workable_call_has_no_reasons(self):
        self._mkcall("2026.10 Fresh")
        calls = find_calls(self.root)
        resolve_states(calls, None)
        self.assertEqual(skip_reasons(calls[0]), [])
        self.assertEqual([c.name for c in workable(calls)], ["2026.10 Fresh"])

    def test_every_skipped_call_carries_at_least_one_reason(self):
        """The property that makes the 'what I did not do' report honest: a
        call is skipped if and only if it has a reason to show for it."""
        self._mkcall("2026.10 Fresh")
        done = self._mkcall("2026.11 Done")
        _write_agent_owned_topics(done, call_name="2026.11 Done")
        self._mkcall("2026.12 Submitted")
        frozen = self._mkcall("2026.09 Frozen")
        _write_agent_owned_topics(frozen, call_name="2026.09 Frozen")
        (frozen / "topics (Alon's conflicted copy 2026-07-01).md").write_text("x", encoding="utf-8")

        calls = find_calls(self.root)
        resolve_states(calls, None)
        for c in calls:
            if c.name == "2026.12 Submitted":
                c.state = "submitted"

        work_names = {c.name for c in workable(calls)}
        for c in calls:
            reasons = skip_reasons(c)
            if c.name in work_names:
                self.assertEqual(reasons, [], f"{c.name} was worked but claims a skip reason")
            else:
                self.assertTrue(reasons, f"{c.name} was skipped with no reason to report")

    def test_a_call_blocked_two_ways_reports_both(self):
        """Reporting only the first reason would let a human 'fix' the state
        column and expect the call to be picked up, when a conflicted copy is
        still freezing it."""
        d = self._mkcall("2026.09 Frozen")
        (d / "topics (Alon's conflicted copy 2026-07-01).md").write_text("x", encoding="utf-8")
        calls = find_calls(self.root)
        resolve_states(calls, None)
        calls[0].state = "submitted"
        reasons = skip_reasons(calls[0])
        self.assertEqual(len(reasons), 2)
        self.assertIn("frozen", reasons[0])
        self.assertIn("submitted", reasons[1])


class ScanCliTestCase(_EnvMixin):
    """The CLI is what SKILL.md step 1 actually invokes. These cases run it
    as a real subprocess rather than calling _main() directly: the defect
    being guarded against was a module with no `__main__` block at all, which
    an in-process call would not have caught - `python3 -m lib.scan` exited 0
    printing nothing, and a run that trusted it would have read "no calls" as
    "nothing open"."""

    SKILL_DIR = Path(__file__).resolve().parent.parent

    def _run(self, *args, root: Path | None = None, expect_ok: bool = True):
        env = dict(os.environ)
        env["AUTO_PROPOSALS_ROOT"] = str(root if root is not None else self.root)
        env["AUTO_PROPOSALS_BOOTSTRAP_STATES"] = str(self.bootstrap_path)
        proc = subprocess.run(
            [sys.executable, "-m", "lib.scan", *args],
            cwd=self.SKILL_DIR,
            env=env,
            capture_output=True,
            text=True,
        )
        if expect_ok:
            self.assertEqual(
                proc.returncode, 0, f"exit {proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            )
        return proc

    def _snapshot(self, root: Path) -> dict[str, bytes]:
        out = {}
        for p in sorted(root.rglob("*")):
            if p.is_file():
                out[str(p.relative_to(root))] = p.read_bytes()
        return out

    # -- the regression this CLI exists to close ----------------------------

    def test_bare_invocation_prints_the_calls_it_found(self):
        self._mkcall("2026.10 Kamin")
        self._mkcall("2026.08.10 VATAT POC")
        proc = self._run("--today", "2026-07-27")
        self.assertIn("2026.10 Kamin", proc.stdout)
        self.assertIn("2026.08.10 VATAT POC", proc.stdout)
        self.assertIn("2 total", proc.stdout)

    def test_an_empty_archive_says_so_instead_of_printing_nothing(self):
        """Silence is the failure mode: an empty stdout reads as 'nothing
        open' when it may mean 'the root is wrong'."""
        proc = self._run("--today", "2026-07-27")
        self.assertTrue(proc.stdout.strip(), "an empty archive must still produce output")
        self.assertIn("No call folders found", proc.stdout)

    def test_nearest_deadline_sorts_first_and_undated_calls_sort_last(self):
        self._mkcall("2026.12 Later")
        self._mkcall("Some Undated Folder")
        self._mkcall("2026.08 Sooner")
        proc = self._run("--today", "2026-07-27")
        body = proc.stdout
        self.assertLess(body.index("2026.08 Sooner"), body.index("2026.12 Later"))
        self.assertLess(body.index("2026.12 Later"), body.index("Some Undated Folder"))

    # -- what it does NOT do ------------------------------------------------

    def test_the_cli_writes_nothing_to_the_archive(self):
        """The scanner is read-only by contract (SAFETY.md #3). Anything it
        creates in the archive is a breach, including a stray temp file."""
        d = self._mkcall("2026.10 Kamin")
        (d / "call.txt").write_text("call text", encoding="utf-8")
        before = self._snapshot(self.root)
        self._run("--today", "2026-07-27")
        self._run("--today", "2026-07-27", "--json")
        self._run("--today", "2026-07-27", "--open-md")
        self.assertEqual(self._snapshot(self.root), before)

    def test_skipped_calls_and_their_reasons_are_reported(self):
        done = self._mkcall("2026.11 Done")
        _write_agent_owned_topics(done, call_name="2026.11 Done")
        proc = self._run("--today", "2026-07-27")
        self.assertIn("Not worked, and why", proc.stdout)
        self.assertIn("topics.md already published", proc.stdout)

    def test_states_are_read_back_out_of_an_existing_open_md(self):
        """resolve_states() is what keeps the human-owned state column
        authoritative. If the CLI skipped that read, a call Alon marked
        `ignore` would be worked on anyway."""
        self._mkcall("2026.10 Kamin")
        (self.root / "OPEN.md").write_text(
            _compose_content(
                {
                    "artifact": "open",
                    "generated_by": "auto-proposals",
                    "generated_at": "27/07/2026 10:00",
                    "version": 1,
                },
                "| call | deadline | days | state | topics | note |\n"
                "|---|---|---|---|---|---|\n"
                "| 2026.10 Kamin | 2026-10-31 | 96 | ignore | no |  |\n",
            ),
            encoding="utf-8",
        )
        proc = self._run("--today", "2026-07-27")
        self.assertIn("0 workable", proc.stdout)
        self.assertIn("state is 'ignore'", proc.stdout)

    # -- machine-readable modes ---------------------------------------------

    def test_json_mode_carries_the_skip_reasons(self):
        self._mkcall("2026.10 Fresh")
        done = self._mkcall("2026.11 Done")
        _write_agent_owned_topics(done, call_name="2026.11 Done")
        payload = json.loads(self._run("--today", "2026-07-27", "--json").stdout)
        by_name = {c["name"]: c for c in payload["calls"]}
        self.assertTrue(by_name["2026.10 Fresh"]["workable"])
        self.assertEqual(by_name["2026.10 Fresh"]["skip_reasons"], [])
        self.assertFalse(by_name["2026.11 Done"]["workable"])
        self.assertTrue(by_name["2026.11 Done"]["skip_reasons"])
        self.assertEqual(by_name["2026.10 Fresh"]["days_until"], 96)

    def test_open_md_mode_emits_exactly_the_renderer_output(self):
        self._mkcall("2026.10 Kamin")
        proc = self._run("--today", "2026-07-27", "--open-md")
        calls = find_calls(self.root)
        resolve_states(calls, None)
        self.assertEqual(proc.stdout, render_open_md(calls, today=date(2026, 7, 27)))

    def test_json_and_open_md_are_mutually_exclusive(self):
        proc = self._run("--json", "--open-md", expect_ok=False)
        self.assertEqual(proc.returncode, 2)

    # -- error paths --------------------------------------------------------

    def test_a_bad_today_is_refused_not_silently_defaulted(self):
        proc = self._run("--today", "not-a-date", expect_ok=False)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("YYYY-MM-DD", proc.stderr)

    def test_a_missing_root_is_an_error_not_an_empty_roster(self):
        """The single most dangerous confusion this CLI can produce: a wrong
        root that reports zero calls looks identical to a clean run."""
        missing = self.root / "no-such-archive"
        proc = self._run(root=missing, expect_ok=False)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("does not exist", proc.stderr)

    def test_a_corrupt_bootstrap_file_fails_loudly(self):
        self._mkcall("2026.10 Kamin")
        self._write_bootstrap("{not json")
        proc = self._run("--today", "2026-07-27", expect_ok=False)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("not valid JSON", proc.stderr)


class CallInfoDefaultsTestCase(unittest.TestCase):
    def test_default_state_is_new(self):
        c = CallInfo(
            name="x", path=Path("/tmp/x"), deadline=None, deadline_precision="none", funder=""
        )
        self.assertEqual(c.state, "new")
        self.assertEqual(c.material, [])
        self.assertEqual(c.frozen, [])


if __name__ == "__main__":
    unittest.main()
