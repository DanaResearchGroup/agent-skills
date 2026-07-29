"""Emit LaTeX from the markdown a draft is written in.

Why LaTeX and not HTML: a funding proposal is judged partly on looking like a
funding proposal. Reviewers read typeset documents all day, and the difference
between a properly set two-column-free article with numbered figures and a
browser print-to-PDF is visible in the first second. LaTeX is also what Alon
already uses for manuscripts, so the .tex we emit is something he can pick up,
edit and recompile rather than a dead end.

The converter is deliberately small and covers the subset a draft actually
uses: headings, emphasis, lists, tables, block quotes, code, links, images and
rules. It is not a general markdown implementation, and it is not trying to be.
Anything it does not recognise passes through as escaped text, which is the
safe direction to fail in - a stray literal beats a document that will not
compile, because the second one produces nothing at all.
"""

from __future__ import annotations

import os
import re

# Characters LaTeX treats as syntax.
#
# Applied in ONE pass, via a single regex. Sequential str.replace() calls are
# the obvious implementation and are wrong: replacing "\" with
# "\textbackslash{}" injects braces that the later "{" and "}" rules then
# escape again, yielding "\textbackslash\{\}" - visible garbage in the PDF.
# A single pass cannot re-process what it just emitted.
_ESCAPES = {
    "\\": r"\textbackslash{}",
    "&": r"\&",
    "%": r"\%",
    "$": r"\$",
    "#": r"\#",
    "_": r"\_",
    "{": r"\{",
    "}": r"\}",
    "~": r"\textasciitilde{}",
    "^": r"\textasciicircum{}",
}

_ESCAPE_RE = re.compile("|".join(re.escape(c) for c in _ESCAPES))

_HEBREW_RE = re.compile(r"[\u0590-\u05FF]")

_HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")
_ULIST_RE = re.compile(r"^(\s*)[-*+]\s+(.*)$")
_OLIST_RE = re.compile(r"^(\s*)\d+[.)]\s+(.*)$")
_QUOTE_RE = re.compile(r"^\s*>\s?(.*)$")
_FENCE_RE = re.compile(r"^\s*```+\s*(\S*)\s*$")
_RULE_RE = re.compile(r"^\s*(?:---+|\*\*\*+|___+)\s*$")
_TABLE_SEP_RE = re.compile(r"^\s*\|?[\s:\-|]+\|[\s:\-|]*$")

_SECTIONS = ("section", "subsection", "subsubsection", "paragraph", "subparagraph", "subparagraph")


def escape(text: str) -> str:
    """Escape LaTeX syntax characters in a run of plain text."""
    return _ESCAPE_RE.sub(lambda m: _ESCAPES[m.group()], text)


def has_hebrew(text: str) -> bool:
    """True if the text contains Hebrew. Decides the engine and preamble.

    This matters because the archive is bilingual and a call may require
    Hebrew. pdflatex cannot set it at all; only a Unicode engine can, and the
    document needs right-to-left support loaded. Getting this wrong produces a
    PDF full of silently missing glyphs, which is worse than a failed compile.
    """
    return bool(_HEBREW_RE.search(text))


def _inline(text: str) -> str:
    """Convert inline markdown within a single line, escaping everything else.

    Inline code and images/links are extracted first and re-inserted after
    escaping, so their contents are not mangled by the escaper and their own
    syntax characters do not leak into the output.
    """
    placeholders: list[str] = []

    def stash(latex: str) -> str:
        placeholders.append(latex)
        return f"\x00{len(placeholders) - 1}\x00"

    # ![alt](path) -> figure. Done before links, since the syntax overlaps.
    def image(m: re.Match) -> str:
        alt, path = m.group(1), m.group(2)
        caption = f"\\caption{{{escape(alt)}}}\n" if alt.strip() else ""
        return stash(
            "\\begin{figure}[htbp]\n\\centering\n"
            f"\\includegraphics[width=0.9\\linewidth]{{{path}}}\n"
            f"{caption}\\end{{figure}}"
        )

    text = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", image, text)

    def link(m: re.Match) -> str:
        label, url = m.group(1), m.group(2)
        return stash(f"\\href{{{url}}}{{{escape(label)}}}")

    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link, text)
    text = re.sub(r"`([^`]+)`", lambda m: stash(f"\\texttt{{{escape(m.group(1))}}}"), text)

    text = escape(text)

    # Emphasis after escaping, so the markers themselves are still visible.
    text = re.sub(r"\*\*\*(.+?)\*\*\*", r"\\textbf{\\emph{\1}}", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"\\textbf{\1}", text)
    text = re.sub(r"(?<!\*)\*(?!\s)(.+?)(?<!\s)\*(?!\*)", r"\\emph{\1}", text)

    for i, latex in enumerate(placeholders):
        text = text.replace(f"\x00{i}\x00", latex)
    return text


