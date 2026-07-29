import hashlib
import os
import re
import shutil
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from test._env import configure_env, make_test_root  # noqa: E402

from lib.paths import PathRefused  # noqa: E402
from lib.publish import (  # noqa: E402
    COMPLETE_MARKER,
    _compose_content,
    _write_all,
    is_agent_owned,
    is_complete,
    parse_frontmatter,
    publish_append,
    publish_create,
    publish_create_binary,
    publish_regenerate,
    read_owned,
    render_frontmatter,
)


def _make_call_dir(root: Path, call: str = "NSF-2027") -> Path:
    """auto-proposals never creates call folders itself (SAFETY.md - a call
    folder only ever comes from a human dropping the call's material into
    the archive). Tests that publish into a call folder must mirror that by
    creating it themselves before exercising publish_create/publish_append.
    """
    call_dir = root / call
    call_dir.mkdir(parents=True, exist_ok=True)
    return call_dir


def owned_frontmatter(**overrides):
    d = {
        "artifact": "topics",
        "call": "NSF-2027",
        "generated_by": "auto-proposals",
        "generated_at": "27/07/2026 10:00",
        "version": 1,
    }
    d.update(overrides)
    return d


class PublishCreateTestCase(unittest.TestCase):
    def setUp(self):
        self.root = make_test_root()
        configure_env(self.root)
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def test_create_refuses_when_target_exists(self):
        rel = "NSF-2027/topics.md"
        _make_call_dir(self.root)
        publish_create(self.root, rel, "first\n", frontmatter=owned_frontmatter())
        original = (self.root / rel).read_text()

        with self.assertRaises(PathRefused):
            publish_create(self.root, rel, "second\n", frontmatter=owned_frontmatter())

        self.assertEqual((self.root / rel).read_text(), original)

    def test_create_refuses_outside_grammar(self):
        bad_rels = [
            "../escape",
            "_Granted/x.md",
            ".hidden/x.md",
            "foo/bar.md",
        ]
        for rel in bad_rels:
            with self.subTest(rel=rel):
                with self.assertRaises(PathRefused):
                    publish_create(self.root, rel, "x\n", frontmatter=owned_frontmatter())

        import os

        abs_path = os.path.join(str(self.root), "NSF-2027", "topics.md")
        with self.assertRaises(PathRefused):
            publish_create(self.root, abs_path, "x\n", frontmatter=owned_frontmatter())

    def test_create_refuses_symlinked_component_and_writes_nothing(self):
        import os

        outside = self.root.parent / "outside-target"
        outside.mkdir(exist_ok=True)
        self.addCleanup(shutil.rmtree, outside, ignore_errors=True)

        call_dir = self.root / "NSF-2027"
        call_dir.mkdir(parents=True, exist_ok=True)
        os.symlink(outside, call_dir / "drafts")

        with self.assertRaises(PathRefused):
            publish_create(
                self.root,
                "NSF-2027/drafts/2026.07.28 a T1-slug.md",
                "x\n",
                frontmatter=owned_frontmatter(),
            )
        self.assertEqual(list(outside.iterdir()), [])

    def test_create_leaves_no_tmp_files_on_success(self):
        _make_call_dir(self.root)
        publish_create(self.root, "NSF-2027/topics.md", "hello\n", frontmatter=owned_frontmatter())
        leftovers = list(self.root.rglob(".auto-proposals.tmp.*"))
        self.assertEqual(leftovers, [])

    def test_create_leaves_no_tmp_files_when_write_raises(self):
        rel = "NSF-2027/topics.md"
        _make_call_dir(self.root)
        publish_create(self.root, rel, "first\n", frontmatter=owned_frontmatter())

        # Second call raises PathRefused (target exists) - still must not
        # leave a temp file behind.
        with self.assertRaises(PathRefused):
            publish_create(self.root, rel, "second\n", frontmatter=owned_frontmatter())

        leftovers = list(self.root.rglob(".auto-proposals.tmp.*"))
        self.assertEqual(leftovers, [])

    def test_create_refuses_when_call_folder_missing_and_creates_nothing(self):
        # auto-proposals must never grow a new top-level folder in the
        # archive from a hallucinated or misspelled call name - the call
        # folder itself only ever comes from a human dropping the call's
        # material into the archive (SAFETY.md).
        before = set(self.root.iterdir())
        rel = "Never-Dropped-Here-2099/topics.md"

        with self.assertRaises(PathRefused):
            publish_create(self.root, rel, "x\n", frontmatter=owned_frontmatter(call="Never-Dropped-Here-2099"))

        after = set(self.root.iterdir())
        self.assertEqual(before, after)
        self.assertFalse((self.root / "Never-Dropped-Here-2099").exists())

    def test_create_into_existing_call_folder_creates_outlines_on_demand(self):
        _make_call_dir(self.root)
        outlines_dir = self.root / "NSF-2027" / "outlines"
        self.assertFalse(outlines_dir.exists())

        path = publish_create(
            self.root,
            "NSF-2027/outlines/T1-slug.md",
            "outline body\n",
            frontmatter=owned_frontmatter(artifact="outline"),
        )

        self.assertTrue(outlines_dir.is_dir())
        self.assertTrue(path.exists())
        self.assertEqual(
            path.read_text(),
            _compose_content(owned_frontmatter(artifact="outline"), "outline body\n"),
        )

    def test_create_refuses_when_call_folder_frozen_by_conflicted_copy(self):
        call_dir = _make_call_dir(self.root)
        conflicted = call_dir / "topics (Alon's conflicted copy 2026-07-27).md"
        conflicted.write_text("ambiguous content\n")

        with self.assertRaises(PathRefused) as ctx:
            publish_create(self.root, "NSF-2027/topics.md", "x\n", frontmatter=owned_frontmatter())

        self.assertIn(conflicted.name, str(ctx.exception))
        self.assertFalse((self.root / "NSF-2027" / "topics.md").exists())


