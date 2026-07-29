import shutil
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from lib import figures  # noqa: E402


class BuildFigureTexTests(unittest.TestCase):
    def test_body_is_wrapped_in_the_shared_preamble(self):
        out = figures.build_figure_tex(r"\begin{tikzpicture}\end{tikzpicture}")
        self.assertIn(r"\documentclass[border=4pt]{standalone}", out)
        self.assertIn(r"\usepackage{tikz}", out)
        self.assertIn(r"\begin{document}", out)
        self.assertIn(r"\end{document}", out)

    def test_a_whole_document_is_refused(self):
        """A figure body that carries its own preamble would silently ignore
        the shared one, so colours and fonts would drift between figures in
        the same proposal."""
        with self.assertRaises(figures.FigureError):
            figures.build_figure_tex("\\documentclass{article}\n\\begin{document}x\\end{document}")


class PipelineFigureTests(unittest.TestCase):
    def test_stages_become_boxes_joined_by_arrows(self):
        out = figures.pipeline_figure([("A", "in"), ("B", "work"), ("C", "out")])
        self.assertEqual(out.count("\\node[box"), 3)
        self.assertEqual(out.count("\\draw[->"), 2)
        self.assertIn("(n0)", out)
        self.assertIn("boxgreen", out)

    def test_a_single_stage_has_no_arrows(self):
        out = figures.pipeline_figure([("only", "work")])
        self.assertNotIn("\\draw[->", out)

    def test_an_empty_pipeline_is_refused(self):
        with self.assertRaises(figures.FigureError):
            figures.pipeline_figure([])


class GanttFigureTests(unittest.TestCase):
    def test_tasks_become_bars(self):
        out = figures.gantt_figure([("WP1", 1, 4), ("WP2", 3, 10)], months=24)
        self.assertEqual(out.count("rectangle"), 2)
        self.assertIn("WP1", out)
        self.assertIn("months", out)

    def test_a_task_outside_the_timeline_is_refused(self):
        """Silently clipping it would draw a Gantt that disagrees with the
        work plan in the text - the kind of error a reviewer spots and the
        author does not."""
        for tasks in ([("WP1", 0, 4)], [("WP1", 1, 25)], [("WP1", 8, 3)]):
            with self.subTest(tasks=tasks):
                with self.assertRaises(figures.FigureError):
                    figures.gantt_figure(tasks, months=24)

    def test_empty_or_zero_length_is_refused(self):
        with self.assertRaises(figures.FigureError):
            figures.gantt_figure([], months=12)
        with self.assertRaises(figures.FigureError):
            figures.gantt_figure([("WP1", 1, 1)], months=0)

    def test_chart_width_is_independent_of_duration(self):
        """A 6-month and a 36-month plan should occupy the same page width,
        or the figure sizing changes with the project length."""
        short = figures.gantt_figure([("WP1", 1, 2)], months=6)
        long = figures.gantt_figure([("WP1", 1, 2)], months=36)
        self.assertIn("x=0.7667cm", short)
        self.assertIn("x=0.1278cm", long)


@unittest.skipUnless(shutil.which("xelatex"), "xelatex not installed")
class CompileFigureTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = Path(tempfile.mkdtemp(prefix="auto-proposals-figtest-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_a_figure_compiles_to_a_pdf(self):
        out = self.tmp / "fig.pdf"
        figures.compile_figure(
            figures.build_figure_tex(figures.pipeline_figure([("A", "in"), ("B", "out")])), out
        )
        self.assertTrue(out.exists())
        self.assertTrue(out.read_bytes().startswith(b"%PDF-"))

    def test_no_build_artefacts_are_left_beside_the_pdf(self):
        """The compile happens in a scratch directory precisely so that no
        .aux or .log can ever land in the archive next to the figure."""
        out = self.tmp / "fig.pdf"
        figures.compile_figure(figures.build_figure_tex(figures.pipeline_figure([("A", "in")])), out)
        self.assertEqual(sorted(p.name for p in self.tmp.iterdir()), ["fig.pdf"])

    def test_a_broken_figure_raises_rather_than_producing_nothing(self):
        """A silently skipped figure yields a PDF with a missing-image box."""
        with self.assertRaises(figures.FigureError):
            figures.compile_figure(
                figures.build_figure_tex(r"\begin{tikzpicture} \draw[ (0,0) -- ; \end{tikzpicture}"),
                self.tmp / "broken.pdf",
            )


if __name__ == "__main__":
    unittest.main()