def _flush_table(rows: list[str], out: list[str]) -> None:
    """Render collected pipe-table rows as a tabular.

    Uses `tabularx` with left-aligned wrapping columns, because a proposal's
    tables hold prose (the commitment check, work-package descriptions) and a
    plain `tabular` would run them off the page rather than wrap.
    """
    if not rows:
        return

    def cells(row: str) -> list[str]:
        row = row.strip()
        if row.startswith("|"):
            row = row[1:]
        if row.endswith("|"):
            row = row[:-1]
        return [c.strip() for c in row.split("|")]

    header = cells(rows[0])
    body = [cells(r) for r in rows[1:]]
    ncols = max([len(header)] + [len(r) for r in body]) or 1
    spec = ">{\\raggedright\\arraybackslash}X" * ncols

    out.append("\\begin{center}")
    out.append(f"\\begin{{tabularx}}{{\\linewidth}}{{{spec}}}")
    out.append("\\toprule")
    out.append(" & ".join(f"\\textbf{{{_inline(c)}}}" for c in header) + " \\\\")
    out.append("\\midrule")
    for row in body:
        row = row + [""] * (ncols - len(row))
        out.append(" & ".join(_inline(c) for c in row) + " \\\\")
    out.append("\\bottomrule")
    out.append("\\end{tabularx}")
    out.append("\\end{center}")
    rows.clear()


def markdown_to_latex_body(md_text: str) -> str:
    """Convert a markdown document body to LaTeX (no preamble)."""
    lines = md_text.replace("\r\n", "\n").split("\n")
    out: list[str] = []
    list_stack: list[str] = []
    table_rows: list[str] = []
    in_code = False
    in_quote = False

    def close_lists(to_depth: int = 0) -> None:
        while len(list_stack) > to_depth:
            out.append(f"\\end{{{list_stack.pop()}}}")

    def close_quote() -> None:
        nonlocal in_quote
        if in_quote:
            out.append("\\end{quote}")
            in_quote = False

    for raw in lines:
        fence = _FENCE_RE.match(raw)
        if fence:
            if in_code:
                out.append("\\end{verbatim}")
                in_code = False
            else:
                close_lists()
                close_quote()
                _flush_table(table_rows, out)
                out.append("\\begin{verbatim}")
                in_code = True
            continue

        if in_code:
            out.append(raw)
            continue

        # Tables are collected whole, because the separator row has to be seen
        # before the first row can be known to be a header.
        if "|" in raw and raw.strip().startswith("|"):
            if _TABLE_SEP_RE.match(raw):
                continue
            close_lists()
            close_quote()
            table_rows.append(raw)
            continue
        _flush_table(table_rows, out)

        if not raw.strip():
            close_lists()
            close_quote()
            out.append("")
            continue

        if _RULE_RE.match(raw):
            close_lists()
            close_quote()
            out.append("\\par\\noindent\\rule{\\linewidth}{0.4pt}")
            continue

        m = _HEADING_RE.match(raw)
        if m:
            close_lists()
            close_quote()
            level = min(len(m.group(1)), len(_SECTIONS)) - 1
            out.append(f"\\{_SECTIONS[level]}*{{{_inline(m.group(2).strip())}}}")
            continue

        q = _QUOTE_RE.match(raw)
        if q:
            close_lists()
            if not in_quote:
                out.append("\\begin{quote}")
                in_quote = True
            out.append(_inline(q.group(1)))
            continue
        close_quote()

        ul, ol = _ULIST_RE.match(raw), _OLIST_RE.match(raw)
        if ul or ol:
            m2 = ul or ol
            env = "itemize" if ul else "enumerate"
            depth = len(m2.group(1).expandtabs(4)) // 2 + 1
            while len(list_stack) > depth:
                out.append(f"\\end{{{list_stack.pop()}}}")
            if len(list_stack) < depth:
                while len(list_stack) < depth:
                    out.append(f"\\begin{{{env}}}")
                    list_stack.append(env)
            elif list_stack and list_stack[-1] != env:
                out.append(f"\\end{{{list_stack.pop()}}}")
                out.append(f"\\begin{{{env}}}")
                list_stack.append(env)
            out.append(f"\\item {_inline(m2.group(2))}")
            continue

        close_lists()
        out.append(_inline(raw.strip()))

    if in_code:
        out.append("\\end{verbatim}")
    _flush_table(table_rows, out)
    close_lists()
    close_quote()
    return "\n".join(out).strip() + "\n"


