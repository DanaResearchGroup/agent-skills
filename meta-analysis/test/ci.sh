#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
import contextlib
import io
import pathlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

sys.path.insert(0, str(pathlib.Path("meta-analysis/bin").resolve()))
import md2pdf
import mdlite
import report_html


failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def has_nested_soul(tex):
    for outer in re.finditer(r"\\(?:hl|st)\{", tex):
        depth, i = 1, outer.end()
        while i < len(tex) and depth:
            if tex.startswith((r"\hl{", r"\st{"), i):
                return True
            if tex[i] == "\\" and i + 1 < len(tex) and tex[i + 1] in "{}":
                i += 2
                continue
            if tex[i] == "{":
                depth += 1
            elif tex[i] == "}":
                depth -= 1
            i += 1
    return False


for url, needle in (("report.md", "report.md"),
                    ("https://example.test/report", "https://example.test/report")):
    source = f"See [`report.md`]({url})."
    for renderer in (mdlite.inline_html, mdlite.inline_tex):
        try:
            result = renderer(source)
        except Exception as exc:
            check(False, f"{renderer.__name__} crashed for {url}: {exc}")
            continue
        check("report.md" in result, f"code span link label lost: {result}")
        check("<code>report.md</code>" in result if renderer is mdlite.inline_html
              else r"\texttt{report.md}" in result, f"code span not rendered: {result}")
        check(needle in result, f"link target missing: {result}")

destination = "https://en.wikipedia.org/wiki/Foo_(bar)"
for renderer, expected in ((mdlite.inline_html, f'<a href="{destination}">w</a>'),
                           (mdlite.inline_tex, rf"\href{{{destination}}}{{w}}")):
    result = renderer(f"[w]({destination})")
    check(result == expected, f"balanced link destination was truncated: {result}")

for renderer, expected in ((mdlite.inline_html, "the appendix (<code>appendix.md</code>)"),
                           (mdlite.inline_tex, r"the appendix (\texttt{appendix.md})")):
    result = renderer("[the appendix](appendix.md)")
    check(result == expected, f"local link path missing in {renderer.__name__}: {result}")
    result = renderer("[`appendix.md`](appendix.md)")
    check(result in ("<code>appendix.md</code>", r"\texttt{appendix.md}"),
          f"duplicate local link path in {renderer.__name__}: {result}")

for source in ("~~*[x](https://e.com)*~~", "==**[x](https://e.com)** tail=="):
    result = mdlite.inline_tex(source)
    check(not re.search(r"\\(?:textbf|emph|hl|st)\{\s*\}", result),
          f"empty TeX wrapper in {source}: {result}")
tex = mdlite.inline_tex("==**[x](https://e.com)** tail==")
check(r"\href{https://e.com}{\textbf{x}}" in tex,
      f"bold did not move inside link label: {tex}")
mixed = mdlite.inline_tex("==**before [x](https://e.com) after**==")
check(mixed == r"\hl{\textbf{before }}\href{https://e.com}{x}\hl{\textbf{ after}}",
      f"soul span contains link or emphasis wrappers are empty: {mixed}")
html = mdlite.inline_html("**[x](https://e.com)**")
check("<strong><a href=\"https://e.com\">x</a></strong>" == html,
      f"HTML emphasis semantics changed: {html}")

injection = r"[x](https://e.com/a}\textbf{INJ}{)"
injected_tex = mdlite.inline_tex(injection)
href = re.search(r"\\href\{([^{}]*)\}\{x\}", injected_tex)
check(href is not None, f"unsafe brace in href URL: {injected_tex}")
if href:
    check(not re.search(r"[{}]", href.group(1))
          and "\\" not in re.sub(r"\\[%#]", "", href.group(1)),
          f"unsafe TeX syntax in href URL: {href.group(1)}")
check(r"\textbf{INJ}" not in injected_tex, f"URL executed TeX markup: {injected_tex}")

for snippet in ('id="m-${esc(k)}"', '<use href="#m-${esc(k2)}"/>',
                '<use href="#m-${esc(e.source)}"/>',
                '${Number(e.depth)}'):
    check(snippet in report_html.JS, f"chart innerHTML interpolation is not escaped: {snippet}")


