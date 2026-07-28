"""Tests for lib.corpus.

Self-contained: builds all fixtures under tempfile.mkdtemp() via test._env's
throwaway-root discipline, never reads from the real ~/Dropbox archive, and
makes no network calls.
"""

import os
import shutil
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from lib import corpus, extract
from test import _env

# --- Safety guard: refuse to run anywhere near the real Dropbox archive. ---
_REAL_DROPBOX = os.path.realpath(os.path.expanduser("~/Dropbox"))
_TEST_TMP_ROOT = os.path.realpath(tempfile.gettempdir())
assert not _TEST_TMP_ROOT.startswith(_REAL_DROPBOX), (
    f"Refusing to run: temp root {_TEST_TMP_ROOT!r} resolves under the real "
    f"Dropbox archive {_REAL_DROPBOX!r}. Tests must never touch ~/Dropbox."
)


def _has_docx() -> bool:
    try:
        import docx  # noqa: F401
        return True
    except ImportError:
        return False


def _touch(path: Path, content: bytes = b"content", *, mtime: float | None = None) -> Path:
    path.write_bytes(content)
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


class PickSourceDatedPdfTest(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="auto-proposals-test-")
        self.addCleanup(shutil.rmtree, self.tmpdir, ignore_errors=True)
        self.folder = Path(self.tmpdir) / "SomeFunder 2021"
        self.folder.mkdir()

    def test_two_dated_pdfs_newer_wins(self):
        older = _touch(self.folder / "proposal_15.03.2020.pdf")
        newer = _touch(self.folder / "proposal_02.11.2021.pdf")

        source, reason = corpus.pick_source(self.folder)

        self.assertEqual(source, newer)
        self.assertIn("2021-11-02", reason)
        self.assertIn("date-named", reason.lower())

    def test_dated_pdf_preferred_over_undated_pdf_and_docx(self):
        _touch(self.folder / "draft.pdf", mtime=time.time())
        dated = _touch(self.folder / "submitted_2021.03.15.pdf")
        _touch(self.folder / "cover_letter_2022-01-01.docx")

        source, reason = corpus.pick_source(self.folder)
        self.assertEqual(source, dated)
        self.assertIn("2021-03-15", reason)

    def test_all_four_date_formats_parse(self):
        cases = {
            "a_15.03.2021.pdf": "2021-03-15",
            "b_2021.03.16.pdf": "2021-03-16",
            "c_15-03-2021.pdf": "2021-03-15",
            "d_2021-03-17.pdf": "2021-03-17",
        }
        for name, expected_iso in cases.items():
            with self.subTest(name=name):
                d = corpus.parse_date_from_filename(name)
                self.assertIsNotNone(d, name)
                self.assertEqual(d.isoformat(), expected_iso)


class PickSourceRungsTest(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="auto-proposals-test-")
        self.addCleanup(shutil.rmtree, self.tmpdir, ignore_errors=True)
        self.folder = Path(self.tmpdir) / "OldCall"
        self.folder.mkdir()

    def test_rung2_undated_pdfs_pick_most_recent_mtime(self):
        now = time.time()
        older = _touch(self.folder / "v1.pdf", mtime=now - 1000)
        newer = _touch(self.folder / "v2_final.pdf", mtime=now)

        source, reason = corpus.pick_source(self.folder)
        self.assertEqual(source, newer)
        self.assertIn("most recently modified", reason.lower())
        self.assertIn("PDF", reason)

    def test_rung3_dated_docx_picked_when_no_pdf(self):
        older = _touch(self.folder / "draft_01.01.2019.docx")
        newer = _touch(self.folder / "final_20.06.2020.docx")

        source, reason = corpus.pick_source(self.folder)
        self.assertEqual(source, newer)
        self.assertIn("2020-06-20", reason)
        self.assertIn("DOCX", reason)

    def test_rung4_undated_docx_by_mtime_when_no_pdf_and_no_dated_docx(self):
        now = time.time()
        older = _touch(self.folder / "notes.docx", mtime=now - 1000)
        newer = _touch(self.folder / "final_notes.docx", mtime=now)

        source, reason = corpus.pick_source(self.folder)
        self.assertEqual(source, newer)
        self.assertIn("most recently modified", reason.lower())
        self.assertIn("DOCX", reason)

    def test_no_usable_file_returns_none_with_reason(self):
        _touch(self.folder / "budget.xlsx")
        _touch(self.folder / "notes.txt")

        source, reason = corpus.pick_source(self.folder)
        self.assertIsNone(source)
        self.assertTrue(reason)
        self.assertIn("no usable", reason.lower())

    def test_empty_folder_returns_none_with_reason(self):
        source, reason = corpus.pick_source(self.folder)
        self.assertIsNone(source)
        self.assertTrue(reason)


