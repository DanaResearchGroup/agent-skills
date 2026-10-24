"""Minimal Markdown parser shared by md2pdf.py and report_html.py.

parse(text) returns a list of blocks:
    ("h", level, text)          ATX heading, level 1-4
    ("p", text)                 paragraph (joined lines)
    ("li", depth, kind, text)   list item; kind "ul" or "ol"; depth from 1
    ("table", rows)             pipe table; rows[0] is the header
    ("img", alt, path)          image on its own line
    ("quote", text)             block quote (joined lines)
    ("code", text)              fenced code block
Inline markup (**bold**, *italic*, `code`, [text](url), ==highlight==, ~~strike~~) is left
in the text for each backend's inline renderer. A block whose whole text is
==...== is a highlighted block; is_highlight() detects it.
"""
import html
import re

LIST_RE = re.compile(r"^(\s*)([-*]|\d+\.)\s+(.*)$")


def _table_cells(line):
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    cells, cell = [], []
    for char in line:
        if char == "|":
            slashes = 0
            for previous in reversed(cell):
                if previous != "\\":
                    break
                slashes += 1
            if slashes % 2:
                cell.pop()
                cell.append("|")
            else:
                cells.append("".join(cell).strip())
                cell = []
        else:
            cell.append(char)
    cells.append("".join(cell).strip())
    return cells


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
                    rows.append(_table_cells(lines[i]))
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
            indent = len(li.group(1).replace("\t", "  "))
            kind = "ol" if li.group(2)[0].isdigit() else "ul"
            item, i = [li.group(3)], i + 1
            while i < len(lines) and lines[i].strip() and lines[i].startswith(" ") and not LIST_RE.match(lines[i]):
                item.append(lines[i].strip()); i += 1
            blocks.append(("li", indent, kind, " ".join(item)))
            continue
        if line.startswith(">"):
            flush()
            quote = []
            while i < len(lines) and lines[i].startswith(">"):
                quoted = lines[i][1:]
                if quoted.startswith(" "):
                    quoted = quoted[1:]
                quote.append(quoted); i += 1
            blocks.append(("quote", "\n".join(quote)))
            continue
        if not line.strip() or line.strip() == "---":
            flush(); i += 1
            continue
        para.append(line.strip()); i += 1
    flush()

    # Track each open level's raw indentation so a shallower item becomes a
    # sibling of the matching level, even after an indentation jump. TeX
    # supports at most four nested lists.
    normalized, list_indents = [], []
    for block in blocks:
        if block[0] == "li":
            _, indent, kind, text = block
            while list_indents and list_indents[-1] >= indent:
                list_indents.pop()
            depth = min(len(list_indents) + 1, 4)
            normalized.append(("li", depth, kind, text))
            list_indents.append(indent)
        else:
            normalized.append(block)
            list_indents.clear()
    return normalized


def is_highlight(text):
    m = re.fullmatch(r"\s*==(.+)==\s*", text, flags=re.S)
    return m.group(1) if m and "==" not in m.group(1) else None


def _inline(s, esc, code, link, bold, ital, hl, strike, keep=None, code_text=None,
            link_text=None, emphasis_links=False):
    """Render inline markup. Links are stashed under their own sentinel (\x01) so
    hl() and strike() can keep them outside the span: soul's \\hl and \\st cannot
    wrap \\href, and a crash there aborts the whole PDF."""
    if keep is None:
        keep = []
    if code_text is None:
        code_text = {}
    if link_text is None:
        link_text = {}

    def stash(out, mark="\x00"):
        keep.append(out)
        return f"{mark}{len(keep) - 1}{mark}"

    rec = lambda t: _inline(t, esc, code, link, bold, ital, hl, strike, keep, code_text,
                            link_text, emphasis_links)  # noqa: E731

    def wrap_emphasis(text, wrapper):
        if not emphasis_links:
            return wrapper(text)
        only_link = re.fullmatch(r"\x01(\d+)\x01", text)
        if only_link and int(only_link.group(1)) in link_text:
            index = int(only_link.group(1))
            url, label = link_text[index]
            label = wrapper(label)
            link_text[index] = (url, label)
            keep[index] = link(url, label)
            return text
        return _around_links(wrapper)(text)

    def stash_code(match):
        marker = stash(code(esc(match.group(1))))
        code_text[int(marker[1:-1])] = match.group(1)
        return marker

    def render_link(match):
        label, target = match.group(1), match.group(2)
        rendered = rec(label)
        if re.match(r"https?://", target):
            marker = stash(link(target, rendered), "\x01")
            link_text[int(marker[1:-1])] = (target, rendered)
            return marker
        plain_label = re.sub(r"\x00(\d+)\x00",
                             lambda m: code_text.get(int(m.group(1)), m.group(0)), label)
        if plain_label.replace("`", "") != target:
            rendered += " (" + code(esc(target)) + ")"
        return stash(rendered)

    s = re.sub(r"`([^`]+)`", stash_code, s)
    s = re.sub(r"\[([^\]]+)\]\(((?:[^()]|\([^()]*\))+)\)", render_link, s)
    s = re.sub(r"~~(.+?)~~", "\x02\\1\x03", s)
    s = esc(s)
    s = re.sub(r"\*\*(.+?)\*\*", lambda m: wrap_emphasis(m.group(1), bold), s)
    s = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])",
               lambda m: wrap_emphasis(m.group(1), ital), s)
    s = re.sub(r"==(.+?)==", lambda m: hl(m.group(1)), s)
    s = re.sub("\x02(.+?)\x03", lambda m: strike(m.group(1)), s)
    return re.sub(r"([\x00\x01])(\d+)\1", lambda m: keep[int(m.group(2))], s)


