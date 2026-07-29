import os
import shutil
import sys
import unittest
from datetime import date
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from test._env import configure_env, make_test_root  # noqa: E402

from lib.paths import (  # noqa: E402
    PathRefused,
    draft_pdf_rel_for,
    dropbox_synced,
    is_call_dir,
    is_conflicted_copy,
    is_draft_pdf,
    next_draft_rel,
    owned_artifact_conflicts,
    resolve_owned,
    root_artifact_conflicts,
    write_mode_for,
)


class PathsTestCase(unittest.TestCase):
    def setUp(self):
        self.root = make_test_root()
        configure_env(self.root)
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    # -- write_mode_for -----------------------------------------------

    def test_write_mode_regenerate_targets(self):
        self.assertEqual(write_mode_for("OPEN.md"), "regenerate")
        self.assertEqual(write_mode_for("CORPUS.md"), "regenerate")

    def test_write_mode_create_targets(self):
        self.assertEqual(write_mode_for("NSF-2027/topics.md"), "create")
        self.assertEqual(write_mode_for("NSF-2027/topics-v2.md"), "create")
        self.assertEqual(write_mode_for("NSF-2027/outlines/T1-slug.md"), "create")
        self.assertEqual(write_mode_for("NSF-2027/outlines/T1-slug-v2.md"), "create")
        self.assertEqual(write_mode_for("NSF-2027/drafts/2026.07.28 a T1-slug.md"), "create")

    def test_write_mode_rejects_garbage(self):
        with self.assertRaises(PathRefused):
            write_mode_for("random.md")
        with self.assertRaises(PathRefused):
            write_mode_for("NSF-2027/notes.md")

    # -- write_mode_for: new draft grammar ------------------------------

    def test_write_mode_draft_accepts_new_grammar_shapes(self):
        # Spaces and non-ascii (Hebrew) characters in <rest> are both valid.
        self.assertEqual(
            write_mode_for("NSF-2027/drafts/2026.07.28 a T5-hybrid white box neural models.md"),
            "create",
        )
        self.assertEqual(
            write_mode_for("NSF-2027/drafts/2026.07.28 a נושא הצעה.md"),
            "create",
        )

    def test_write_mode_draft_rejects_old_v_form(self):
        with self.assertRaises(PathRefused):
            write_mode_for("NSF-2027/drafts/T1-slug-v1.md")

    def test_write_mode_draft_rejects_malformed_dates(self):
        for rel in (
            "NSF-2027/drafts/2026.7.28 a slug.md",
            "NSF-2027/drafts/26.07.28 a slug.md",
            "NSF-2027/drafts/2026-07-28 a slug.md",
        ):
            with self.subTest(rel=rel):
                with self.assertRaises(PathRefused):
                    write_mode_for(rel)

    def test_write_mode_draft_rejects_bad_letter(self):
        for rel in (
            "NSF-2027/drafts/2026.07.28 aa slug.md",
            "NSF-2027/drafts/2026.07.28 A slug.md",
            "NSF-2027/drafts/2026.07.28 slug.md",
        ):
            with self.subTest(rel=rel):
                with self.assertRaises(PathRefused):
                    write_mode_for(rel)

    def test_write_mode_draft_rejects_missing_date(self):
        with self.assertRaises(PathRefused):
            write_mode_for("NSF-2027/drafts/a slug.md")

    # -- resolve_owned: grammar escapes --------------------------------

    def test_resolve_owned_refuses_dotdot_escape(self):
        with self.assertRaises(PathRefused):
            resolve_owned(self.root, "../escape")

    def test_resolve_owned_refuses_underscore_call(self):
        with self.assertRaises(PathRefused):
            resolve_owned(self.root, "_Granted/x.md")

    def test_resolve_owned_refuses_dot_call(self):
        with self.assertRaises(PathRefused):
            resolve_owned(self.root, ".hidden/x.md")

    def test_resolve_owned_refuses_unrecognised_shape(self):
        with self.assertRaises(PathRefused):
            resolve_owned(self.root, "foo/bar.md")

    def test_resolve_owned_refuses_absolute_path(self):
        with self.assertRaises(PathRefused):
            resolve_owned(self.root, "/etc/passwd")

    def test_resolve_owned_accepts_grammar_shapes(self):
        (self.root / "NSF-2027").mkdir(parents=True)

        p = resolve_owned(self.root, "OPEN.md")
        self.assertEqual(p, self.root / "OPEN.md")
        p = resolve_owned(self.root, "NSF-2027/topics.md")
        self.assertEqual(p, self.root / "NSF-2027" / "topics.md")
        p = resolve_owned(self.root, "NSF-2027/outlines/T1-slug-v2.md")
        self.assertEqual(p, self.root / "NSF-2027" / "outlines" / "T1-slug-v2.md")
        p = resolve_owned(self.root, "NSF-2027/drafts/2026.07.28 a T1-slug.md")
        self.assertEqual(p, self.root / "NSF-2027" / "drafts" / "2026.07.28 a T1-slug.md")

    # -- resolve_owned: symlink escapes ---------------------------------

    def test_resolve_owned_refuses_symlinked_component(self):
        outside = self.root.parent / "outside-target"
        outside.mkdir(exist_ok=True)
        self.addCleanup(shutil.rmtree, outside, ignore_errors=True)

        call_dir = self.root / "NSF-2027"
        call_dir.mkdir(parents=True, exist_ok=True)
        drafts_link = call_dir / "drafts"
        os.symlink(outside, drafts_link)

        with self.assertRaises(PathRefused):
            resolve_owned(self.root, "NSF-2027/drafts/2026.07.28 a T1-slug.md")

        # Nothing should have been written at the symlink destination.
        self.assertEqual(list(outside.iterdir()), [])

    def test_resolve_owned_refuses_symlinked_final_component(self):
        outside = self.root.parent / "outside-file.md"
        outside.write_text("not mine")
        self.addCleanup(outside.unlink, missing_ok=True)

        call_dir = self.root / "NSF-2027"
        call_dir.mkdir(parents=True, exist_ok=True)
        target = call_dir / "topics.md"
        os.symlink(outside, target)

        with self.assertRaises(PathRefused):
            resolve_owned(self.root, "NSF-2027/topics.md")

    # -- is_conflicted_copy -----------------------------------------------

    def test_is_conflicted_copy_table(self):
        cases = [
            ("topics (Alon's conflicted copy 2026-07-27).md", True),
            ("topics (Someone Else's conflicted copy 2026-01-02).md", True),
            ("weird CONFLICTED COPY thing.md", True),
            ("topics.md", False),
            ("notes (draft 2).md", False),
            ("weird (conflicted copy).md", True),
            ("topics (host-laptop conflicted copy 2026-01-01).md", True),
            # KNOWN GAP (SAFETY.md #5): Dropbox localises this filename on
            # non-English UI locales, and this detector only recognises the
            # English "conflicted copy" wording. A Hebrew-locale conflicted
            # copy of an owned artifact is therefore invisible to the freeze
            # check and will NOT halt the run - this case documents that gap
            # rather than a coverage guarantee.
            ("נושא (עותק מנוגד 2026-07-27).md", False),
        ]
        for name, expected in cases:
            with self.subTest(name=name):
                self.assertEqual(is_conflicted_copy(name), expected)

    # -- dropbox_synced -----------------------------------------------

    def test_dropbox_synced_fails_closed_when_binary_missing(self):
        # A cron environment can easily have a PATH that doesn't include the
        # dropbox CLI. Fail-open here would mean "we have no idea if the
        # tree is synced" is silently treated as "go ahead and publish" -
        # that's the wrong default for an unversioned archive.
        with patch("lib.paths.subprocess.run", side_effect=FileNotFoundError()):
            ok, reason = dropbox_synced()
        self.assertFalse(ok)
        self.assertIn("AUTO_PROPOSALS_ALLOW_UNSYNCED", reason)

    # -- root_artifact_conflicts ---------------------------------------

    def test_root_artifact_conflicts_finds_conflicted_copy_of_corpus(self):
        (self.root / "CORPUS.md").write_text("---\n---\n")
        conflicted = self.root / "CORPUS (Alon's conflicted copy 2026-07-27).md"
        conflicted.write_text("dup")

        conflicts = root_artifact_conflicts(self.root, "CORPUS")
        self.assertIn(conflicted, conflicts)

    def test_root_artifact_conflicts_empty_when_clean(self):
        (self.root / "OPEN.md").write_text("---\n---\n")
        self.assertEqual(root_artifact_conflicts(self.root, "OPEN"), [])

    # -- resolve_owned: call folder must exist byte-for-byte -------------

    def test_resolve_owned_refuses_call_folder_that_only_near_matches(self):
        # A trailing space is a distinct directory entry on most filesystems
        # but looks identical at a glance; it must never be treated as the
        # real call folder.
        (self.root / "NSF-2027 ").mkdir()
        with self.assertRaises(PathRefused) as ctx:
            resolve_owned(self.root, "NSF-2027/topics.md")
        self.assertIn("NSF-2027 ", str(ctx.exception))

    def test_resolve_owned_refuses_when_call_folder_missing_entirely(self):
        with self.assertRaises(PathRefused):
            resolve_owned(self.root, "NSF-2027/topics.md")

    # -- owned_artifact_conflicts -----------------------------------------

    def test_owned_artifact_conflicts_finds_topics_and_outline(self):
        call_dir = self.root / "NSF-2027"
        (call_dir / "outlines").mkdir(parents=True)
        (call_dir / "drafts").mkdir(parents=True)

        (call_dir / "topics.md").write_text("---\n---\n")
        (call_dir / "topics (Alon's conflicted copy 2026-07-27).md").write_text("dup")
        (call_dir / "outlines" / "T1-slug.md").write_text("---\n---\n")
        (call_dir / "outlines" / "T1-slug (Alon's conflicted copy 2026-07-27).md").write_text("dup")

        conflicts = owned_artifact_conflicts(call_dir)
        names = {p.name for p in conflicts}
        self.assertIn("topics (Alon's conflicted copy 2026-07-27).md", names)
        self.assertIn("T1-slug (Alon's conflicted copy 2026-07-27).md", names)
        self.assertEqual(len(conflicts), 2)

    def test_owned_artifact_conflicts_empty_when_clean(self):
        call_dir = self.root / "NSF-2027"
        (call_dir / "outlines").mkdir(parents=True)
        (call_dir / "topics.md").write_text("---\n---\n")
        self.assertEqual(owned_artifact_conflicts(call_dir), [])

    # -- is_call_dir --------------------------------------------------

    def test_is_call_dir(self):
        (self.root / "NSF-2027").mkdir(parents=True)
        (self.root / "_Granted").mkdir(parents=True)
        (self.root / ".obsidian").mkdir(parents=True)

        self.assertTrue(is_call_dir(self.root / "NSF-2027"))
        self.assertFalse(is_call_dir(self.root / "_Granted"))
        self.assertFalse(is_call_dir(self.root / ".obsidian"))

    # -- next_draft_rel -------------------------------------------------

    def test_next_draft_rel_returns_a_when_drafts_dir_absent(self):
        (self.root / "NSF-2027").mkdir(parents=True)
        rel = next_draft_rel(self.root, "NSF-2027", "T1-slug", date(2026, 7, 28))
        self.assertEqual(rel, "NSF-2027/drafts/2026.07.28 a T1-slug.md")

    def test_next_draft_rel_returns_a_when_drafts_dir_empty(self):
        call_dir = self.root / "NSF-2027"
        (call_dir / "drafts").mkdir(parents=True)
        rel = next_draft_rel(self.root, "NSF-2027", "T1-slug", date(2026, 7, 28))
        self.assertEqual(rel, "NSF-2027/drafts/2026.07.28 a T1-slug.md")

    def test_next_draft_rel_increments_letter_for_same_date_and_base_name(self):
        call_dir = self.root / "NSF-2027"
        drafts_dir = call_dir / "drafts"
        drafts_dir.mkdir(parents=True)
        (drafts_dir / "2026.07.28 a T1-slug.md").write_text("---\n---\n")

        rel = next_draft_rel(self.root, "NSF-2027", "T1-slug", date(2026, 7, 28))
        self.assertEqual(rel, "NSF-2027/drafts/2026.07.28 b T1-slug.md")

    def test_next_draft_rel_resets_to_a_on_different_date(self):
        call_dir = self.root / "NSF-2027"
        drafts_dir = call_dir / "drafts"
        drafts_dir.mkdir(parents=True)
        (drafts_dir / "2026.07.27 c T1-slug.md").write_text("---\n---\n")

        rel = next_draft_rel(self.root, "NSF-2027", "T1-slug", date(2026, 7, 28))
        self.assertEqual(rel, "NSF-2027/drafts/2026.07.28 a T1-slug.md")

    def test_next_draft_rel_scoped_per_base_name(self):
        # A different topic drafted the same day starts its own lettering.
        call_dir = self.root / "NSF-2027"
        drafts_dir = call_dir / "drafts"
        drafts_dir.mkdir(parents=True)
        (drafts_dir / "2026.07.28 a T1-slug.md").write_text("---\n---\n")

        rel = next_draft_rel(self.root, "NSF-2027", "T2-other-slug", date(2026, 7, 28))
        self.assertEqual(rel, "NSF-2027/drafts/2026.07.28 a T2-other-slug.md")

    def test_next_draft_rel_skips_unrelated_and_malformed_files(self):
        call_dir = self.root / "NSF-2027"
        drafts_dir = call_dir / "drafts"
        drafts_dir.mkdir(parents=True)
        (drafts_dir / "T1-slug-v1.md").write_text("old form")
        (drafts_dir / "notes.md").write_text("unrelated")
        (drafts_dir / "2026.07.28 a T1-slug (Alon's conflicted copy 2026-07-29).md").write_text("dup")

        rel = next_draft_rel(self.root, "NSF-2027", "T1-slug", date(2026, 7, 28))
        self.assertEqual(rel, "NSF-2027/drafts/2026.07.28 a T1-slug.md")

    def test_next_draft_rel_refuses_after_z(self):
        call_dir = self.root / "NSF-2027"
        drafts_dir = call_dir / "drafts"
        drafts_dir.mkdir(parents=True)
        (drafts_dir / "2026.07.28 z T1-slug.md").write_text("---\n---\n")

        with self.assertRaises(PathRefused):
            next_draft_rel(self.root, "NSF-2027", "T1-slug", date(2026, 7, 28))