class PickSourceSkipRulesTest(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="auto-proposals-test-")
        self.addCleanup(shutil.rmtree, self.tmpdir, ignore_errors=True)
        self.folder = Path(self.tmpdir) / "SkipCall"
        self.folder.mkdir()

    def test_conflicted_copy_pdf_skipped_in_favour_of_plain_one(self):
        plain = _touch(self.folder / "proposal_10.05.2021.pdf")
        _touch(self.folder / "proposal_10.05.2021 (Alon's conflicted copy 2021-05-11).pdf")

        source, reason = corpus.pick_source(self.folder)
        self.assertEqual(source, plain)

    def test_dotfile_pdf_skipped(self):
        _touch(self.folder / ".hidden_15.03.2021.pdf")
        source, reason = corpus.pick_source(self.folder)
        self.assertIsNone(source)

    def test_office_lockfile_skipped(self):
        _touch(self.folder / "~$proposal_15.03.2021.docx")
        source, reason = corpus.pick_source(self.folder)
        self.assertIsNone(source)

    def test_symlink_never_followed_or_picked(self):
        outside_dir = tempfile.mkdtemp(prefix="auto-proposals-test-outside-")
        self.addCleanup(shutil.rmtree, outside_dir, ignore_errors=True)
        real_target = _touch(Path(outside_dir) / "secret_20.01.2022.pdf")

        link = self.folder / "linked_20.01.2022.pdf"
        link.symlink_to(real_target)

        source, reason = corpus.pick_source(self.folder)
        self.assertIsNone(source)

    def test_depth_capped_at_one_level_two_levels_down_not_selected(self):
        sub = self.folder / "Sub"
        sub.mkdir()
        deeper = sub / "Deeper"
        deeper.mkdir()
        _touch(deeper / "buried_20.01.2022.pdf")

        source, reason = corpus.pick_source(self.folder)
        self.assertIsNone(source)
        self.assertIn("no usable", reason.lower())