def _around_links(wrap):
    """Apply wrap() to each run of text between link sentinels, leaving links bare."""
    return lambda t: "".join(p if re.fullmatch(r"\x01\d+\x01", p) else wrap(p) if p.strip() else p
                             for p in re.split(r"(\x01\d+\x01)", t))


def _around_soul(wrap):
    """Wrap text runs while leaving links and existing soul spans outside."""
    def render(text):
        out, start, i = [], 0, 0
        while i < len(text):
            end = None
            link_marker = re.match(r"\x01\d+\x01", text[i:])
            if link_marker:
                end = i + link_marker.end()
            elif text.startswith("\x02", i):
                marker_end = text.find("\x03", i + 1)
                if marker_end >= 0:
                    end = marker_end + 1
            elif text.startswith((r"\hl{", r"\st{"), i):
                depth, j = 1, i + 4
                while j < len(text) and depth:
                    if text[j] == "\\" and j + 1 < len(text) and text[j + 1] in "{}":
                        j += 2
                        continue
                    if text[j] == "{":
                        depth += 1
                    elif text[j] == "}":
                        depth -= 1
                    j += 1
                if depth == 0:
                    end = j
            if end is None:
                i += 1
                continue
            run = text[start:i]
            out.append(wrap(run) if run.strip() else run)
            out.append(text[i:end])
            start = end
            i = end
        run = text[start:]
        out.append(wrap(run) if run.strip() else run)
        return "".join(out)
    return render


def _flatten_soul(text):
    """Split overlapping soul spans so TeX never has soul inside soul."""
    commands = {r"\hl{": "hl", r"\st{": "st"}

    def wrap(kind, content):
        return (r"\hl{" if kind == "hl" else r"\st{") + content + "}"

    def find_span(source, start):
        command = next((name for name in commands if source.startswith(name, start)), None)
        if command is None:
            return None
        depth, i = 1, start + len(command)
        while i < len(source) and depth:
            if source[i] == "\\" and i + 1 < len(source) and source[i + 1] in "{}":
                i += 2
                continue
            if source[i] == "{":
                depth += 1
            elif source[i] == "}":
                depth -= 1
            i += 1
        if depth:
            return None
        return commands[command], source[start + len(command):i - 1], i

    def render_span(kind, content):
        out, run, i = [], [], 0
        while i < len(content):
            span = find_span(content, i)
            if span is None:
                run.append(content[i])
                i += 1
                continue
            child_kind, child_content, end = span
            plain = "".join(run)
            if plain.strip():
                out.append(wrap(kind, plain))
            else:
                out.append(plain)
            run.clear()
            out.append(render_span(child_kind, child_content))
            i = end
        plain = "".join(run)
        if not out:
            return wrap(kind, plain)
        if plain.strip():
            out.append(wrap(kind, plain))
        else:
            out.append(plain)
        return "".join(out)

    out, i = [], 0
    while i < len(text):
        span = find_span(text, i)
        if span is None:
            out.append(text[i])
            i += 1
        else:
            kind, content, end = span
            out.append(render_span(kind, content))
            i = end
    return "".join(out)


TEX_SPECIALS = {"\\": r"\textbackslash{}", "&": r"\&", "%": r"\%", "#": r"\#", "_": r"\_",
                "$": r"\$", "{": r"\{", "}": r"\}", "~": r"\textasciitilde{}", "^": r"\textasciicircum{}"}


def escape_tex(text):
    return "".join(TEX_SPECIALS.get(char, char) for char in text)


def inline_tex(s):
    def tex_url(url):
        for char, encoded in (("\\", "%5C"), ("{", "%7B"), ("}", "%7D"),
                              ("^", "%5E"), ("~", "%7E"), (" ", "%20")):
            url = url.replace(char, encoded)
        return url.replace("%", r"\%").replace("#", r"\#")

    rendered = _inline(s, escape_tex,
                   lambda t: r"\texttt{" + t + "}",
                   lambda url, t: r"\href{" + tex_url(url) + "}{" + t + "}",
                   lambda t: r"\textbf{" + t + "}", lambda t: r"\emph{" + t + "}",
                   _around_soul(lambda t: r"\hl{" + t + "}"),
                   _around_soul(lambda t: r"\st{" + t + "}"), emphasis_links=True)
    return _flatten_soul(rendered)


def inline_html(s):
    return _inline(s, lambda t: html.escape(t, quote=False),
                   lambda t: "<code>" + t + "</code>",
                   lambda url, t: '<a href="' + html.escape(url) + '">' + t + "</a>",
                   lambda t: "<strong>" + t + "</strong>", lambda t: "<em>" + t + "</em>",
                   lambda t: "<mark>" + t + "</mark>", lambda t: "<del>" + t + "</del>")
