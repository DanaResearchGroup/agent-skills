#!/usr/bin/env python3
"""Render one or more meta-analysis Markdown files into a single PDF via xelatex.

Usage:
    md2pdf.py OUT.pdf FIRST.md [MORE.md ...]

The first file is the reader-facing summary; every further file is appended
after a page break as an appendix. Markdown support is that of mdlite.py.
A paragraph that is wholly ==...== renders as a highlighted box; inside a list
item or table cell, or as a shorter ==span==, it renders as inline
highlighting.

Needs xelatex with fontspec, xcolor, soul, tcolorbox, xltabular, enumitem,
hyperref, and the DejaVu fonts. Exits non-zero, printing the end of the
LaTeX log, if xelatex fails.
"""
import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from mdlite import inline_tex, is_highlight, parse  # noqa: E402

ENV = {"ul": "itemize", "ol": "enumerate"}


def para(text):
    inner = is_highlight(text)
    return r"\begin{keybox}" + inline_tex(inner) + r"\end{keybox}" if inner else inline_tex(text)


def table(rows):
    n = len(rows[0])
    # width share of each column follows its mean text length (clamped), so
    # a narrow "#" column does not take as much room as a prose column; the
    # longest unbreakable word in a column sets its floor
    def share(k):
        cells = [r[k] if k < len(r) else "" for r in rows]
        mean = sum(len(c) for c in cells) / len(cells)
        word = max((len(w) for c in cells for w in c.split()), default=1)
        return min(max(mean, 1.5 * word, 4), 60)
    lens = [share(k) for k in range(n)]
    spec = "".join(">{\\raggedright\\arraybackslash\\hsize=%.3f\\hsize}X" % (n * w / sum(lens)) for w in lens)
    out = [r"{\small\begin{xltabular}{\linewidth}{" + spec + r"}\toprule",
           " & ".join(r"\textbf{" + inline_tex(c) + "}" for c in rows[0]) + r"\\\midrule\endhead"]
    for r in rows[1:]:
        out.append(" & ".join(inline_tex(c) for c in (r + [""] * n)[:n]) + r"\\")
    out.append(r"\bottomrule\end{xltabular}}")
    return "\n".join(out)


def convert(md_path, appendix):
    base, out, stack = md_path.parent, [], []

    def close(depth=0):
        while len(stack) > depth:
            out.append(r"\end{" + ENV[stack.pop()] + "}")

    for b in parse(md_path.read_text(encoding="utf-8")):
        if b[0] != "li":
            close()
        if b[0] == "h":
            text = inline_tex(b[2])
            if b[1] == 1:
                out.append((r"\clearpage\appendixtitle{" if appendix else r"\doctitle{") + text + "}")
            else:
                out.append({2: r"\section*{", 3: r"\subsection*{", 4: r"\paragraph*{"}[b[1]] + text + "}")
        elif b[0] == "p":
            out.append(para(b[1]) + "\n")
        elif b[0] == "li":
            _, depth, kind, text = b
            close(depth)
            if len(stack) == depth and stack[-1] != kind:
                close(depth - 1)
            while len(stack) < depth:
                stack.append(kind); out.append(r"\begin{" + ENV[kind] + "}")
            out.append(r"\item " + inline_tex(text))
        elif b[0] == "table":
            out.append(table(b[1]))
        elif b[0] == "img":
            target = (base / b[2]).resolve()
            if not target.exists():
                print(f"warning: image not found, alt text used: {target}", file=sys.stderr)
                out.append(r"\begin{center}\emph{[" + inline_tex(b[1] or target.name) + r"]}\end{center}")
                continue
            out.append(r"\begin{center}\includegraphics[width=\linewidth,height=0.55\textheight,"
                       r"keepaspectratio]{\detokenize{" + str(target) + r"}}\end{center}")
        elif b[0] == "quote":
            out.append(r"\begin{quote}\itshape " + para(b[1]) + r"\end{quote}")
        elif b[0] == "code":
            out.append("\\begin{verbatim}\n" + b[1] + "\n\\end{verbatim}")
    close()
    return "\n".join(out)


PREAMBLE = r"""\documentclass[11pt,a4paper]{article}
\usepackage[margin=2cm]{geometry}
\usepackage{fontspec}\setmainfont{DejaVu Serif}\setsansfont{DejaVu Sans}\setmonofont{DejaVu Sans Mono}[Scale=0.85]
\usepackage{graphicx,xcolor,soul,booktabs,xltabular,enumitem}
\usepackage[most]{tcolorbox}
\usepackage[hidelinks]{hyperref}
\definecolor{hlyellow}{HTML}{FFF2A8}\sethlcolor{hlyellow}
\soulregister\textbf7\soulregister\emph7\soulregister\texttt7
\newtcolorbox{keybox}{colback=hlyellow,colframe=hlyellow!60!black,boxrule=0.4pt,arc=2pt,left=6pt,right=6pt,top=4pt,bottom=4pt}
\setlength{\parindent}{0pt}\setlength{\parskip}{5pt}
\setlist{itemsep=2pt,topsep=3pt}
\newcommand{\doctitle}[1]{{\sffamily\LARGE\bfseries #1\par}\vspace{6pt}}
\newcommand{\appendixtitle}[1]{{\sffamily\Large\bfseries Appendix: #1\par}\vspace{6pt}}
\begin{document}
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out")
    ap.add_argument("sources", nargs="+")
    a = ap.parse_args()
    if not shutil.which("xelatex"):
        sys.exit("md2pdf: xelatex not found")
    srcs = [pathlib.Path(s).resolve() for s in a.sources]
    body = "\n\n".join(convert(p, appendix=k > 0) for k, p in enumerate(srcs))
    with tempfile.TemporaryDirectory() as tmp:
        tex = pathlib.Path(tmp) / "report.tex"
        tex.write_text(PREAMBLE + body + "\n\\end{document}\n", encoding="utf-8")
        for _ in range(2):
            r = subprocess.run(["xelatex", "-interaction=nonstopmode", "-halt-on-error", tex.name],
                               cwd=tmp, capture_output=True, text=True)
            if r.returncode:
                log = (pathlib.Path(tmp) / "report.log").read_text(errors="replace")
                sys.exit("md2pdf: xelatex failed\n" + log[-3000:])
        shutil.copy(pathlib.Path(tmp) / "report.pdf", a.out)
    print(a.out)


if __name__ == "__main__":
    main()