class PublishRegenerateTestCase(unittest.TestCase):
    def setUp(self):
        self.root = make_test_root()
        configure_env(self.root)
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def test_regenerate_first_creation_with_none_sha(self):
        path = publish_regenerate(
            self.root, "OPEN.md", "call list\n",
            expected_sha256=None, frontmatter=owned_frontmatter(artifact="roster"),
        )
        self.assertTrue(path.exists())

    def test_regenerate_refuses_on_sha_mismatch_and_leaves_content_intact(self):
        publish_regenerate(
            self.root, "OPEN.md", "v1\n",
            expected_sha256=None, frontmatter=owned_frontmatter(artifact="roster"),
        )
        original = (self.root / "OPEN.md").read_text()

        with self.assertRaises(PathRefused):
            publish_regenerate(
                self.root, "OPEN.md", "v2\n",
                expected_sha256="0" * 64, frontmatter=owned_frontmatter(artifact="roster"),
            )

        self.assertEqual((self.root / "OPEN.md").read_text(), original)

    def test_regenerate_succeeds_on_matching_sha(self):
        publish_regenerate(
            self.root, "OPEN.md", "v1\n",
            expected_sha256=None, frontmatter=owned_frontmatter(artifact="roster"),
        )
        _, sha = read_owned(self.root, "OPEN.md")
        publish_regenerate(
            self.root, "OPEN.md", "v2\n",
            expected_sha256=sha, frontmatter=owned_frontmatter(artifact="roster"),
        )
        text, _ = read_owned(self.root, "OPEN.md")
        self.assertIn("v2", text)

    def test_regenerate_refuses_non_regenerate_target(self):
        with self.assertRaises(PathRefused):
            publish_regenerate(
                self.root, "NSF-2027/topics.md", "x\n",
                expected_sha256=None, frontmatter=owned_frontmatter(),
            )

    def test_regenerate_refuses_over_human_written_file_without_provenance(self):
        # CORPUS.md/OPEN.md are hand-editable by Alon. A file at that path
        # with no auto-proposals provenance frontmatter must never be
        # silently regenerated over, no matter what sha the caller passes.
        (self.root / "CORPUS.md").write_text("# my hand-written notes\n")
        _, sha = read_owned(self.root, "CORPUS.md")

        with self.assertRaises(PathRefused):
            publish_regenerate(
                self.root, "CORPUS.md", "generated content\n",
                expected_sha256=sha, frontmatter=owned_frontmatter(artifact="corpus"),
            )

        self.assertIn("my hand-written notes", (self.root / "CORPUS.md").read_text())

    def test_regenerate_refuses_when_root_artifact_frozen_by_conflicted_copy(self):
        conflicted = self.root / "CORPUS (Alon's conflicted copy 2026-07-27).md"
        conflicted.write_text("dup")

        with self.assertRaises(PathRefused) as ctx:
            publish_regenerate(
                self.root, "CORPUS.md", "generated content\n",
                expected_sha256=None, frontmatter=owned_frontmatter(artifact="corpus"),
            )

        self.assertIn(conflicted.name, str(ctx.exception))
        self.assertFalse((self.root / "CORPUS.md").exists())

    def test_regenerate_reruns_cas_check_immediately_before_replace(self):
        # The sha the caller passes was read before this call started; a
        # concurrent writer can land a change in the window between that
        # read and the actual replace. The fix re-hashes the on-disk file
        # right before the replace (not just once at the top of the call)
        # to narrow that window as far as possible - this test simulates a
        # writer landing inside the temp-file-write step, which only the
        # immediately-before-replace re-check can catch.
        publish_regenerate(
            self.root, "OPEN.md", "v1\n",
            expected_sha256=None, frontmatter=owned_frontmatter(artifact="roster"),
        )
        _, sha = read_owned(self.root, "OPEN.md")

        from lib import publish as publish_mod

        real_write_temp = publish_mod._write_temp_dirfd

        def racing_write_temp(dir_fd, content):
            name = real_write_temp(dir_fd, content)
            fd = os.open("OPEN.md", os.O_WRONLY | os.O_APPEND, dir_fd=dir_fd)
            try:
                os.write(fd, b"raced in\n")
            finally:
                os.close(fd)
            return name

        with patch.object(publish_mod, "_write_temp_dirfd", side_effect=racing_write_temp):
            with self.assertRaises(PathRefused):
                publish_regenerate(
                    self.root, "OPEN.md", "v2\n",
                    expected_sha256=sha, frontmatter=owned_frontmatter(artifact="roster"),
                )

        # The race-injected write must survive - regenerate refused rather
        # than clobbering it.
        self.assertIn("raced in", (self.root / "OPEN.md").read_text())

    def test_regenerate_pre_replace_rehash_refuses_cleanly_on_non_utf8_race(self):
        # Same race window as the test above, but the concurrent writer
        # lands invalid UTF-8 bytes. _hash_dirfd_or_none() used to buffer
        # the whole file and decode it as UTF-8 before hashing, so a racing
        # writer landing non-UTF-8 bytes made the immediately-before-replace
        # re-check itself crash with an uncaught UnicodeDecodeError instead
        # of cleanly refusing as a concurrent-edit conflict. It must now
        # hash raw bytes and never need to decode at all.
        publish_regenerate(
            self.root, "OPEN.md", "v1\n",
            expected_sha256=None, frontmatter=owned_frontmatter(artifact="roster"),
        )
        _, sha = read_owned(self.root, "OPEN.md")

        from lib import publish as publish_mod

        real_write_temp = publish_mod._write_temp_dirfd

        def racing_write_temp(dir_fd, content):
            name = real_write_temp(dir_fd, content)
            fd = os.open("OPEN.md", os.O_WRONLY | os.O_APPEND, dir_fd=dir_fd)
            try:
                os.write(fd, b"\xff\xfe\x00bad")
            finally:
                os.close(fd)
            return name

        with patch.object(publish_mod, "_write_temp_dirfd", side_effect=racing_write_temp):
            try:
                with self.assertRaises(PathRefused):
                    publish_regenerate(
                        self.root, "OPEN.md", "v2\n",
                        expected_sha256=sha, frontmatter=owned_frontmatter(artifact="roster"),
                    )
            except UnicodeDecodeError:
                self.fail(
                    "the pre-replace re-hash leaked a UnicodeDecodeError instead of "
                    "a clean PathRefused"
                )

    def test_regenerate_round_trip_agrees_on_unchanged_lf_content(self):
        # read_owned() and the immediately-before-replace re-hash
        # (_hash_dirfd_or_none) must compute the identical digest for the
        # same on-disk content, or every regenerate would spuriously look
        # like a concurrent-edit conflict.
        publish_regenerate(
            self.root, "OPEN.md", "line one\nline two\n",
            expected_sha256=None, frontmatter=owned_frontmatter(artifact="roster"),
        )
        _, sha = read_owned(self.root, "OPEN.md")

        publish_regenerate(
            self.root, "OPEN.md", "line one\nline two\n",
            expected_sha256=sha, frontmatter=owned_frontmatter(artifact="roster"),
        )

        text, _ = read_owned(self.root, "OPEN.md")
        self.assertIn("line one\nline two", text)

    def test_regenerate_round_trip_agrees_on_crlf_content(self):
        # read_owned() used to hash via Path.read_text(), which applies
        # universal-newline translation: a CRLF file would hash as though
        # it were LF there, while _hash_dirfd_or_none() (the
        # immediately-before-replace re-check) hashed the true bytes. The
        # two digests disagreed, so publish_regenerate() refused every
        # regenerate of a CRLF file with a spurious "changed since it was
        # read" mismatch even though nothing had changed. Both functions
        # must now hash the same raw bytes.
        crlf_content = _compose_content(
            owned_frontmatter(artifact="roster"), "line one\r\nline two\r\n"
        ).replace("\n", "\r\n")
        # write_bytes(), not write_text(), so the \r\n survives untouched -
        # write_text() would apply the same universal-newline translation
        # this test exists to catch.
        (self.root / "OPEN.md").write_bytes(crlf_content.encode("utf-8"))

        _, sha = read_owned(self.root, "OPEN.md")

        publish_regenerate(
            self.root, "OPEN.md", "line one\r\nline two\r\n",
            expected_sha256=sha, frontmatter=owned_frontmatter(artifact="roster"),
        )

        text, _ = read_owned(self.root, "OPEN.md")
        self.assertIn("line one", text)

    def test_read_owned_refuses_non_utf8_file_naming_the_path(self):
        path = self.root / "OPEN.md"
        path.write_bytes(b"\xff\xfe\x00bad")

        try:
            with self.assertRaises(PathRefused) as ctx:
                read_owned(self.root, "OPEN.md")
        except UnicodeDecodeError:
            self.fail("read_owned() leaked a UnicodeDecodeError instead of raising PathRefused")

        self.assertIn(str(path), str(ctx.exception))

    def test_read_owned_sha_matches_hashlib_for_large_file(self):
        body = "x" * 70000 + "\n"
        content = _compose_content(owned_frontmatter(artifact="roster"), body)
        (self.root / "OPEN.md").write_text(content, encoding="utf-8")

        _, sha = read_owned(self.root, "OPEN.md")

        self.assertEqual(sha, hashlib.sha256((self.root / "OPEN.md").read_bytes()).hexdigest())


