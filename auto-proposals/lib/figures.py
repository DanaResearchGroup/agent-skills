"""Build standalone figures for a draft proposal.

Figures are TikZ/pgfplots, not matplotlib. Three reasons, in order:

* matplotlib on this machine is broken (built against NumPy 1.x, running 2.x)
  and fixing someone's conda environment is not this skill's job;
* a proposal figure is judged on looking like it belongs in the document, and
  TikZ inherits the document's fonts and line weights for free;
* Alon has to be able to change the numbers. A `.tex` he can open and edit is
  a live figure; a `.png` is a dead end, which is the same argument that makes
  drafts ship their LaTeX source.

Each figure is one self-contained folder, `<call>/grf/<slug>/`, holding
`<slug>.tex` (the source) and `<slug>.pdf` (the compiled vector image), so a
figure is never separated from the source that made it.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path


class FigureError(RuntimeError):
    """A figure could not be compiled. Never swallowed: a draft that silently
    omits a figure it references produces a PDF with a missing-image box, and
    the run must say so instead."""


# The preamble every figure shares. Kept here rather than in each figure so a
# change to fonts or colours applies to all of them at once, and so a figure
# source cannot quietly load a package the compile host does not have.
FIGURE_PREAMBLE = r"""\documentclass[border=4pt]{standalone}
\usepackage{fontspec}
\usepackage{tikz}
\usepackage{pgfplots}
\pgfplotsset{compat=1.18}
\usetikzlibrary{positioning,arrows.meta,fit,backgrounds,calc,shapes.geometric}
\usepackage{xcolor}
\definecolor{mockred}{RGB}{200,16,46}
\definecolor{boxblue}{RGB}{222,235,247}
\definecolor{boxgreen}{RGB}{226,240,217}
\definecolor{boxgrey}{RGB}{240,240,240}
"""


def build_figure_tex(body: str) -> str:
    """Wrap a TikZ body in the shared standalone preamble."""
    body = body.strip()
    if "\\begin{document}" in body:
        raise FigureError(
            "figure body must be TikZ content only, not a whole document - "
            "the preamble and document environment are supplied here"
        )
    return f"{FIGURE_PREAMBLE}\n\\begin{{document}}\n{body}\n\\end{{document}}\n"


def compile_figure(tex_source: str, out_pdf: Path, *, engine: str = "xelatex") -> Path:
    """Compile a standalone figure source to a cropped, vector PDF.

    Compiles in a scratch directory and copies only the PDF out, so no .aux or
    .log ever lands anywhere near the archive.
    """
    if not shutil.which(engine):
        raise FigureError(f"{engine} is not installed, so figures cannot be compiled")

    out_pdf = Path(out_pdf)
    out_pdf.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="auto-proposals-fig-") as tmp:
        tmpdir = Path(tmp)
        src = tmpdir / "figure.tex"
        src.write_text(tex_source, encoding="utf-8")
        proc = subprocess.run(
            [engine, "-interaction=nonstopmode", "-halt-on-error", src.name],
            cwd=tmpdir,
            capture_output=True,
            text=True,
            timeout=300,
        )
        built = tmpdir / "figure.pdf"
        if proc.returncode != 0 or not built.exists():
            log = (tmpdir / "figure.log")
            detail = ""
            if log.exists():
                errors = [
                    ln for ln in log.read_text(encoding="utf-8", errors="replace").splitlines()
                    if ln.startswith("!")
                ]
                detail = " | ".join(errors[:4])
            raise FigureError(
                f"{engine} failed to compile the figure (exit {proc.returncode}). {detail}"
            )
        shutil.copyfile(built, out_pdf)

    return out_pdf


def pipeline_figure(stages: list[tuple[str, str]], *, caption_colours: bool = True) -> str:
    """A left-to-right pipeline of labelled boxes joined by arrows.

    `stages` is a list of (label, kind) where kind is "in", "work" or "out",
    which only selects the fill colour. This is the single most reusable
    proposal figure - almost every methods section has one - so it is provided
    rather than hand-written per draft.
    """
    if not stages:
        raise FigureError("a pipeline figure needs at least one stage")
    fills = {"in": "boxgrey", "work": "boxblue", "out": "boxgreen"}
    lines = [
        r"\begin{tikzpicture}[",
        r"  node distance=6mm and 9mm, >=Stealth,",
        r"  box/.style={draw, rounded corners, align=center, "
        r"text width=27mm, minimum height=13mm, font=\small}]",
    ]
    prev = None
    for i, (label, kind) in enumerate(stages):
        fill = fills.get(kind, "boxblue") if caption_colours else "white"
        pos = f", right=of n{i - 1}" if prev is not None else ""
        lines.append(f"  \\node[box, fill={fill}{pos}] (n{i}) {{{label}}};")
        prev = i
    for i in range(1, len(stages)):
        lines.append(f"  \\draw[->, thick] (n{i - 1}) -- (n{i});")
    lines.append(r"\end{tikzpicture}")
    return "\n".join(lines)


def gantt_figure(tasks: list[tuple[str, int, int]], *, months: int) -> str:
    """A work-package Gantt chart.

    `tasks` is a list of (label, start_month, end_month), 1-based and
    inclusive. Every proposal needs one and drawing it by hand in TikZ each
    time is where mistakes get made.
    """
    if not tasks:
        raise FigureError("a Gantt figure needs at least one task")
    if months < 1:
        raise FigureError("a Gantt figure needs a positive number of months")
    unit = 4.6 / months  # keep the chart a fixed width regardless of duration
    lines = [
        r"\begin{tikzpicture}[x=%.4fcm, y=-0.62cm, font=\small]" % unit,
    ]
    # Month grid and axis.
    for m in range(0, months + 1):
        lines.append(f"  \\draw[gray!25] ({m},0) -- ({m},{len(tasks) + 0.4});")
    step = max(1, months // 6)
    for m in range(0, months + 1, step):
        lines.append(f"  \\node[above, font=\\scriptsize] at ({m},0) {{{m}}};")
    lines.append(
        f"  \\node[above=3.5mm, font=\\scriptsize\\itshape] at ({months / 2},0) {{months}};"
    )
    for i, (label, start, end) in enumerate(tasks, start=1):
        if not (1 <= start <= end <= months):
            raise FigureError(
                f"task {label!r} spans months {start}-{end}, outside 1-{months}"
            )
        lines.append(
            f"  \\node[left, font=\\small] at (0,{i}) {{{label}}};"
        )
        lines.append(
            f"  \\draw[fill=boxblue, draw=black!55, rounded corners=1pt] "
            f"({start - 1},{i - 0.28}) rectangle ({end},{i + 0.28});"
        )
    lines.append(r"\end{tikzpicture}")
    return "\n".join(lines)
