import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from lib import latex  # noqa: E402


class EscapeTests(unittest.TestCase):
    def test_every_latex_special_is_escaped(self):
        out = latex.escape("100% of $5 & #1 _x_ {a} ~ ^ \\")
        for raw in ("100\\%", "\\$5", "\\&", "\\#1", "\\_x\\_", "\\{a\\}"):
            self.assertIn(raw, out)

    def test_backslash_is_escaped_first_and_not_doubled(self):
        """If the backslash were replaced after the others, the backslashes
        introduced by their own replacements would be escaped again and the
        output would be visible garbage."""
        out = latex.escape("a\\b")
        self.assertEqual(out, "a\\textbackslash{}b")
        self.assertNotIn("\\textbackslash{}textbackslash", latex.escape("50% \\"))


class InlineTests(unittest.TestCase):
    def test_bold_and_italic(self):
        self.assertIn("\\textbf{x}", latex._inline("**x**"))
        self.assertIn("\\emph{x}", latex._inline("*x*"))

    def test_inline_code_contents_are_not_treated_as_markdown(self):
        out = latex._inline("`a_b **c**`")
        self.assertIn("\\texttt{", out)
        self.assertIn("a\\_b", out)
        self.assertNotIn("\\textbf", out)

    def test_link_url_is_not_escaped_but_label_is(self):
        """Escaping the URL would break the hyperlink; not escaping the label
        would break the compile on any label containing a special."""
        out = latex._inline("[100% guide](https://x.test/a_b)")
        self.assertIn("https://x.test/a_b", out)
        self.assertIn("100\\%", out)

    def test_image_becomes_a_figure_with_caption(self):
        out = latex._inline("![Work packages](fig/gantt.png)")
        self.assertIn("\\begin{figure}", out)
        self.assertIn("\\includegraphics", out)
        self.assertIn("fig/gantt.png", out)
        self.assertIn("\\caption{Work packages}", out)

    def test_image_without_alt_text_has_no_empty_caption(self):
        out = latex._inline("![](fig/x.png)")
        self.assertIn("\\includegraphics", out)
        self.assertNotIn("\\caption", out)


class BodyTests(unittest.TestCase):
    def test_headings_map_to_sections(self):
        out = latex.markdown_to_latex_body("# A\n\n## B\n\n### C\n")
        self.assertIn("\\section*{A}", out)
        self.assertIn("\\subsection*{B}", out)
        self.assertIn("\\subsubsection*{C}", out)

    def test_lists_open_and_close(self):
        out = latex.markdown_to_latex_body("- one\n- two\n\nafter\n")
        self.assertEqual(out.count("\\begin{itemize}"), 1)
        self.assertEqual(out.count("\\end{itemize}"), 1)
        self.assertIn("\\item one", out)

    def test_ordered_list_uses_enumerate(self):
        out = latex.markdown_to_latex_body("1. one\n2. two\n")
        self.assertIn("\\begin{enumerate}", out)
        self.assertIn("\\end{enumerate}", out)

    def test_table_becomes_tabularx_with_header_rule(self):
        md = "| call | state |\n|---|---|\n| GRO | new |\n"
        out = latex.markdown_to_latex_body(md)
        self.assertIn("\\begin{tabularx}", out)
        self.assertIn("\\toprule", out)
        self.assertIn("\\textbf{call}", out)
        self.assertIn("GRO & new", out)
        self.assertNotIn("---", out)

    def test_code_fence_is_verbatim_and_not_escaped(self):
        out = latex.markdown_to_latex_body("```\npython3 -m lib.scan --root $ROOT\n```\n")
        self.assertIn("\\begin{verbatim}", out)
        self.assertIn("$ROOT", out)
        self.assertNotIn("\\$ROOT", out)

    def test_every_environment_is_closed_at_end_of_document(self):
        """An unclosed environment does not degrade the PDF - it stops the
        compile, so the run produces nothing at all."""
        out = latex.markdown_to_latex_body("- a\n\n> quote\n\n```\ncode\n")
        for env in ("itemize", "quote", "verbatim"):
            self.assertEqual(
                out.count(f"\\begin{{{env}}}"), out.count(f"\\end{{{env}}}"), env
            )


class DocumentTests(unittest.TestCase):
    def test_document_is_self_contained(self):
        doc = latex.build_document("# T\n\nBody.\n", title="A draft")
        self.assertTrue(doc.startswith("\\documentclass"))
        self.assertIn("\\begin{document}", doc)
        self.assertIn("\\end{document}", doc)
        self.assertIn("\\usepackage{tabularx}", doc)

    def test_title_is_escaped(self):
        doc = latex.build_document("body\n", title="Cost & Scope 100%")
        self.assertIn("Cost \\& Scope 100\\%", doc)

    def test_hebrew_is_detected_and_pulls_in_a_unicode_preamble(self):
        """pdflatex silently drops Hebrew glyphs, so the preamble - and the
        engine choice that follows from it - has to switch on detection."""
        self.assertTrue(latex.has_hebrew("קול קורא"))
        self.assertFalse(latex.has_hebrew("call for proposals"))
        doc = latex.build_document("# קול קורא\n", title="t")
        self.assertIn("polyglossia", doc)
        self.assertIn("fontspec", doc)
        self.assertNotIn("inputenc", doc)

    def test_english_document_does_not_pull_in_the_hebrew_preamble(self):
        doc = latex.build_document("# Call\n", title="t")
        self.assertNotIn("polyglossia", doc)
        self.assertIn("inputenc", doc)

    def test_hebrew_font_is_overridable(self):
        """A missing font is a hard compile failure, and David CLM only exists
        if Debian/Ubuntu's `culmus` package is installed."""
        import os
        from unittest.mock import patch

        doc = latex.build_document("שלום\n", title="t")
        self.assertIn("{David CLM}", doc)
        with patch.dict(os.environ, {"AUTO_PROPOSALS_HEBREW_FONT": "Noto Sans Hebrew"}):
            doc = latex.build_document("שלום\n", title="t")
        self.assertIn("{Noto Sans Hebrew}", doc)
        self.assertNotIn("{David CLM}", doc)

    def test_hebrew_falls_back_to_fontspec_when_bidi_is_missing(self):
        """Ubuntu's texlive-xetex ships unicode-bidi.sty, NOT bidi.sty, so
        polyglossia's Hebrew support is unavailable on a host that looks
        correctly provisioned. Falling back beats failing every Hebrew draft."""
        doc = latex.build_document("שלום\n", title="t", rtl_support=False)
        self.assertNotIn("\\usepackage{polyglossia}", doc)
        self.assertIn("\\usepackage{fontspec}", doc)
        self.assertIn("\\newfontfamily\\hebrewfont", doc)
        self.assertIn("texlive-lang-arabic", doc)

    def test_rtl_support_is_irrelevant_to_an_english_document(self):
        for rtl in (True, False):
            with self.subTest(rtl=rtl):
                doc = latex.build_document("# Call\n", title="t", rtl_support=rtl)
                self.assertNotIn("hebrewfont", doc)

    def test_hebrew_can_be_forced_off(self):
        doc = latex.build_document("שלום\n", title="t", hebrew=False)
        self.assertNotIn("polyglossia", doc)


if __name__ == "__main__":
    unittest.main()