class PublishAppendTestCase(unittest.TestCase):
    def setUp(self):
        self.root = make_test_root()
        configure_env(self.root)
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def test_append_refuses_without_agent_frontmatter(self):
        rel = "NSF-2027/topics.md"
        target = self.root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("no frontmatter here\n")

        with self.assertRaises(PathRefused):
            publish_append(self.root, rel, "steering text")

    def test_append_refuses_symlinked_target_via_dirfd_nofollow(self):
        # resolve_owned() already refuses a symlinked final component, but
        # the write path itself must not rely on that alone - a symlink
        # swapped in for the real artifact after resolve_owned() checked it
        # (classic TOCTOU) must still be caught by the dir_fd + O_NOFOLLOW
        # open at write time. Patch resolve_owned() to bypass its own check
        # so this test isolates publish_append's own protection.
        outside = self.root.parent / "outside-append-target.md"
        outside.write_text("not mine\n")
        self.addCleanup(outside.unlink, missing_ok=True)

        rel = "NSF-2027/topics.md"
        call_dir = self.root / "NSF-2027"
        call_dir.mkdir(parents=True, exist_ok=True)
        target = call_dir / "topics.md"
        os.symlink(outside, target)

        with patch("lib.publish.resolve_owned", return_value=target):
            with self.assertRaises(PathRefused):
                publish_append(self.root, rel, "steering text")

        self.assertEqual(outside.read_text(), "not mine\n")

    def test_append_succeeds_and_preserves_original_bytes_as_prefix(self):
        rel = "NSF-2027/topics.md"
        _make_call_dir(self.root)
        publish_create(self.root, rel, "body\n", frontmatter=owned_frontmatter())
        original_bytes = (self.root / rel).read_bytes()

        publish_append(self.root, rel, "focus on renewable energy")

        new_bytes = (self.root / rel).read_bytes()
        self.assertTrue(new_bytes.startswith(original_bytes))
        self.assertIn(b"focus on renewable energy", new_bytes)

    def test_append_is_true_o_append_original_bytes_are_exact_prefix_and_file_only_grows(self):
        rel = "NSF-2027/topics.md"
        _make_call_dir(self.root)
        publish_create(self.root, rel, "body\n", frontmatter=owned_frontmatter())
        original_bytes = (self.root / rel).read_bytes()

        publish_append(self.root, rel, "steering block one")
        after_first = (self.root / rel).read_bytes()
        self.assertTrue(after_first.startswith(original_bytes))
        self.assertGreaterEqual(len(after_first), len(original_bytes))

        # A second append must build on the *current* on-disk bytes (true
        # O_APPEND to the existing inode), not silently replace them the way
        # a write-temp-and-os.replace would if something else had touched
        # the file in between.
        publish_append(self.root, rel, "steering block two")
        after_second = (self.root / rel).read_bytes()
        self.assertTrue(after_second.startswith(after_first))
        self.assertGreaterEqual(len(after_second), len(after_first))
        self.assertIn(b"steering block one", after_second)
        self.assertIn(b"steering block two", after_second)

    def test_append_fence_is_strictly_longer_than_longest_backtick_run_in_payload(self):
        rel = "NSF-2027/topics.md"
        _make_call_dir(self.root)
        publish_create(self.root, rel, "body\n", frontmatter=owned_frontmatter())

        payload = "before\n```python\nprint('hi')\n```\nafter with ```` four backticks too"
        publish_append(self.root, rel, payload)

        content = (self.root / rel).read_text()
        prefix = _compose_content(owned_frontmatter(), "body\n")
        appended = content[len(prefix):]
        lines = appended.strip("\n").split("\n")

        # First line is the dated steering comment; the wrapping fence opens
        # on the very next line and must close on the very last line.
        self.assertTrue(lines[0].startswith("<!-- auto-proposals: steering appended"))
        opening_fence = lines[1]
        closing_fence = lines[-1]
        self.assertTrue(set(opening_fence) == {"`"})
        self.assertEqual(opening_fence, closing_fence)

        # The payload text itself must come back byte-for-byte between the
        # wrapping fences - i.e. it is nested inside, not broken out of.
        inner_text = "\n".join(lines[2:-1])
        self.assertEqual(inner_text, payload)

        longest_run_in_payload = max(len(run) for run in re.findall(r"`+", payload))
        self.assertGreater(len(opening_fence), longest_run_in_payload)
        self.assertGreaterEqual(len(opening_fence), 3)

    def test_append_refuses_when_call_folder_frozen_by_conflicted_copy(self):
        rel = "NSF-2027/topics.md"
        call_dir = _make_call_dir(self.root)
        publish_create(self.root, rel, "body\n", frontmatter=owned_frontmatter())
        original_bytes = (self.root / rel).read_bytes()

        conflicted = call_dir / "topics (Alon's conflicted copy 2026-07-27).md"
        conflicted.write_text("ambiguous content\n")

        with self.assertRaises(PathRefused) as ctx:
            publish_append(self.root, rel, "steering text")

        self.assertIn(conflicted.name, str(ctx.exception))
        self.assertEqual((self.root / rel).read_bytes(), original_bytes)


