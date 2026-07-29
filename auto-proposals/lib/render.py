"""Render a markdown draft to PDF.

Alon reads drafts on screen and on paper, and a funding draft that only exists
as markdown is one he cannot hand to a colleague. So every draft is published
twice: the markdown, which stays the editable source of truth, and a PDF
rendering of it.

**LaTeX is the intended path**, because a proposal is judged partly on looking
like one and because the .tex it compiles is kept alongside the PDF for Alon to
edit and recompile. Everything else here is a fallback for a host without a TeX
engine, and a fallback never produces LaTeX sources.

This module deliberately does NOT pick one PDF toolchain and depend on it. The
skill runs on several of Alon's machines and inside cron, and the available
converters differ between them - the manuscripts repo compiles with MiKTeX on
his Windows box, while HL has no TeX at all. So it tries a chain of backends in
quality order and reports which one it used, so the caller can say so in its
run report.

The one behaviour this module refuses to have is a silent skip. If no backend
is available it raises RenderUnavailable naming what to install. A draft that
quietly shipped without its PDF would look identical to one that succeeded.
"""

from __future__ import annotations

import html as html_mod
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from lib import latex


class RenderUnavailable(Exception):
    """No PDF backend is installed on this host. The message names the fix."""


class RenderFailed(Exception):
    """A backend was available, ran, and did not produce a usable PDF."""


# Frontmatter is our bookkeeping, not part of the document. It is stripped
# before rendering so the PDF opens on the title rather than on YAML.
_FRONTMATTER_RE = re.compile(r"\A---\s*\n.*?\n---\s*\n", re.DOTALL)

# The completeness marker is likewise internal.
_MARKER_RE = re.compile(r"^<!--\s*auto-proposals:end\s*-->\s*$", re.MULTILINE)

_CSS = """
@page { size: A4; margin: 2.2cm 2.0cm; }
body { font-family: "Times New Roman", Times, serif; font-size: 11pt;
       line-height: 1.5; color: #000; }
h1 { font-size: 17pt; margin: 0 0 0.6em 0; }
h2 { font-size: 13.5pt; margin: 1.4em 0 0.4em 0; border-bottom: 1px solid #999;
     padding-bottom: 2px; }
h3 { font-size: 12pt; margin: 1.1em 0 0.3em 0; }
p, li { text-align: justify; }
table { border-collapse: collapse; width: 100%; margin: 0.8em 0; font-size: 10pt; }
th, td { border: 1px solid #666; padding: 4px 6px; text-align: left;
         vertical-align: top; }
th { background: #eee; }
code, pre { font-family: "DejaVu Sans Mono", monospace; font-size: 9.5pt; }
pre { background: #f4f4f4; padding: 6px 8px; border: 1px solid #ddd;
      white-space: pre-wrap; }
blockquote { margin: 0.6em 0 0.6em 1.2em; padding-left: 0.8em;
             border-left: 3px solid #bbb; color: #333; }
img { max-width: 100%; }
figure { margin: 1em 0; text-align: center; }
figcaption { font-size: 9.5pt; font-style: italic; margin-top: 0.3em; }
"""


def strip_internal_markup(md_text: str) -> str:
    """Remove the frontmatter block and completeness marker from a published
    artifact, leaving the document a reader should see.

    Only newlines are trimmed, never spaces. A bare .strip() would also eat
    leading indentation - turning a document that opens with an indented code
    block into one that opens with a paragraph - which is the exact class of
    quiet corruption this renderer exists to avoid.
    """
    body = _FRONTMATTER_RE.sub("", md_text, count=1)
    return _MARKER_RE.sub("", body).strip("\n") + "\n"


def markdown_to_html(md_text: str, *, title: str) -> str:
    """Convert markdown to a standalone HTML document.

    Uses python-markdown with the table and fenced-code extensions, because a
    proposal draft's tables are load-bearing and a converter that drops them
    produces a document that looks complete and is not. If python-markdown is
    missing we fall back to escaping the text into a <pre> block rather than
    emitting a half-parsed document - an obviously-plain PDF is a better
    failure than a subtly-mangled one.
    """
    try:
        import markdown  # type: ignore

        body = markdown.markdown(
            md_text,
            extensions=["tables", "fenced_code", "sane_lists", "attr_list"],
        )
    except ImportError:
        body = "<pre>" + html_mod.escape(md_text) + "</pre>"

    return (
        "<!DOCTYPE html>\n<html><head><meta charset='utf-8'>\n"
        f"<title>{html_mod.escape(title)}</title>\n"
        f"<style>{_CSS}</style>\n</head><body>\n{body}\n</body></html>\n"
    )


def _run(cmd: list[str], *, cwd: str | None = None, timeout: int = 180) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, check=False
    )


