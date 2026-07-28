import os
import shutil
import tempfile
import sys
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from test._env import make_test_root  # noqa: E402

from lib.integrity import LARGE_FILE_SKIPPED, diff, format_report, snapshot  # noqa: E402


class IntegrityTestCase(unittest.TestCase):
    def setUp(self):
        self.root = make_test_root()
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def test_diff_flags_modified_and_deleted_but_not_owned_created(self):
        keep = self.root / "keep.md"
        keep.write_text("original\n")
        gone = self.root / "gone.md"
        gone.write_text("bye\n")

        before = snapshot(self.root)

        # Ensure mtime actually advances on filesystems with coarse
        # resolution.
        time.sleep(0.01)
        keep.write_text("changed\n")
        gone.unlink()
        owned = self.root / "NSF-2027" / "topics.md"
        owned.parent.mkdir(parents=True)
        owned.write_text("owned artifact\n")

        after = snapshot(self.root)

        result = diff(before, after, owned_rels={"NSF-2027/topics.md"})

        self.assertIn("keep.md", result["modified"])
        self.assertIn("gone.md", result["deleted"])
        self.assertNotIn("NSF-2027/topics.md", result["created_unowned"])
        self.assertEqual(result["created_unowned"], [])

    def test_diff_flags_unowned_created_file(self):
        before = snapshot(self.root)
        (self.root / "surprise.md").write_text("who wrote this\n")
        after = snapshot(self.root)

        result = diff(before, after, owned_rels=set())
        self.assertIn("surprise.md", result["created_unowned"])

    def test_format_report_empty_when_clean(self):
        before = snapshot(self.root)
        after = snapshot(self.root)
        result = diff(before, after, owned_rels=set())
        self.assertEqual(format_report(result), "")

    def test_format_report_nonempty_when_dirty(self):
        result = {"modified": ["a.md"], "deleted": [], "created_unowned": []}
        report = format_report(result)
        self.assertIn("a.md", report)
        self.assertNotEqual(report, "")

    def test_snapshot_handles_spaces_and_hebrew_names(self):
        f = self.root / "call folder עברית" / "topics.md"
        f.parent.mkdir(parents=True)
        f.write_text("content\n")

        snap = snapshot(self.root)
        self.assertIn("call folder עברית/topics.md", snap)

    def test_diff_flags_modified_owned_artifact(self):
        # Only *creation* of an owned path is expected/excluded - an owned
        # artifact this run did not itself publish turning up modified is
        # exactly the clobber class L3 exists to catch, even though the
        # path is one the agent is allowed to own.
        owned = self.root / "NSF-2027" / "topics.md"
        owned.parent.mkdir(parents=True)
        owned.write_text("original\n")

        before = snapshot(self.root)
        time.sleep(0.01)
        owned.write_text("clobbered\n")
        after = snapshot(self.root)

        result = diff(before, after, owned_rels={"NSF-2027/topics.md"})
        self.assertIn("NSF-2027/topics.md", result["modified"])

    def test_diff_flags_deleted_owned_artifact(self):
        owned = self.root / "NSF-2027" / "topics.md"
        owned.parent.mkdir(parents=True)
        owned.write_text("original\n")

        before = snapshot(self.root)
        owned.unlink()
        after = snapshot(self.root)

        result = diff(before, after, owned_rels={"NSF-2027/topics.md"})
        self.assertIn("NSF-2027/topics.md", result["deleted"])

    def test_snapshot_detects_content_change_with_same_size_and_mtime(self):
        # (size, mtime_ns) alone can't see this: same length, and mtime is
        # forced back to the exact original value with os.utime, imitating
        # either a very coarse filesystem clock or a deliberate attempt to
        # hide an edit. The content hash must still catch it.
        f = self.root / "topics.md"
        f.write_text("aaaa\n")
        before = snapshot(self.root)
        st = f.stat()

        f.write_text("bbbb\n")
        os.utime(f, ns=(st.st_atime_ns, st.st_mtime_ns))
        after = snapshot(self.root)

        self.assertEqual(before["topics.md"][0], after["topics.md"][0])  # same size
        self.assertEqual(before["topics.md"][1], after["topics.md"][1])  # same mtime_ns
        self.assertNotEqual(before["topics.md"][3], after["topics.md"][3])  # different hash

        result = diff(before, after, owned_rels=set())
        self.assertIn("topics.md", result["modified"])

    def test_snapshot_records_inode(self):
        f = self.root / "topics.md"
        f.write_text("content\n")
        snap = snapshot(self.root)
        self.assertEqual(snap["topics.md"][2], f.stat().st_ino)

    def test_snapshot_skips_hashing_files_over_cap_and_diff_reports_it(self):
        f = self.root / "big.md"
        f.write_text("x" * 100)

        with patch.dict(os.environ, {"AUTO_PROPOSALS_HASH_MAX_BYTES": "10"}):
            snap = snapshot(self.root)

        self.assertEqual(snap["big.md"][3], LARGE_FILE_SKIPPED)

        result = diff(snap, snap, owned_rels=set())
        self.assertEqual(result["skipped_large"], 1)
        # skipped_large alone is not an alarm - a clean diff stays clean.
        self.assertEqual(format_report(result), "")

    def test_format_report_notes_skipped_large_only_alongside_a_real_alarm(self):
        result = {
            "modified": ["a.md"],
            "deleted": [],
            "created_unowned": [],
            "skipped_large": 2,
        }
        report = format_report(result)
        self.assertIn("a.md", report)
        self.assertIn("2", report)


if __name__ == "__main__":
    unittest.main()


from lib import integrity  # noqa: E402


class DiffExpectedModifiedTestCase(unittest.TestCase):
    """A regenerate of an existing OPEN.md/CORPUS.md legitimately modifies a
    file. The caller declares that one path up front; everything else that
    moved must still alarm."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="auto-proposals-test-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        (self.root / "OPEN.md").write_text("v1\n", encoding="utf-8")
        (self.root / "untouchable.pdf").write_text("original\n", encoding="utf-8")

    def test_declared_modification_is_not_an_alarm(self):
        before = integrity.snapshot(self.root)
        (self.root / "OPEN.md").write_text("v2 regenerated\n", encoding="utf-8")
        after = integrity.snapshot(self.root)
        d = integrity.diff(before, after, owned_rels={"OPEN.md"},
                           expected_modified={"OPEN.md"})
        self.assertEqual(d["modified"], [])
        self.assertEqual(integrity.format_report(d).strip(), "")

    def test_undeclared_modification_still_alarms(self):
        before = integrity.snapshot(self.root)
        (self.root / "OPEN.md").write_text("v2 regenerated\n", encoding="utf-8")
        (self.root / "untouchable.pdf").write_text("CLOBBERED\n", encoding="utf-8")
        after = integrity.snapshot(self.root)
        d = integrity.diff(before, after, owned_rels={"OPEN.md"},
                           expected_modified={"OPEN.md"})
        self.assertEqual(d["modified"], ["untouchable.pdf"])
        self.assertIn("untouchable.pdf", integrity.format_report(d))

    def test_omitting_expected_modified_keeps_the_old_strict_behaviour(self):
        before = integrity.snapshot(self.root)
        (self.root / "OPEN.md").write_text("v2\n", encoding="utf-8")
        after = integrity.snapshot(self.root)
        d = integrity.diff(before, after, owned_rels={"OPEN.md"})
        self.assertEqual(d["modified"], ["OPEN.md"])
