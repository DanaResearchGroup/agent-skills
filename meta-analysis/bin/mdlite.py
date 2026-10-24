"""Minimal Markdown parser shared by md2pdf.py and report_html.py.

parse(text) returns a list of blocks:
    ("h", level, text)          ATX heading, level 1-4
    ("p", text)                 paragraph (joined lines)
    ("li", depth, kind, text)   list item; kind "ul" or "ol"; depth from 1
    ("table", rows)             pipe table; rows[0] is the header
    ("img", alt, path)          image on its own line
    ("quote", text)             block quote (joined lines)
    ("code", text)              fenced code block
Inline markup (**bold**, *italic*, `code`, [text](url), ==highlight==) is left
in the text for each backend's inline renderer. A block whose whole text is
==...== is a highlighted block; is_highlight() detects it.
"""
import html
import re

LIST_RE = re.compile(r"^(\s*)([-*]|\d+\.)\s+(.*)$")


def parse(text):
    lines = text.split("\n")
    blocks, para, i = [], [], 0

    def flush():
        if para:
            blocks.append(("p", " ".join(para)))
            para.clear()

    while i < len(lines):
        line = lines[i]
        if line.startswith("```"):
            flush()
            code, i = [], i + 1
            while i < len(lines) and not lines[i].startswith("```"):
                code.append(lines[i]); i += 1
            blocks.append(("code", "\n".join(code))); i += 1
            continue
        if line.startswith("|"):
            flush()
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                if not re.match(r"^\|[\s:|-]+\|\s*$", lines[i]):
                    rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                i += 1
            blocks.append(("table", rows))
            continue
        m = re.match(r"^!\[(.*?)\]\((.*?)\)\s*$", line)
        if m:
            flush(); blocks.append(("img", m.group(1), m.group(2).replace("%20", " "))); i += 1
            continue
        h = re.match(r"^(#{1,4})\s+(.*)$", line)
        if h:
            flush(); blocks.append(("h", len(h.group(1)), h.group(2))); i += 1
            continue
        li = LIST_RE.match(line)
        if li:
            flush()
            depth = 1 + len(li.group(1).replace("\t", "  ")) // 2
            kind = "ol" if li.group(2)[0].isdigit() else "ul"
            item, i = [li.group(3)], i + 1
            while i < len(lines) and lines[i].strip() and lines[i].startswith(" ") and not LIST_RE.match(lines[i]):
                item.append(lines[i].strip()); i += 1
            blocks.append(("li", depth, kind, " ".join(item)))
            continue
        if line.startswith(">"):
            flush()
            quote = []
            while i < len(lines) and lines[i].startswith(">"):
                quote.append(lines[i].lstrip(">").strip()); i += 1
            blocks.append(("quote", " ".join(quote)))
            continue
        if not line.strip() or line.strip() == "---":
            flush(); i += 1
            continue
        para.append(line.strip()); i += 1
    flush()
    return blocks


def is_highlight(text):
    m = re.fullmatch(r"\s*==(.+)==\s*", text, flags=re.S)
    return m.group(1) if m and "==" not in m.group(1) else None


def _inline(s, esc, code, link, bold, ital, hl):
    keep = []

    def stash(out):
        keep.append(out)
        return f"\x00{len(keep) - 1}\x00"

    s = re.sub(r"`([^`]+)`", lambda m: stash(code(esc(m.group(1)))), s)
    s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)",
               lambda m: stash(link(m.group(2), _inline(m.group(1), esc, code, link, bold, ital, hl))
                               if re.match(r"https?://", m.group(2))
                               else _inline(m.group(1), esc, code, link, bold, ital, hl)), s)
    s = esc(s)
    s = re.sub(r"\*\*(.+?)\*\*", lambda m: bold(m.group(1)), s)
    s = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", lambda m: ital(m.group(1)), s)
    s = re.sub(r"==(.+?)==", lambda m: hl(m.group(1)), s)
    return re.sub(r"\x00(\d+)\x00", lambda m: keep[int(m.group(1))], s)


TEX_SPECIALS = {"\\": r"\textbackslash{}", "&": r"\&", "%": r"\%", "#": r"\#", "_": r"\_",
                "$": r"\$", "{": r"\{", "}": r"\}", "~": r"\textasciitilde{}", "^": r"\textasciicircum{}"}


def inline_tex(s):
    return _inline(s, lambda t: "".join(TEX_SPECIALS.get(c, c) for c in t),
                   lambda t: r"\texttt{" + t + "}",
                   lambda url, t: r"\href{" + url.replace("%", r"\%").replace("#", r"\#") + "}{" + t + "}",
                   lambda t: r"\textbf{" + t + "}", lambda t: r"\emph{" + t + "}",
                   lambda t: r"\hl{" + t + "}")


def inline_html(s):
    return _inline(s, lambda t: html.escape(t, quote=False),
                   lambda t: "<code>" + t + "</code>",
                   lambda url, t: '<a href="' + html.escape(url) + '">' + t + "</a>",
                   lambda t: "<strong>" + t + "</strong>", lambda t: "<em>" + t + "</em>",
                   lambda t: "<mark>" + t + "</mark>")