class ReadOwnedHostGateTestCase(unittest.TestCase):
    """read_owned() no longer calls _check_environment(): reads must work on
    any host / while Dropbox is syncing so a non-publish-host machine can
    still report what's in the archive. Writes stay host-gated."""

    def setUp(self):
        self.root = make_test_root()
        configure_env(self.root)
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def test_read_owned_ignores_host_gate_but_publish_create_still_enforces_it(self):
        rel = "NSF-2027/topics.md"
        _make_call_dir(self.root)
        publish_create(self.root, rel, "body\n", frontmatter=owned_frontmatter())

        wrong_host = os.environ.get("AUTO_PROPOSALS_PUBLISH_HOST", "HL") + "-definitely-not-this-host"
        os.environ["AUTO_PROPOSALS_PUBLISH_HOST"] = wrong_host
        # The host gate and the sync gate have separate opt-outs, so this can
        # exercise the host check without also re-enabling the Dropbox check
        # (which would make the test depend on the machine's sync state).
        os.environ["AUTO_PROPOSALS_ALLOW_ANY_HOST"] = "0"
        self.addCleanup(lambda: os.environ.__setitem__("AUTO_PROPOSALS_ALLOW_ANY_HOST", "1"))

        # Reads are not host-gated: this must succeed even though the
        # configured publish host no longer matches this machine.
        text, sha = read_owned(self.root, rel)
        self.assertIn("body", text)
        self.assertTrue(sha)

        # Writes are still host-gated.
        with self.assertRaises(PathRefused):
            publish_create(self.root, "NSF-2027/topics-v2.md", "second\n", frontmatter=owned_frontmatter())