class PickSourceDepth2FallbackTest(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="auto-proposals-test-")
        self.addCleanup(shutil.rmtree, self.tmpdir, ignore_errors=True)
        self.folder = Path(self.tmpdir) / "2023.12 ERC"
        self.folder.mkdir()

    def test_no_top_level_candidate_falls_back_to_subdirectory(self):
        sub = self.folder / "Part B1"
        sub.mkdir()
        picked = _touch(sub / "2023.05.24 a Part B1.docx")
        # A non-candidate top-level file so the folder isn't simply empty.
        _touch(self.folder / "notes.txt")

        source, reason = corpus.pick_source(self.folder)

        self.assertEqual(source, picked)
        self.assertIn("no top-level candidate", reason)
        self.assertIn("Part B1", reason)

    def test_symlinked_subdirectory_never_descended_into(self):
        outside_dir = tempfile.mkdtemp(prefix="auto-proposals-test-outside-")
        self.addCleanup(shutil.rmtree, outside_dir, ignore_errors=True)
        real_sub = Path(outside_dir) / "RealSub"
        real_sub.mkdir()
        _touch(real_sub / "2023.05.24 a Part B1.docx")

        link = self.folder / "Sub"
        try:
            link.symlink_to(real_sub, target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest("symlinks not supported in this environment")

        source, reason = corpus.pick_source(self.folder)
        self.assertIsNone(source)
        self.assertIn("no usable", reason.lower())

    def test_only_stray_text_file_stays_unindexed_with_honest_reason(self):
        _touch(self.folder / "link.txt")

        source, reason = corpus.pick_source(self.folder)

        self.assertIsNone(source)
        self.assertTrue(reason)
        self.assertIn("no usable", reason.lower())
        self.assertIn(self.folder.name, reason)


class RenderInventoryMdTest(unittest.TestCase):
    def test_unindexed_folder_named_with_reason(self):
        entries = [
            corpus.CorpusEntry(
                corpus="_Granted", folder="GoodCall", source=Path("/x/a.pdf"),
                reason="latest date-named PDF", indexed=True, chars=123,
                cache_path=Path("/cache/a.txt"),
            ),
            corpus.CorpusEntry(
                corpus="_Archive", folder="EmptyCall", source=None,
                reason="no usable top-level .pdf or .docx file found in folder 'EmptyCall'",
                indexed=False, chars=0, cache_path=None,
            ),
        ]
        md = corpus.render_inventory_md(entries)

        self.assertIn("GoodCall", md)
        self.assertIn("## Unindexed", md)
        self.assertIn("EmptyCall", md)
        self.assertIn("no usable top-level .pdf or .docx file found", md)
        # Nothing silently dropped: both folders appear somewhere in the output.
        unindexed_section = md.split("## Unindexed", 1)[1]
        self.assertIn("EmptyCall", unindexed_section)


class BuildInventoryTest(unittest.TestCase):
    def setUp(self):
        self.root = _env.make_test_root()
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        _env.configure_env(self.root)
        self.cache_dir = Path(tempfile.mkdtemp(prefix="auto-proposals-test-cache-"))
        self.addCleanup(shutil.rmtree, self.cache_dir, ignore_errors=True)

        (self.root / "_Granted").mkdir()
        (self.root / "_Archive").mkdir()

    @unittest.skipUnless(_has_docx(), "python-docx not installed")
    def test_survives_one_folder_extraction_failure(self):
        import docx

        good_folder = self.root / "_Granted" / "GoodCall"
        good_folder.mkdir()
        document = docx.Document()
        document.add_paragraph("GOODCALL MARKER TEXT")
        document.save(str(good_folder / "proposal_01.01.2021.docx"))

        bad_folder = self.root / "_Granted" / "BadCall"
        bad_folder.mkdir()
        bad_source = _touch(bad_folder / "proposal_02.02.2021.docx", content=b"not a real docx")

        real_extract_cached = extract.extract_cached

        def flaky_extract_cached(path, cache_dir, **kwargs):
            if Path(path) == bad_source:
                raise RuntimeError("simulated extraction blow-up")
            return real_extract_cached(path, cache_dir, **kwargs)

        with mock.patch("lib.corpus.extract.extract_cached", side_effect=flaky_extract_cached):
            entries = corpus.build_inventory(self.root, cache_dir=self.cache_dir, corpora=("_Granted",))

        by_folder = {e.folder: e for e in entries}
        self.assertEqual(set(by_folder), {"GoodCall", "BadCall"})

        self.assertTrue(by_folder["GoodCall"].indexed)
        self.assertGreater(by_folder["GoodCall"].chars, 0)

        self.assertFalse(by_folder["BadCall"].indexed)
        self.assertIn("simulated extraction blow-up", by_folder["BadCall"].reason)

    def test_cache_dir_inside_archive_root_is_refused_and_nothing_written(self):
        folder = self.root / "_Granted" / "SomeCall"
        folder.mkdir()
        _touch(folder / "proposal_01.01.2021.pdf")

        bad_cache_dir = self.root / "_cache_inside_archive"

        with self.assertRaises(extract.ExtractRefused):
            corpus.build_inventory(self.root, cache_dir=bad_cache_dir, corpora=("_Granted",))

        self.assertFalse(bad_cache_dir.exists())

    @unittest.skipUnless(_has_docx(), "python-docx not installed")
    def test_progress_callback_invoked_and_folder_with_no_source_recorded(self):
        empty_folder = self.root / "_Archive" / "NothingHere"
        empty_folder.mkdir()
        _touch(empty_folder / "budget.xlsx")

        messages = []
        entries = corpus.build_inventory(
            self.root, cache_dir=self.cache_dir, corpora=("_Archive",),
            progress=messages.append,
        )

        self.assertTrue(messages, "progress callback should have been called")
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0].folder, "NothingHere")
        self.assertFalse(entries[0].indexed)