def build_document(
    md_text: str,
    *,
    title: str,
    hebrew: bool | None = None,
    rtl_support: bool = True,
) -> str:
    """Wrap a converted body in a complete, compilable LaTeX document.

    `hebrew` forces the bilingual preamble on or off; the default detects it.
    The Hebrew path needs a Unicode engine (xelatex/lualatex) - pdflatex will
    fail on it, which is the correct outcome rather than a PDF of blank boxes.

    `rtl_support` says whether polyglossia's `bidi` dependency is installed.
    When it is not, we fall back to loading the Hebrew font through fontspec
    alone rather than failing the compile. That fallback is not equivalent:
    glyphs and within-run ordering are right, but neutral characters
    (punctuation) at the boundary between Hebrew and English can land on the
    wrong side, because nothing is running the Unicode bidi algorithm. Good
    enough for the short quoted call fragments these drafts contain, NOT good
    enough for a document written in Hebrew throughout - hence the caller
    probes for bidi rather than assuming.
    """
    if hebrew is None:
        hebrew = has_hebrew(md_text) or has_hebrew(title)

    if hebrew:
        # Overridable, because the font is the most likely thing to be missing
        # on any given host and a missing font is a hard compile failure.
        # "David CLM" ships in Debian/Ubuntu's `culmus` package; if that is not
        # installed, set AUTO_PROPOSALS_HEBREW_FONT to one that is.
        font = os.environ.get("AUTO_PROPOSALS_HEBREW_FONT", "David CLM")
        if rtl_support:
            lang = (
                "\\usepackage{polyglossia}\n"
                "\\setmainlanguage{english}\n"
                "\\setotherlanguage{hebrew}\n"
                f"\\newfontfamily\\hebrewfont[Script=Hebrew]{{{font}}}\n"
            )
        else:
            lang = (
                "% bidi.sty is not installed (apt: texlive-lang-arabic), so\n"
                "% polyglossia's Hebrew support is unavailable. Falling back to\n"
                "% fontspec alone: correct glyphs, but punctuation at a\n"
                "% Hebrew/English boundary may sit on the wrong side.\n"
                f"\\newfontfamily\\hebrewfont[Script=Hebrew]{{{font}}}\n"
            )
        fonts = "\\usepackage{fontspec}\n"
    else:
        lang = ""
        fonts = "\\usepackage[T1]{fontenc}\n\\usepackage[utf8]{inputenc}\n"

    return (
        "\\documentclass[11pt,a4paper]{article}\n"
        f"{fonts}"
        "\\usepackage{geometry}\n"
        "\\geometry{margin=2.2cm}\n"
        "\\usepackage{graphicx}\n"
        "\\usepackage{booktabs}\n"
        "\\usepackage{tabularx}\n"
        "\\usepackage{array}\n"
        "\\usepackage{enumitem}\n"
        "\\usepackage{setspace}\n"
        "\\usepackage[colorlinks=true,linkcolor=black,urlcolor=blue]{hyperref}\n"
        f"{lang}"
        "\\setlength{\\parskip}{0.5em}\n"
        "\\setlength{\\parindent}{0pt}\n"
        "\\onehalfspacing\n"
        f"\\title{{{escape(title)}}}\n"
        "\\date{}\n"
        "\\begin{document}\n"
        "\\maketitle\n"
        f"{markdown_to_latex_body(md_text)}"
        "\\end{document}\n"
    )
