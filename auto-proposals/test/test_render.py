import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from lib import render  # noqa: E402


class StripInternalMarkupTests(unittest.TestCase):
    def test_frontmatter_and_marker_are_removed(self):
        md = (
            "---\n"
            "artifact: draft\n"
            "generated_by: auto-proposals\n"
            "---\n"
            "# Title\n\nBody.\n\n"
            "<!-- auto-proposals:end -->\n"
        )
        out = render.strip_internal_markup(md)
        self.assertNotIn("generated_by", out)
        self.assertNotIn("auto-proposals:end", out)
        self.assertTrue(out.startswith("# Title"))

    def test_only_the_leading_frontmatter_block_is_stripped(self):
        """A '---' later in the document is a horizontal rule, not frontmatter.

        Stripping it would silently delete a chunk of a real draft, which is
        exactly the class of quiet corruption this module must not produce.
        """
        md = "---\na: b\n---\n# T\n\nPara one.\n\n---\n\nPara two.\n"
        out = render.strip_internal_markup(md)
        self.assertIn("Para one.", out)
        self.assertIn("Para two.", out)
        self.assertIn("\n---\n", out)

    def test_document_without_frontmatter_is_left_alone(self):
        md = "# Title\n\nBody.\n"
        self.assertEqual(render.strip_internal_markup(md).strip(), md.strip())


class MarkdownToHtmlTests(unittest.TestCase):
    def test_tables_survive_conversion(self):
        """A proposal's tables carry the commitment check and the budget. A
        converter that drops them yields a document that looks complete and is
        not, so this is asserted rather than assumed."""
        try:
            import markdown  # noqa: F401
        except ImportError:
            self.skipTest("python-markdown not installed")
        html = render.markdown_to_html("| a | b |\n|---|---|\n| 1 | 2 |\n", title="t")
        self.assertIn("<table>", html)
        self.assertIn("<td>1</td>", html)

    def test_title_is_escaped(self):
        html = render.markdown_to_html("body", title="<script>x</script>")
        self.assertNotIn("<title><script>", html)
        self.assertIn("&lt;script&gt;", html)

    def test_falls_back_to_preformatted_when_markdown_missing(self):
        with patch.dict(sys.modules, {"markdown": None}):
            html = render.markdown_to_html("# not parsed", title="t")
        self.assertIn("<pre>", html)
        self.assertIn("# not parsed", html)


class BackendSelectionTests(unittest.TestCase):
    def test_no_backend_raises_render_unavailable(self):
        with patch.object(render.shutil, "which", return_value=None):
            self.assertIsNone(render.available_backend())
            with self.assertRaises(render.RenderUnavailable):
                render.render_markdown_to_pdf("# t", Path("/nonexistent/o.pdf"))

    def test_a_broken_backend_does_not_end_the_chain(self):
        """An installed-but-broken backend must step aside for the next one.

        This is the snap-LibreOffice case: on PATH, fails every conversion. If
        a failure aborted the chain, a host with both a broken LibreOffice and
        a working weasyprint would produce no PDF at all.
        """
        calls = []

        def boom(*a, **k):
            calls.append("pandoc")
            raise render.RenderFailed("pandoc exploded")

        def ok(*a, **k):
            calls.append("weasyprint")
            return True

        with patch.object(render, "_try_pandoc", boom), \
             patch.object(render, "_try_weasyprint", ok), \
             patch.object(render, "_try_libreoffice", lambda *a, **k: False):
            backend = render.render_markdown_to_pdf("# t", Path("/tmp/unused.pdf"))

        self.assertEqual(backend, "weasyprint")
        self.assertEqual(calls, ["pandoc", "weasyprint"])

    def test_all_present_backends_failing_raises_render_failed_not_unavailable(self):
        """The two failure modes must stay distinguishable: 'install something'
        is a different instruction from 'what you installed is broken'."""
        with patch.object(render, "_try_pandoc", lambda *a, **k: (_ for _ in ()).throw(render.RenderFailed("x"))), \
             patch.object(render, "_try_weasyprint", lambda *a, **k: False), \
             patch.object(render, "_try_libreoffice", lambda *a, **k: False):
            with self.assertRaises(render.RenderFailed) as ctx:
                render.render_markdown_to_pdf("# t", Path("/tmp/unused.pdf"))
        self.assertIn("snap", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