class FrontmatterTestCase(unittest.TestCase):
    def test_round_trip_with_colon_and_hebrew_value_and_complete_last(self):
        d = {
            "artifact": "topics",
            "call": "NSF-2027",
            "generated_by": "auto-proposals",
            "note": "ratio 3:1",
            "title": "נושא מוצע",  # Hebrew value
            "sources": ["a.pdf", "b.pdf"],
            "complete": True,
        }
        rendered = render_frontmatter(d)

        lines = [line for line in rendered.split("\n") if line.strip()]
        # 'complete' must be the last key emitted, right before the
        # closing '---'.
        self.assertEqual(lines[-2], "complete: true")
        self.assertEqual(lines[-1], "---")

        parsed = parse_frontmatter(rendered)
        self.assertEqual(parsed["artifact"], "topics")
        self.assertEqual(parsed["note"], "ratio 3:1")
        self.assertEqual(parsed["title"], d["title"])
        self.assertEqual(parsed["sources"], ["a.pdf", "b.pdf"])
        self.assertIs(parsed["complete"], True)

    def test_is_agent_owned_and_is_complete(self):
        text = _compose_content(owned_frontmatter(complete=True), "body\n")
        self.assertTrue(is_agent_owned(text))
        self.assertTrue(is_complete(text))

        text2 = "no frontmatter\n"
        self.assertFalse(is_agent_owned(text2))
        self.assertFalse(is_complete(text2))

    def test_is_complete_requires_trailing_marker_not_just_frontmatter_flag(self):
        # A write that got truncated right after the frontmatter still has
        # `complete: true` at the top of the file - that must NOT read as
        # complete, because the frontmatter is written before the body.
        truncated = render_frontmatter(owned_frontmatter(complete=True)) + "body cut off mid"
        self.assertFalse(is_complete(truncated))

        whole = _compose_content(owned_frontmatter(complete=True), "body\n")
        self.assertTrue(whole.rstrip("\n").endswith(COMPLETE_MARKER))
        self.assertTrue(is_complete(whole))

    def test_is_agent_owned_requires_artifact_call_version(self):
        text = render_frontmatter({"generated_by": "auto-proposals"}) + "body\n"
        self.assertFalse(is_agent_owned(text))

        text2 = render_frontmatter(owned_frontmatter()) + "body\n"
        self.assertTrue(is_agent_owned(text2))

    def test_parse_frontmatter_rejects_duplicate_keys(self):
        # Ambiguous provenance (which value does a reader trust?) is treated
        # as no provenance at all, rather than "whichever the loop saw last".
        text = "---\ngenerated_by: auto-proposals\ngenerated_by: someone-else\n---\nbody\n"
        self.assertEqual(parse_frontmatter(text), {})

    def test_parse_frontmatter_rejects_oversized_block(self):
        huge = "x" * (17 * 1024)
        text = f"---\nnote: {huge}\n---\nbody\n"
        self.assertEqual(parse_frontmatter(text), {})

    def test_parse_frontmatter_rejects_too_many_keys(self):
        lines = [f"k{i}: v" for i in range(100)]
        text = "---\n" + "\n".join(lines) + "\n---\nbody\n"
        self.assertEqual(parse_frontmatter(text), {})

    def test_write_all_loops_until_every_byte_is_written(self):
        # os.write() is allowed to write fewer bytes than asked; a bare
        # single os.write() call (the pre-fix behaviour) can silently drop
        # the tail of a steering block on a busy filesystem.
        written = bytearray()
        calls = []

        def fake_write(fd, data):
            n = min(3, len(data))
            calls.append(n)
            written.extend(bytes(data[:n]))
            return n

        with patch("lib.publish.os.write", side_effect=fake_write):
            _write_all(999, b"hello world, this is more than 3 bytes")

        self.assertEqual(bytes(written), b"hello world, this is more than 3 bytes")
        self.assertGreater(len(calls), 1)