# Unicode engines first. The archive is bilingual and a call may require
# Hebrew; pdflatex cannot set it at all, so preferring it would produce a PDF
# of missing glyphs on exactly the documents where that is least noticeable.
LATEX_ENGINES = ("xelatex", "lualatex", "pdflatex", "tectonic")


def latex_engine() -> str | None:
    """The LaTeX engine that would be used, or None if none is installed."""
    return next((e for e in LATEX_ENGINES if shutil.which(e)), None)


def _try_latex(
    md_text: str, out_path: Path, base_dir: Path, title: str, keep_tex: Path | None
) -> bool:
    """Preferred backend: emit LaTeX, compile it, and optionally keep the .tex.

    Compiled twice. A single pass leaves cross-references and any table-of-
    contents unresolved, and the failure is silent - the PDF is produced, just
    with '??' where the references should be.

    The engine is never allowed to prompt: `-interaction=nonstopmode` plus a
    timeout, because a LaTeX error dialog waiting on stdin inside cron hangs
    the run forever rather than failing it.
    """
    engine = latex_engine()
    if engine is None:
        return False

    hebrew = latex.has_hebrew(md_text) or latex.has_hebrew(title)
    if hebrew and engine == "pdflatex":
        raise RenderFailed(
            "this draft contains Hebrew and the only LaTeX engine available is "
            "pdflatex, which cannot typeset it. Install xelatex or lualatex."
        )

    tex_source = latex.build_document(
        md_text, title=title, hebrew=hebrew
    )

    with tempfile.TemporaryDirectory() as td:
        stem = "draft"
        tex_path = Path(td) / f"{stem}.tex"
        tex_path.write_text(tex_source, encoding="utf-8")

        if engine == "tectonic":
            cmd = ["tectonic", "--outdir", td, str(tex_path)]
            passes = 1  # tectonic reruns internally until references settle
        else:
            cmd = [
                engine, "-interaction=nonstopmode", "-halt-on-error",
                "-output-directory", td, str(tex_path),
            ]
            passes = 2

        res = None
        for _ in range(passes):
            # cwd=base_dir so \includegraphics finds figures by relative path.
            res = _run(cmd, cwd=str(base_dir), timeout=240)

        produced = Path(td) / f"{stem}.pdf"
        if not produced.exists():
            log = ""
            log_path = Path(td) / f"{stem}.log"
            if log_path.exists():
                log = _latex_error_excerpt(log_path.read_text(errors="replace"))
            if not log and res is not None:
                log = (res.stderr or res.stdout or "").strip()[:400]
            raise RenderFailed(f"{engine} produced no PDF: {log}")

        shutil.copyfile(produced, out_path)
        if keep_tex is not None:
            keep_tex.parent.mkdir(parents=True, exist_ok=True)
            keep_tex.write_text(tex_source, encoding="utf-8")
    return True


def _latex_error_excerpt(log: str) -> str:
    """Pull the actual LaTeX errors out of a log that is mostly noise.

    A raw .log tail is usually font-map chatter and says nothing about why the
    compile failed. The lines that matter start with '!'.
    """
    errors = [ln for ln in log.splitlines() if ln.startswith("!")]
    if errors:
        return " / ".join(errors[:4])[:400]
    return log.strip()[-400:]


def _try_pandoc(md_text: str, out_path: Path, base_dir: Path) -> bool:
    """Best output when present: real typesetting, proper figure placement."""
    if not shutil.which("pandoc"):
        return False
    engine = next(
        (e for e in ("tectonic", "xelatex", "pdflatex", "weasyprint") if shutil.which(e)),
        None,
    )
    if engine is None:
        return False

    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "draft.md"
        src.write_text(md_text, encoding="utf-8")
        cmd = [
            "pandoc", str(src), "-o", str(out_path),
            f"--pdf-engine={engine}",
            "--resource-path", str(base_dir),
            "--standalone",
        ]
        if engine != "weasyprint":
            cmd += ["-V", "geometry:margin=2cm", "-V", "fontsize=11pt"]
        res = _run(cmd, cwd=str(base_dir))
    if res.returncode != 0 or not out_path.exists():
        raise RenderFailed(f"pandoc failed: {(res.stderr or res.stdout or '').strip()[:400]}")
    return True


def _try_weasyprint(md_text: str, out_path: Path, base_dir: Path, title: str) -> bool:
    if not shutil.which("weasyprint"):
        return False
    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "draft.html"
        src.write_text(markdown_to_html(md_text, title=title), encoding="utf-8")
        # base_dir as the URL base so relative figure paths resolve.
        res = _run(["weasyprint", "--base-url", str(base_dir) + os.sep, str(src), str(out_path)])
    if res.returncode != 0 or not out_path.exists():
        raise RenderFailed(f"weasyprint failed: {(res.stderr or '').strip()[:400]}")
    return True


