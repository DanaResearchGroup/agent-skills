"""Render a markdown draft to PDF.

Alon reads drafts on screen and on paper, and a funding draft that only exists
as markdown is one he cannot hand to a colleague. So every draft is published
twice: the markdown, which stays the editable source of truth, and a PDF
rendering of it.

This module deliberately does NOT pick one PDF toolchain and depend on it. The
skill runs on several of Alon's machines and inside cron, and the available
converters differ between them. Instead it tries a chain of backends in quality
order and reports which one it used, so the caller can say so in its run report.

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
    artifact, leaving the document a reader should see."""
    body = _FRONTMATTER_RE.sub("", md_text, count=1)
    return _MARKER_RE.sub("", body).strip() + "\n"


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


BACKENDS_IN_PREFERENCE_ORDER = ("pandoc", "weasyprint", "libreoffice")


def render_markdown_to_pdf(
    md_text: str,
    out_path: Path,
    *,
    title: str = "draft",
    base_dir: Path | None = None,
) -> str:
    """Render `md_text` to a PDF at `out_path`. Returns the backend name used.

    `base_dir` is where relative figure paths resolve from - pass the folder
    holding the draft's images, or the call folder. Frontmatter and the
    completeness marker are stripped first.

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
            "or a pandoc/weasyprint install is the fix."
        )

    raise RenderUnavailable(
        "no PDF backend found on this host. Install one of: pandoc (plus "
        "tectonic/xelatex), weasyprint, or libreoffice. Preferred is pandoc + "
        "tectonic for typeset output with proper figure placement."
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
    if shutil.which("pandoc") and any(
        shutil.which(e) for e in ("tectonic", "xelatex", "pdflatex", "weasyprint")
    ):
        return "pandoc"
    if shutil.which("weasyprint"):
        return "weasyprint"
    if shutil.which("libreoffice") or shutil.which("soffice"):
        return "libreoffice"
    return None