class ThinOverrideTest(unittest.TestCase):
    def setUp(self):
        self.root = _env.make_test_root()
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        _env.configure_env(self.root)
        self.cache_dir = Path(tempfile.mkdtemp(prefix="auto-proposals-test-cache-"))
        self.addCleanup(shutil.rmtree, self.cache_dir, ignore_errors=True)
        (self.root / "_Granted").mkdir()

    @staticmethod
    def _fake_extraction(path: Path, chars: int) -> extract.Extraction:
        return extract.Extraction(
            path=Path(path), text="x" * chars, tool="fake", ok=True, note="", chars=chars,
        )

    def test_thin_primary_switches_to_richer_alternative(self):
        folder = self.root / "_Granted" / "ThinCall"
        folder.mkdir()
        primary = _touch(folder / "proposal_20.01.2022.pdf")
        alt = _touch(folder / "proposal_10.01.2022.pdf")

        def fake_extract_cached(path, cache_dir, **kwargs):
            path = Path(path)
            if path == primary:
                return self._fake_extraction(path, 50)
            if path == alt:
                return self._fake_extraction(path, 5000)
            raise AssertionError(f"unexpected extraction call: {path}")

        with mock.patch("lib.corpus.extract.extract_cached", side_effect=fake_extract_cached):
            entries = corpus.build_inventory(self.root, cache_dir=self.cache_dir, corpora=("_Granted",))

        self.assertEqual(len(entries), 1)
        entry = entries[0]
        self.assertTrue(entry.indexed)
        self.assertEqual(entry.source, alt)
        self.assertEqual(entry.chars, 5000)
        self.assertFalse(entry.thin)
        self.assertIn(primary.name, entry.reason)
        self.assertIn("50", entry.reason)
        self.assertIn(alt.name, entry.reason)
        self.assertIn("5000", entry.reason)

    def test_all_candidates_thin_keeps_original_pick_and_flags_thin(self):
        folder = self.root / "_Granted" / "AllThinCall"
        folder.mkdir()
        primary = _touch(folder / "proposal_20.01.2022.pdf")
        alt = _touch(folder / "proposal_10.01.2022.pdf")

        def fake_extract_cached(path, cache_dir, **kwargs):
            path = Path(path)
            if path == primary:
                return self._fake_extraction(path, 100)
            if path == alt:
                return self._fake_extraction(path, 500)
            raise AssertionError(f"unexpected extraction call: {path}")

        with mock.patch("lib.corpus.extract.extract_cached", side_effect=fake_extract_cached):
            entries = corpus.build_inventory(self.root, cache_dir=self.cache_dir, corpora=("_Granted",))

        self.assertEqual(len(entries), 1)
        entry = entries[0]
        self.assertTrue(entry.indexed)
        self.assertEqual(entry.source, primary)
        self.assertEqual(entry.chars, 100)
        self.assertTrue(entry.thin)

        md = corpus.render_inventory_md(entries)
        thin_section = md.split("## Thin", 1)[1]
        self.assertIn("AllThinCall", thin_section)

    def test_max_alternatives_respected(self):
        folder = self.root / "_Granted" / "ManyThinCall"
        folder.mkdir()
        primary = _touch(folder / "proposal_20.01.2022.pdf")
        for i in range(1, 9):  # 8 alternatives, more than MAX_ALTERNATIVES (6)
            _touch(folder / f"proposal_{i:02d}.01.2022.pdf")

        call_count = {"alternatives": 0}

        def fake_extract_cached(path, cache_dir, **kwargs):
            path = Path(path)
            if path == primary:
                return self._fake_extraction(path, 10)
            call_count["alternatives"] += 1
            return self._fake_extraction(path, 20)

        with mock.patch("lib.corpus.extract.extract_cached", side_effect=fake_extract_cached):
            entries = corpus.build_inventory(self.root, cache_dir=self.cache_dir, corpora=("_Granted",))

        self.assertEqual(len(entries), 1)
        self.assertTrue(entries[0].thin)
        self.assertLessEqual(call_count["alternatives"], corpus.MAX_ALTERNATIVES)


@unittest.skipUnless(_has_docx(), "python-docx not installed")
class DocxWatchdogTest(unittest.TestCase):
    """Proves the in-process docx/msg extraction watchdog (the sanctioned
    lib/extract.py change) actually cuts off a hang, using a faked slow
    parser rather than a genuinely pathological file.
    """

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="auto-proposals-test-")
        self.addCleanup(shutil.rmtree, self.tmpdir, ignore_errors=True)

    def test_hanging_docx_parse_is_cut_off_at_timeout(self):
        import sys

        path = Path(self.tmpdir) / "slow.docx"
        path.write_bytes(b"not-a-real-docx-just-needs-to-exist")

        class _HangingDocument:
            def __init__(self, *a, **k):
                time.sleep(5)

        class _FakeDocxModule:
            Document = _HangingDocument

        with mock.patch.dict(sys.modules, {"docx": _FakeDocxModule}):
            t0 = time.monotonic()
            result = extract.extract(path, timeout=1)
            elapsed = time.monotonic() - t0

        self.assertFalse(result.ok)
        self.assertLess(elapsed, 4.0, "watchdog should cut the hang off well before the fake 5s sleep completes")
        self.assertIn("timed out", result.note.lower())


if __name__ == "__main__":
    unittest.main()
