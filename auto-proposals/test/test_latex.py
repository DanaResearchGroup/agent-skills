import re
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
        self.assertIn("\\usepackage[bidi=default]{babel}", doc)
        self.assertIn("fontspec", doc)
        self.assertNotIn("inputenc", doc)

    def test_english_document_does_not_pull_in_the_hebrew_preamble(self):
        doc = latex.build_document("# Call\n", title="t")
        self.assertNotIn("babel", doc)
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

    def test_hebrew_needs_no_package_beyond_a_bare_xetex_install(self):
        """The whole reason for babel over polyglossia. polyglossia's Hebrew
        pulls in bidi.sty, which Debian/Ubuntu ship ONLY inside
        texlive-lang-arabic - an Arabic package that has no business being a
        dependency of Hebrew output. babel carries babel-he.ini itself and
        implements bidi with XeTeX primitives, so `texlive-xetex` alone is
        enough. This test is the guard against that dependency creeping back."""
        doc = latex.build_document("שלום\n", title="t")
        self.assertNotIn("polyglossia", doc)
        self.assertNotIn("bidi.sty", doc)
        self.assertNotIn("texlive-lang-arabic", doc)
        self.assertIn("\\usepackage[bidi=default]{babel}", doc)
        self.assertIn("\\babelprovide[import]{hebrew}", doc)

    def test_only_english_and_hebrew_are_declared(self):
        """Two languages, deliberately. Every other language would need its own
        font and locale data, and none of them appear in this archive."""
        doc = latex.build_document("שלום\n", title="t")
        provided = re.findall(r"\\babelprovide\[[^\]]*\]\{(\w+)\}", doc)
        self.assertEqual(sorted(provided), ["english", "hebrew"])

    def test_hebrew_can_be_forced_off(self):
        doc = latex.build_document("שלום\n", title="t", hebrew=False)
        self.assertNotIn("babel", doc)


class HebrewRunMarkingTests(unittest.TestCase):
    """Without \\foreignlanguage the Hebrew preamble is inert: babel applies
    the Hebrew font and switches direction only inside a language switch."""

    def test_a_hebrew_run_is_wrapped(self):
        out = latex.mark_hebrew_runs("a term מחקר דומה, which means similar.")
        self.assertIn("\\foreignlanguage{hebrew}{מחקר דומה}", out)
        self.assertNotIn("similar", out.split("}")[0])

    def test_neutrals_between_hebrew_words_stay_inside_the_run(self):
        """The colon belongs to the Hebrew phrase. Left outside, the bidi
        algorithm places it at the wrong end of the run."""
        out = latex.mark_hebrew_runs("requires: שפה: אנגלית בלבד.")
        self.assertIn("\\foreignlanguage{hebrew}{שפה: אנגלית בלבד}", out)

    def test_english_between_two_hebrew_fragments_is_not_swallowed(self):
        """The bug this regex was rewritten for: bridging over any non-Hebrew
        character pulled the English word into the Hebrew run, where it would
        be typeset in the Hebrew font and reordered right-to-left."""
        out = latex.mark_hebrew_runs("Clause (ח) says אין מחקר outright.")
        self.assertIn("\\foreignlanguage{hebrew}{ח}", out)
        self.assertIn("\\foreignlanguage{hebrew}{אין מחקר}", out)
        # The real property: no English word ends up inside a Hebrew group.
        wrapped = re.findall(r"\\foreignlanguage\{hebrew\}\{([^}]*)\}", out)
        self.assertEqual(wrapped, ["ח", "אין מחקר"])
        for group in wrapped:
            self.assertNotRegex(group, r"[A-Za-z]")

    def test_an_english_only_document_is_untouched(self):
        text = "No Hebrew here at all: 100% English."
        self.assertEqual(latex.mark_hebrew_runs(text), text)

    def test_inline_code_is_never_wrapped(self):
        """mark_hebrew_runs runs while code is still stashed as a placeholder,
        so a path or identifier can never be reordered."""
        out = latex._inline("see `AUTO_PROPOSALS_ROOT` and שלום")
        self.assertIn("\\texttt{AUTO\\_PROPOSALS\\_ROOT}", out)
        self.assertIn("\\foreignlanguage{hebrew}{שלום}", out)


if __name__ == "__main__":
    unittest.main()


class MockValueTests(unittest.TestCase):
    """A draft carries invented numbers by design. The one thing that must
    never happen is a mock number being mistaken for a researched one."""

    def test_a_mock_marker_renders_bold_red(self):
        out = latex.mark_mock_values("costs [MOCK: 45,000 NIS] per year")
        self.assertIn("\\textcolor{mockred}{\\textbf{[MOCK: 45,000 NIS]}}", out)

    def test_the_marker_text_survives_into_the_output(self):
        """The word MOCK stays visible in the PDF, not just the colour - a
        greyscale print or a colour-blind reader must still see it."""
        out = latex.mark_mock_values("[MOCK: 12]")
        self.assertIn("[MOCK: 12]", out)

    def test_several_markers_on_one_line_are_all_caught(self):
        out = latex.mark_mock_values("[MOCK: 3] of [MOCK: 9] runs")
        self.assertEqual(out.count("mockred"), 2)

    def test_prose_without_a_marker_is_untouched(self):
        text = "The budget is 350,000 as stated in the call."
        self.assertEqual(latex.mark_mock_values(text), text)

    def test_the_colour_is_defined_in_every_document(self):
        """Otherwise the first mock value in any draft fails the compile."""
        for md in ("# English only\n", "# עברית\n"):
            with self.subTest(md=md):
                self.assertIn("\\definecolor{mockred}", latex.build_document(md, title="t"))

    def test_markers_survive_the_full_inline_pipeline(self):
        out = latex._inline("screens [MOCK: 12] APIs at **[MOCK: 45,000]** cost")
        self.assertEqual(out.count("mockred"), 2)

    def test_a_marker_inside_inline_code_is_left_alone(self):
        """Code is a literal; colouring inside it would change what it says."""
        out = latex._inline("`[MOCK: x]` is the marker syntax")
        self.assertNotIn("mockred", out)