def _try_libreoffice(md_text: str, out_path: Path, base_dir: Path, title: str) -> bool:
    """Last resort. LibreOffice's HTML import is crude - expect plainer tables
    and looser spacing than the other two backends - but it is installed far
    more widely, and a plain PDF beats no PDF.
    """
    soffice = shutil.which("libreoffice") or shutil.which("soffice")
    if not soffice:
        return False

    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "draft.html"
        src.write_text(markdown_to_html(md_text, title=title), encoding="utf-8")
        res = _run(
            [soffice, "--headless", "--norestore", "--convert-to", "pdf",
             "--outdir", td, str(src)],
            cwd=str(base_dir),
            timeout=300,
        )
        produced = Path(td) / "draft.pdf"
        if not produced.exists():
            raise RenderFailed(
                f"libreoffice produced no PDF: {(res.stderr or res.stdout or '').strip()[:400]}"
            )
        shutil.copyfile(produced, out_path)
    return True


BACKENDS_IN_PREFERENCE_ORDER = ("latex", "pandoc", "weasyprint", "libreoffice")


def render_markdown_to_pdf(
    md_text: str,
    out_path: Path,
    *,
    title: str = "draft",
    base_dir: Path | None = None,
    keep_tex: Path | None = None,
) -> str:
    """Render `md_text` to a PDF at `out_path`. Returns the backend name used.

    `base_dir` is where relative figure paths resolve from - pass the folder
    holding the draft's images, or the call folder. Frontmatter and the
    completeness marker are stripped first.

    `keep_tex` asks the LaTeX backend to write the .tex it compiled to that
    path, so the source of the PDF is preserved and Alon can edit and recompile
    it himself. Only the LaTeX backend honours it; the fallbacks have no LaTeX
    source to keep, and a caller that got a PDF from one of them will find no
    file there. Check the returned backend name before assuming otherwise.

    Raises RenderUnavailable if no backend exists on this host, and RenderFailed
    if one existed but did not produce a PDF. Neither is caught here on purpose:
    the caller must decide whether to publish the markdown alone and say so, and
    that decision should never be made silently.
    """
    out_path = Path(out_path)
    base_dir = Path(base_dir) if base_dir is not None else out_path.parent
    body = strip_internal_markup(md_text)

    attempts: list[tuple[str, str]] = []
    present = False

    # A backend that is installed but broken must not end the chain - it should
    # step aside for the next one. This is not hypothetical: a snap-packaged
    # LibreOffice is on PATH and fails every conversion because its confinement
    # blocks the file it is handed. Detection by `which` cannot see that, so the
    # only reliable signal is having tried.
    for name, fn in (
        ("latex", lambda: _try_latex(body, out_path, base_dir, title, keep_tex)),
        ("pandoc", lambda: _try_pandoc(body, out_path, base_dir)),
        ("weasyprint", lambda: _try_weasyprint(body, out_path, base_dir, title)),
        ("libreoffice", lambda: _try_libreoffice(body, out_path, base_dir, title)),
    ):
        try:
            if fn():
                return name
        except (RenderFailed, subprocess.TimeoutExpired, OSError) as exc:
            present = True
            attempts.append((name, str(exc)))
            continue

    if present:
        detail = "; ".join(f"{n}: {msg}" for n, msg in attempts)
        raise RenderFailed(
            f"every available PDF backend failed ({detail}). If LibreOffice is "
            "installed as a snap, its confinement blocks the conversion - a deb "
            "or a TeX install is the fix."
        )

    raise RenderUnavailable(
        "no PDF backend found on this host. Install a LaTeX engine - "
        "`texlive-xetex` plus `texlive-latex-extra` (xelatex handles the "
        "archive's Hebrew; pdflatex cannot) - which is also what produces the "
        "keepable .tex source. Failing that, pandoc, weasyprint or a non-snap "
        "libreoffice will render, but without LaTeX sources."
    )


def available_backend() -> str | None:
    """Name the backend render_markdown_to_pdf() would try first, or None.

    Cheap enough to call before writing a draft, so a run can warn up front that
    it will not be able to produce the PDF rather than discovering it at the
    last step.

    This answers "is one on PATH", not "does one work" - a snap-packaged
    LibreOffice answers yes here and still fails every conversion. Treat a
    non-None result as "probably", and the return value of an actual render as
    the truth.
    """
    if latex_engine() is not None:
        return "latex"
    if shutil.which("pandoc") and any(
        shutil.which(e) for e in ("tectonic", "xelatex", "pdflatex", "weasyprint")
    ):
        return "pandoc"
    if shutil.which("weasyprint"):
        return "weasyprint"
    if shutil.which("libreoffice") or shutil.which("soffice"):
        return "libreoffice"
    return None