class DraftPdfGrammarTests(unittest.TestCase):
    def test_draft_pdf_is_a_create_target(self):
        self.assertEqual(
            write_mode_for("NSF-2027/drafts/2026.07.28 a T1-slug.pdf"), "create"
        )

    def test_pdf_must_carry_the_same_date_letter_grammar_as_the_md(self):
        for rel in (
            "NSF-2027/drafts/T1-slug.pdf",
            "NSF-2027/drafts/2026.07.28 T1-slug.pdf",
            "NSF-2027/drafts/2026.7.28 a T1-slug.pdf",
            "NSF-2027/drafts/2026.07.28 A T1-slug.pdf",
        ):
            with self.subTest(rel=rel):
                with self.assertRaises(PathRefused):
                    write_mode_for(rel)

    def test_pdf_is_only_allowed_under_drafts(self):
        """Outlines and topics have no PDF companion. Allowing one would make
        `drafts/` special for no reason and widen the binary write surface."""
        for rel in (
            "NSF-2027/topics.pdf",
            "NSF-2027/outlines/T1-slug.pdf",
            "OPEN.pdf",
        ):
            with self.subTest(rel=rel):
                with self.assertRaises(PathRefused):
                    write_mode_for(rel)

    def test_is_draft_pdf_discriminates(self):
        self.assertTrue(is_draft_pdf("NSF-2027/drafts/2026.07.28 a T1-slug.pdf"))
        self.assertFalse(is_draft_pdf("NSF-2027/drafts/2026.07.28 a T1-slug.md"))
        self.assertFalse(is_draft_pdf("NSF-2027/context/notes.pdf"))

    def test_pdf_rel_is_derived_from_the_md_not_composed(self):
        md = next_draft_rel(self.root, "NSF-2027", "T1-slug", date(2026, 7, 28))
        self.assertEqual(
            draft_pdf_rel_for(md), "NSF-2027/drafts/2026.07.28 a T1-slug.pdf"
        )

    def test_pdf_rel_refuses_a_non_draft_source(self):
        for rel in ("NSF-2027/topics.md", "NSF-2027/outlines/T1-slug.md", "OPEN.md"):
            with self.subTest(rel=rel):
                with self.assertRaises(PathRefused):
                    draft_pdf_rel_for(rel)

    def setUp(self):
        self.root = make_test_root()
        configure_env(self.root)


class ContextFolderIsNeverWritableTests(unittest.TestCase):
    """`<call>/context/` is Alon's, for material he drops in to steer a picked
    direction. It is an input only, so every write to it must be refused by the
    grammar rather than by anyone remembering not to."""

    def test_context_paths_are_refused(self):
        for rel in (
            "NSF-2027/context/notes.md",
            "NSF-2027/context/paper.pdf",
            "NSF-2027/context/sub/thing.md",
            "NSF-2027/context.md",
        ):
            with self.subTest(rel=rel):
                with self.assertRaises(PathRefused):
                    write_mode_for(rel)


if __name__ == "__main__":
    unittest.main()