with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    source = root / "list.md"
    source.write_text("- parent\n      - deeply nested\n", encoding="utf-8")
    html = report_html.render(source, None, False)
    tex = md2pdf.convert(source, False)
    check(not re.search(r"<(?:ul|ol)>\s*<(?:ul|ol)>", html),
          f"adjacent HTML list opens: {html}")
    check(not re.search(r"\\begin\{(?:itemize|enumerate)\}\s*\\begin\{(?:itemize|enumerate)\}", tex),
          f"nested TeX list lacks item: {tex}")

    source.write_text("      - starts deep\n", encoding="utf-8")
    html = report_html.render(source, None, False)
    tex = md2pdf.convert(source, False)
    check(html.startswith("<ul>\n<li>"), f"deep-start HTML list not normalized: {html}")
    check(tex.startswith("\\begin{itemize}\n\\item "), f"deep-start TeX list not normalized: {tex}")

    blocks = mdlite.parse("- a\n      - deep\n    - mid\n")
    depths = [block[1] for block in blocks if block[0] == "li"]
    check(depths == [1, 2, 2], f"shallower item did not become sibling: {depths}")

    nested = "".join(" " * indent + "- level\n" for indent in (0, 2, 4, 6, 8, 10))
    depths = [block[1] for block in mdlite.parse(nested) if block[0] == "li"]
    check(depths == [1, 2, 3, 4, 4, 4], f"list depth was not capped at four: {depths}")

    table = mdlite.parse("| x \\| y | z |\n")
    cells = table[0][1][0]
    check(cells == ["x | y", "z"], f"escaped table pipe split a cell: {cells}")

    if shutil.which("xelatex"):
        pdf_source, pdf_output = root / "emphasis.md", root / "emphasis.pdf"
        pdf_source.write_text("~~*[x](https://e.com)*~~\n", encoding="utf-8")
        result = subprocess.run([sys.executable, "meta-analysis/bin/md2pdf.py",
                                 str(pdf_output), str(pdf_source)],
                                capture_output=True, text=True, timeout=90)
        check(result.returncode == 0,
              f"xelatex PDF build failed ({result.returncode}): {result.stderr}\n{result.stdout}")

        unsafe_source, unsafe_pdf = root / "unsafe.md", root / "unsafe.pdf"
        unsafe_source.write_text(injection + "\n", encoding="utf-8")
        result = subprocess.run([sys.executable, "meta-analysis/bin/md2pdf.py",
                                 str(unsafe_pdf), str(unsafe_source)],
                                capture_output=True, text=True, timeout=90)
        check(result.returncode == 0,
              f"xelatex rejected escaped URL ({result.returncode}): {result.stderr}\n{result.stdout}")

    image = root / "unsafe}.png"
    image.write_bytes(b"placeholder")
    image_md = root / "image.md"
    image_md.write_text("![Chart](unsafe}.png)\n", encoding="utf-8")
    warning = io.StringIO()
    image_dir = root / "safe-assets"
    with contextlib.redirect_stderr(warning):
        image_tex = md2pdf.convert(image_md, False, image_dir=image_dir)
    check(not warning.getvalue() and (image_dir / "image-0.png").exists(),
          f"existing awkward image path was not copied safely: {warning.getvalue()}")
    check("safe-assets/image-0.png" in image_tex,
          f"safe image alias absent from TeX: {image_tex}")
    missing_md = root / "missing-image.md"
    missing_md.write_text("![Missing](absent.png)\n", encoding="utf-8")
    with contextlib.redirect_stderr(warning := io.StringIO()):
        missing_tex = md2pdf.convert(missing_md, False)
    check("warning: image not found" in warning.getvalue()
          and r"\emph{[Missing]}" in missing_tex,
          f"missing image warning or alt placeholder absent: {warning.getvalue()} {missing_tex}")

    def png_chunk(name, data):
        payload = name + data
        return (struct.pack(">I", len(data)) + payload
                + struct.pack(">I", zlib.crc32(payload) & 0xffffffff))

    png = (b"\x89PNG\r\n\x1a\n"
           + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
           + png_chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00"))
           + png_chunk(b"IEND", b""))
    percent_image = root / "95% confidence.png"
    percent_image.write_bytes(png)
    percent_md = root / "percent-image.md"
    percent_md.write_text("![Confidence](95% confidence.png)\n", encoding="utf-8")
    if shutil.which("xelatex"):
        percent_pdf = root / "percent-image.pdf"
        result = subprocess.run([sys.executable, "meta-analysis/bin/md2pdf.py",
                                 str(percent_pdf), str(percent_md)],
                                capture_output=True, text=True, timeout=90)
        check(result.returncode == 0,
              f"xelatex rejected image path with percent ({result.returncode}): "
              f"{result.stderr}\n{result.stdout}")
        check("warning:" not in result.stderr,
              f"existing percent image unexpectedly used fallback: {result.stderr}")

        image_names = (
            "95% confidence.png", "a#b.png", "r&d.png", "snake_case.png",
            "tilde~x.png", "cap^x.png", "cost$5.png", "brace{x}.png",
            "back\\slash.png", "résumé ü.png", "two  spaces.png",
            "sub/dir with %.png", "quote's.png", "paren(1).png", "semi;colon.png",
        )
        image_lines = []
        for name in image_names:
            image_path = root / name
            image_path.parent.mkdir(parents=True, exist_ok=True)
            image_path.write_bytes(png)
            image_lines.append(f"![alt {name}]({name})")
        batch_md, batch_pdf = root / "image-batch.md", root / "image-batch.pdf"
        batch_md.write_text("\n\n".join(image_lines) + "\n", encoding="utf-8")
        result = subprocess.run([sys.executable, "meta-analysis/bin/md2pdf.py",
                                 str(batch_pdf), str(batch_md)],
                                capture_output=True, text=True, timeout=90)
        check(result.returncode == 0 and "warning:" not in result.stderr,
              f"xelatex failed awkward existing image paths ({result.returncode}): "
              f"{result.stderr}\n{result.stdout}")

    code_md = root / "code.md"
    code_md.write_text("```\n\\end{verbatim}\n\\textbf{INJ}\n```\n", encoding="utf-8")
    code_tex = md2pdf.convert(code_md, False)
    check(r"\end{verbatim}" not in code_tex,
          f"fenced code can terminate its TeX environment: {code_tex}")
    check(r"\textbf{INJ}" not in code_tex,
          f"fenced code runs TeX markup: {code_tex}")
    soul_cases = (
        "~~strike ==hl inside== strike~~",
        "==hl ~~strike inside~~ hl==",
        "~~a ==b== c ==d== e~~",
        "==a ~~b ==c== d~~ e==",
        "~~a ==b ~~c~~ d== e~~",
        "==x== ~~y ==z== w~~ ==v==",
        "==a ~~b ==c ~~d== e~~ f==",
    )
    if shutil.which("xelatex"):
        code_pdf = root / "code.pdf"
        result = subprocess.run([sys.executable, "meta-analysis/bin/md2pdf.py",
                                 str(code_pdf), str(code_md)],
                                capture_output=True, text=True, timeout=90)
        check(result.returncode == 0,
              f"xelatex rejected escaped fenced code ({result.returncode}): "
              f"{result.stderr}\n{result.stdout}")

    for index, quote in enumerate(soul_cases):
        soul_md, soul_pdf = root / f"soul-{index}.md", root / f"soul-{index}.pdf"
        soul_md.write_text(quote + "\n", encoding="utf-8")
        soul_tex = md2pdf.convert(soul_md, False)
        check(not has_nested_soul(soul_tex),
              f"nested soul command in {quote}: {soul_tex}")
        if shutil.which("xelatex"):
            result = subprocess.run([sys.executable, "meta-analysis/bin/md2pdf.py",
                                     str(soul_pdf), str(soul_md)],
                                    capture_output=True, text=True, timeout=90)
            check(result.returncode == 0,
                  f"xelatex rejected nested soul case {quote!r} ({result.returncode}): "
                  f"{result.stderr}\n{result.stdout}")

    quote_md = root / "quote.md"
    quote_text = "Keep *stars*, `ticks`, under_score\n> nested *literal*\nlast"
    quote_md.write_text("> Keep *stars*, `ticks`, under_score\n>> nested *literal*\n> last\n",
                        encoding="utf-8")
    parsed_quote = next(block[1] for block in mdlite.parse(quote_md.read_text())
                        if block[0] == "quote")
    check(parsed_quote == quote_text, f"block quote text was changed: {parsed_quote!r}")
    quote_html = report_html.render(quote_md, None, False)
    check("Keep *stars*, `ticks`, under_score<br>\n&gt; nested *literal*<br>\nlast" in quote_html,
          f"HTML quote markup was parsed or line breaks lost: {quote_html}")
    check("<em>" not in quote_html and "<code>" not in quote_html,
          f"HTML quote applied inline Markdown: {quote_html}")
    quote_tex = md2pdf.convert(quote_md, False)
    check("Keep *stars*, `ticks`, under\\_score\\\\> nested *literal*\\\\last" in quote_tex,
          f"TeX quote was parsed or line breaks lost: {quote_tex}")
    check(r"\emph{" not in quote_tex and r"\texttt{" not in quote_tex,
          f"TeX quote applied inline Markdown: {quote_tex}")

    missing = root / "missing.md"
    missing.write_text("![Missing chart](absent.png)\n", encoding="utf-8")
    stderr = io.StringIO()
    with contextlib.redirect_stderr(stderr):
        html = report_html.render(missing, None, False)
    target = (root / "absent.png").resolve()
    check(f"warning: image not found, alt text used: {target}" in stderr.getvalue(),
          f"missing image warning absent: {stderr.getvalue()}")
    check("Missing chart" in html and "missing-image" in html,
          f"missing image placeholder absent: {html}")

if failures:
    raise AssertionError("\n".join(failures))
print("meta-analysis renderer regressions passed")
PY