_PDF_BYTES = b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n1 0 obj\n<<>>\nendobj\ntrailer\n%%EOF\n"

_MD_REL = "NSF-2027/drafts/2026.07.28 a T1-slug.md"
_PDF_REL = "NSF-2027/drafts/2026.07.28 a T1-slug.pdf"


class PublishCreateBinaryTests(unittest.TestCase):
    def setUp(self):
        self.root = make_test_root()
        configure_env(self.root)
        _make_call_dir(self.root)

    def _publish_md(self, rel=_MD_REL):
        return publish_create(
            self.root, rel, "# draft\n", frontmatter=owned_frontmatter(artifact="draft")
        )

    def test_pdf_publishes_alongside_its_markdown(self):
        self._publish_md()
        target = publish_create_binary(self.root, _PDF_REL, _PDF_BYTES)
        self.assertTrue(target.exists())
        self.assertEqual(target.read_bytes(), _PDF_BYTES)

    def test_bytes_are_stored_verbatim(self):
        """The whole reason for a separate binary path: text-mode writing would
        translate newlines and corrupt the PDF silently."""
        self._publish_md()
        payload = b"%PDF-1.7\r\n\x00\x01\x02\r\n\x80\xff binary \r\n%%EOF"
        target = publish_create_binary(self.root, _PDF_REL, payload)
        self.assertEqual(target.read_bytes(), payload)

    def test_no_frontmatter_or_marker_is_injected(self):
        self._publish_md()
        target = publish_create_binary(self.root, _PDF_REL, _PDF_BYTES)
        raw = target.read_bytes()
        self.assertTrue(raw.startswith(b"%PDF"))
        self.assertNotIn(b"generated_by", raw)
        self.assertNotIn(COMPLETE_MARKER.encode(), raw)

    def test_refuses_when_the_markdown_draft_is_absent(self):
        """A PDF has no frontmatter, so it cannot vouch for itself. Its sibling
        .md is the only provenance anchor - without one, drafts/ would accept
        arbitrary binaries."""
        with self.assertRaises(PathRefused) as ctx:
            publish_create_binary(self.root, _PDF_REL, _PDF_BYTES)
        self.assertIn("markdown draft", str(ctx.exception))

    def test_refuses_when_the_sibling_markdown_is_not_agent_owned(self):
        drafts = self.root / "NSF-2027" / "drafts"
        drafts.mkdir(parents=True, exist_ok=True)
        (drafts / "2026.07.28 a T1-slug.md").write_text(
            "---\ngenerated_by: a human\n---\nhand written\n", encoding="utf-8"
        )
        with self.assertRaises(PathRefused):
            publish_create_binary(self.root, _PDF_REL, _PDF_BYTES)

    def test_refuses_to_overwrite_an_existing_pdf(self):
        self._publish_md()
        publish_create_binary(self.root, _PDF_REL, _PDF_BYTES)
        with self.assertRaises(PathRefused) as ctx:
            publish_create_binary(self.root, _PDF_REL, b"%PDF-1.7 different\n")
        self.assertIn("already exists", str(ctx.exception))
        self.assertEqual((self.root / _PDF_REL).read_bytes(), _PDF_BYTES)

    def test_refuses_a_non_draft_path(self):
        for rel in ("NSF-2027/topics.pdf", "OPEN.pdf", "NSF-2027/context/x.pdf"):
            with self.subTest(rel=rel):
                with self.assertRaises(PathRefused):
                    publish_create_binary(self.root, rel, _PDF_BYTES)

    def test_refuses_a_markdown_path(self):
        """create-pdf must not become a second way to write text artifacts,
        bypassing frontmatter and the completeness marker."""
        self._publish_md("NSF-2027/drafts/2026.07.28 b T1-slug.md")
        with self.assertRaises(PathRefused):
            publish_create_binary(
                self.root, "NSF-2027/drafts/2026.07.28 c T1-slug.md", b"plain"
            )

    def test_leaves_no_temp_file_behind_on_refusal(self):
        self._publish_md()
        publish_create_binary(self.root, _PDF_REL, _PDF_BYTES)
        with self.assertRaises(PathRefused):
            publish_create_binary(self.root, _PDF_REL, b"%PDF other\n")
        leftovers = [
            p.name
            for p in (self.root / "NSF-2027" / "drafts").iterdir()
            if p.name.startswith(".auto-proposals.tmp.")
        ]
        self.assertEqual(leftovers, [])


if __name__ == "__main__":
    unittest.main()
