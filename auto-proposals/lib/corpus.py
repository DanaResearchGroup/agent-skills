"""Deterministic half of the CORPUS.md distillation pipeline.

Walks `_Granted` and `_Archive` (see SAFETY.md #2: everything `_`-prefixed is
read-only forever) and, for every immediate subfolder ("call folder" in the
archive's own naming, one per past proposal), picks the single top-level
file that best represents that proposal, extracts its text into a cache
directory outside the archive via `lib.extract.extract_cached`, and records
the result as a `CorpusEntry`. The actual judgement of *what those past
proposals mean* — the distillation — is a model's job, done later from this
module's output; this module only does the deterministic selection and
extraction.

Read-only with respect to the archive: this module never opens a file under
`root` for writing, and never creates a directory there. The only writes it
performs are inside the caller-supplied `cache_dir`, and those go through
`lib.extract.extract_cached`, which itself refuses (raises `ExtractRefused`)
if `cache_dir` resolves inside the archive root. That check is not
duplicated here — see `extract_cached`'s docstring for why an `assert` isn't
good enough and a real exception is used instead.

Selection prefers files directly inside a call folder, matching the archive's
own convention that supporting material (older drafts, reviewer comments,
budget spreadsheets, ...) lives in subdirectories that are not the proposal
itself. When a folder has no usable top-level candidate at all, selection
falls back exactly one level down (e.g. into a `Part B1/`, `Pre-proposal/` or
`Call/` subdirectory some real folders use) - never deeper than that, and
never into a symlinked subdirectory.

Content-based override: if the chosen file's extracted text turns out to be
"thin" (fewer than `THIN_CHARS` characters - often a cover letter or a
one-page summary that happens to win the filename-based chain), a handful of
the other candidates in the same folder/depth are tried too, and whichever
recovers the most text wins. See `_apply_thin_override` for the exact policy.
"""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass, asdict
from datetime import date, datetime
from pathlib import Path
from typing import Callable

from lib import extract
from lib.paths import is_conflicted_copy


@dataclass
class CorpusEntry:
    corpus: str          # "_Granted" or "_Archive"
    folder: str           # folder name, byte-for-byte
    source: Path | None    # the file chosen to represent this proposal
    reason: str            # why that file was chosen, or why none was
    indexed: bool
    chars: int
    cache_path: Path | None   # extracted text, in the cache dir
    thin: bool = False        # True if the FINAL chosen entry's text is still
                               # under THIN_CHARS (see _apply_thin_override)


# ---------------------------------------------------------------------------
# Thin-content override thresholds
# ---------------------------------------------------------------------------
#
# THIN_CHARS is the default; AUTO_PROPOSALS_THIN_CHARS overrides it, read
# fresh on every call (same pattern as lib.integrity's
# AUTO_PROPOSALS_HASH_MAX_BYTES) so tests can swap it per case without
# needing to reload this module.

THIN_CHARS = 2000

# Never try more than this many alternative candidates per thin folder - both
# to bound run time over a large archive and to keep the extractor call count
# testable/predictable.
MAX_ALTERNATIVES = 6


def _thin_chars() -> int:
    raw = os.environ.get("AUTO_PROPOSALS_THIN_CHARS")
    if not raw:
        return THIN_CHARS
    try:
        return int(raw)
    except ValueError:
        return THIN_CHARS


# ---------------------------------------------------------------------------
# Date parsing
# ---------------------------------------------------------------------------
#
# Four filename date formats, in a fixed order so the same filename always
# parses the same way. The two "." formats and the two "-" formats are
# distinguished from each other purely by which group is 4 digits vs 2 -
# `2021.03.15` can only match YYYY.MM.DD (no `\d{2}\.` prefix lines up with a
# non-digit lookbehind), `15.03.2021` can only match DD.MM.YYYY, so there is
# no ambiguity to resolve by trying one format before another.

_DATE_PATTERNS: list[tuple[re.Pattern, str]] = [
    (re.compile(r"(?<!\d)\d{2}\.\d{2}\.\d{4}(?!\d)"), "%d.%m.%Y"),
    (re.compile(r"(?<!\d)\d{4}\.\d{2}\.\d{2}(?!\d)"), "%Y.%m.%d"),
    (re.compile(r"(?<!\d)\d{2}-\d{2}-\d{4}(?!\d)"), "%d-%m-%Y"),
    (re.compile(r"(?<!\d)\d{4}-\d{2}-\d{2}(?!\d)"), "%Y-%m-%d"),
]


def parse_date_from_filename(name: str) -> date | None:
    """Return the newest valid calendar date found anywhere in `name` across
    the four supported formats, or None if no substring parses as a real
    date. A filename with more than one date-looking substring (e.g. both a
    draft date and a submission date) resolves to the latest one - the same
    "newest wins" rule this module applies everywhere else.
    """
    candidates: list[date] = []
    for pattern, fmt in _DATE_PATTERNS:
        for m in pattern.finditer(name):
            try:
                candidates.append(datetime.strptime(m.group(0), fmt).date())
            except ValueError:
                continue
    return max(candidates) if candidates else None


# ---------------------------------------------------------------------------
# Top-level (non-recursive) directory listing, with the same skip rules as
# lib.extract's corpus/input scanning: dotfiles, Office lock files, Dropbox
# conflicted copies, and symlinks (never followed - a symlink planted inside
# the archive must not be able to pull selection onto a file outside it).
# ---------------------------------------------------------------------------

def _should_skip_name(name: str) -> bool:
    if name.startswith("."):
        return True
    if name.startswith("~$"):
        return True
    if is_conflicted_copy(name):
        return True
    return False


def _iter_top_level_files(folder: Path) -> list[Path]:
    try:
        entries = list(os.scandir(folder))
    except OSError:
        return []
    result: list[Path] = []
    for entry in sorted(entries, key=lambda e: e.name):
        try:
            if entry.is_symlink():
                continue
            if not entry.is_file(follow_symlinks=False):
                continue
        except OSError:
            continue
        if _should_skip_name(entry.name):
            continue
        result.append(Path(entry.path))
    return result


def _iter_one_level_down_files(folder: Path) -> list[Path]:
    """Files found exactly one directory below `folder` - i.e. directly
    inside `folder`'s immediate subdirectories, applying the same skip rules
    `_iter_top_level_files` applies at the top level. A symlinked
    subdirectory is never descended into (same "never follow a symlink into
    something outside our control" rule as for files), and nothing more than
    one level down is ever scanned.
    """
    try:
        entries = list(os.scandir(folder))
    except OSError:
        return []
    result: list[Path] = []
    for entry in sorted(entries, key=lambda e: e.name):
        try:
            if entry.is_symlink():
                continue
            if not entry.is_dir(follow_symlinks=False):
                continue
        except OSError:
            continue
        if _should_skip_name(entry.name):
            continue
        result.extend(_iter_top_level_files(Path(entry.path)))
    return result


# ---------------------------------------------------------------------------
# Selection chain
# ---------------------------------------------------------------------------

def _select_latest_or_by_mtime(files: list[Path], ext_desc: str) -> tuple[Path | None, str | None]:
    """Shared logic for both the PDF and DOCX rungs: prefer the latest
    date-named file; failing that, the most recently modified file of that
    extension. Returns (None, None) if `files` is empty, letting the caller
    fall through to the next rung.
    """
    dated = [(f, parse_date_from_filename(f.name)) for f in files]
    dated = [(f, d) for f, d in dated if d is not None]
    if dated:
        picked, picked_date = max(dated, key=lambda t: t[1])
        return picked, f"latest date-named {ext_desc}: {picked.name!r} (parsed date {picked_date.isoformat()})"

    if files:
        picked = max(files, key=lambda p: p.stat().st_mtime)
        return picked, (
            f"no date-named {ext_desc} found ({len(files)} {ext_desc}(s) present); "
            f"picked most recently modified: {picked.name!r}"
        )

    return None, None


def _pick_from_files(files: list[Path]) -> tuple[Path | None, str | None]:
    """Run the four-rung extension-preference chain over an already-gathered
    file list: latest date-named PDF -> any PDF by mtime -> latest
    date-named DOCX -> any DOCX by mtime -> latest date-named DOC -> any DOC
    by mtime -> (None, None). Shared by the top-level and one-level-down
    passes in `pick_source`.
    """
    pdfs = [f for f in files if f.suffix.lower() == ".pdf"]
    picked, reason = _select_latest_or_by_mtime(pdfs, "PDF")
    if picked is not None:
        return picked, reason

    docxs = [f for f in files if f.suffix.lower() == ".docx"]
    picked, reason = _select_latest_or_by_mtime(docxs, "DOCX")
    if picked is not None:
        return picked, reason

    # `_Archive/` spans many years, so a good number of the older proposals are
    # still in the pre-2007 binary .doc format. Without this rung they would be
    # reported as having no usable file at all, which reads as "nothing here"
    # when in fact the proposal is sitting right there, just in an old format
    # that extract.py handles perfectly well via catdoc.
    docs = [f for f in files if f.suffix.lower() == ".doc"]
    picked, reason = _select_latest_or_by_mtime(docs, "DOC")
    if picked is not None:
        return picked, reason

    return None, None


def _ordered_candidates_from_files(files: list[Path]) -> list[Path]:
    """Every file in `files`, in the same rung / date-then-mtime preference
    order `_pick_from_files` would consider them in, but returning the full
    ordered list instead of stopping at the first hit. Used to find
    alternatives for the thin-content override (see `_apply_thin_override`).
    """
    result: list[Path] = []
    for suffix in (".pdf", ".docx", ".doc"):
        ext_files = [f for f in files if f.suffix.lower() == suffix]
        dated = [(f, parse_date_from_filename(f.name)) for f in ext_files]
        dated = [(f, d) for f, d in dated if d is not None]
        dated.sort(key=lambda t: t[1], reverse=True)
        dated_files = {f for f, _ in dated}
        undated = [f for f in ext_files if f not in dated_files]
        undated.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        result.extend(f for f, _ in dated)
        result.extend(undated)
    return result


def pick_source(folder: Path) -> tuple[Path | None, str]:
    """Select the single file that best represents the proposal in `folder`,
    per the four-rung chain in this module's docstring / the task spec:
    latest date-named PDF -> any PDF by mtime -> latest date-named DOCX ->
    any DOCX by mtime -> latest date-named DOC -> any DOC by mtime.

    If nothing at the top level of `folder` matches, the same chain is
    re-run over files found exactly one directory down (e.g. inside a
    `Part B1/` or `Pre-proposal/` subdirectory some real folders use).
    Nothing deeper than that one extra level is ever searched, and a
    symlinked subdirectory is never descended into.
    """
    folder = Path(folder)

    top_files = _iter_top_level_files(folder)
    picked, reason = _pick_from_files(top_files)
    if picked is not None:
        return picked, reason

    depth2_files = _iter_one_level_down_files(folder)
    picked, reason = _pick_from_files(depth2_files)
    if picked is not None:
        subdir_name = picked.parent.name + "/"
        return picked, f"no top-level candidate; selected from subdirectory {subdir_name!r}: {reason}"

    return None, (
        f"no usable .pdf, .docx or .doc file found in folder {folder.name!r}, "
        "either at the top level or one directory down in an immediate "
        "subdirectory (dotfiles, Office lock files, Dropbox conflicted copies, "
        "and symlinks/symlinked subdirectories are skipped; nothing more than "
        "one level down is ever searched)"
    )


# ---------------------------------------------------------------------------
# Thin-content override
# ---------------------------------------------------------------------------

def _apply_thin_override(
    *,
    folder: Path,
    primary_source: Path,
    primary_reason: str,
    primary_extraction,
    primary_cache_path: Path | None,
    cache_dir: Path,
    timeout: int,
) -> tuple[Path, str, int, Path | None, bool]:
    """After the primary pick has been extracted, check whether its text is
    "thin" (fewer than `THIN_CHARS` characters) and, if so, try up to
    `MAX_ALTERNATIVES` other candidates from the same folder/depth the
    primary pick came from to see whether one of them recovers substantially
    more text.

    - If some alternative recovers at least `THIN_CHARS` characters (which,
      since the primary is thin, is automatically more than the primary
      recovered), it wins outright: the entry switches to that alternative.
    - If every candidate tried (primary plus every alternative) is still
      thin, the ORIGINAL primary pick is kept regardless of which
      alternative happened to recover the most text - a slightly-less-thin
      alternative is not a meaningfully better answer, and switching to one
      would just hide that this folder likely has no substantive proposal
      text at all.

    Returns (source, reason, chars, cache_path, thin) for the final entry.
    Never calls the extractor more than `MAX_ALTERNATIVES` times.
    """
    threshold = _thin_chars()
    if primary_extraction.chars >= threshold:
        return primary_source, primary_reason, primary_extraction.chars, primary_cache_path, False

    if primary_source.parent == folder:
        sibling_files = _iter_top_level_files(folder)
    else:
        sibling_files = _iter_one_level_down_files(folder)

    alternatives = [f for f in _ordered_candidates_from_files(sibling_files) if f != primary_source]
    alternatives = alternatives[:MAX_ALTERNATIVES]

    best_source: Path | None = None
    best_chars = -1
    best_cache_path: Path | None = None
    for alt in alternatives:
        alt_extraction = extract.extract_cached(alt, cache_dir, timeout=timeout)
        if alt_extraction.ok and alt_extraction.chars > best_chars:
            alt_key = extract.cache_key(alt)
            candidate_alt_cache = cache_dir / f"{alt_key}.txt"
            best_source = alt
            best_chars = alt_extraction.chars
            best_cache_path = candidate_alt_cache if candidate_alt_cache.exists() else None

    if best_source is not None and best_chars >= threshold:
        new_reason = (
            f"{primary_reason} recovered only {primary_extraction.chars} chars "
            f"(below the {threshold}-char threshold); using {best_source.name!r} "
            f"instead, which recovered {best_chars} chars"
        )
        return best_source, new_reason, best_chars, best_cache_path, False

    new_reason = (
        f"{primary_reason} recovered only {primary_extraction.chars} chars "
        f"(below the {threshold}-char threshold), and no alternative candidate "
        "in this folder recovered enough text to clear it either; this folder "
        "may hold no substantive proposal text - a human should check"
    )
    return primary_source, new_reason, primary_extraction.chars, primary_cache_path, True


# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------

def build_inventory(
    root: Path,
    *,
    corpora: tuple[str, ...] = ("_Granted", "_Archive"),
    cache_dir: Path,
    limit: int | None = None,
    timeout: int = 300,
    progress: Callable[[str], None] | None = None,
) -> list[CorpusEntry]:
    """Walk each corpus folder's immediate subdirectories, pick a source for
    each, extract it into `cache_dir`, and record the result.

    Read-only with respect to `root`: the only writes this function performs
    are those `lib.extract.extract_cached` makes inside `cache_dir`, and that
    function refuses outright (raises `ExtractRefused`, not caught here - a
    structural safety violation must abort the run, not be swallowed as a
    per-folder failure) if `cache_dir` resolves inside the archive root.

    Robust to a single folder's selection or extraction blowing up for any
    other reason: that folder is recorded as an unindexed entry with the
    error in its `reason`, and the walk continues.

    `limit`, if given, caps the total number of folders processed across all
    of `corpora` combined - useful for a quick dry run over a ~100-folder
    archive.

    `timeout` (seconds) is threaded through to every `extract.extract_cached`
    call this function makes, including alternates tried by the thin-content
    override; see `lib.extract.extract_cached` / `lib.extract.extract` for
    what it bounds (subprocess wall-clock time, or the in-process docx/msg
    watchdog).
    """
    root = Path(root)
    cache_dir = Path(cache_dir)
    entries: list[CorpusEntry] = []
    processed = 0

    for corpus in corpora:
        corpus_dir = root / corpus
        try:
            folder_names = sorted(
                e.name for e in os.scandir(corpus_dir) if e.is_dir(follow_symlinks=False)
            )
        except OSError as exc:
            if progress is not None:
                progress(f"{corpus}: could not list {corpus_dir}: {exc}")
            continue

        for folder_name in folder_names:
            if limit is not None and processed >= limit:
                return entries

            folder = corpus_dir / folder_name
            processed += 1
            if progress is not None:
                progress(f"[{processed}] {corpus}/{folder_name} ...")

            try:
                source, reason = pick_source(folder)
                if source is None:
                    entries.append(CorpusEntry(
                        corpus=corpus, folder=folder_name, source=None, reason=reason,
                        indexed=False, chars=0, cache_path=None, thin=False,
                    ))
                    if progress is not None:
                        progress(f"    unindexed: {reason}")
                    continue

                extraction = extract.extract_cached(source, cache_dir, timeout=timeout)
                key = extract.cache_key(source)
                candidate_cache_path = cache_dir / f"{key}.txt"
                cache_path = candidate_cache_path if candidate_cache_path.exists() else None

                if extraction.ok:
                    final_source, final_reason, final_chars, final_cache_path, thin = _apply_thin_override(
                        folder=folder,
                        primary_source=source,
                        primary_reason=reason,
                        primary_extraction=extraction,
                        primary_cache_path=cache_path,
                        cache_dir=cache_dir,
                        timeout=timeout,
                    )
                    entries.append(CorpusEntry(
                        corpus=corpus, folder=folder_name, source=final_source, reason=final_reason,
                        indexed=True, chars=final_chars, cache_path=final_cache_path, thin=thin,
                    ))
                    if progress is not None:
                        thin_note = " [thin]" if thin else ""
                        progress(f"    indexed: {final_source.name} ({final_chars} chars){thin_note}")
                else:
                    combined_reason = f"{reason}; extraction failed: {extraction.note}"
                    entries.append(CorpusEntry(
                        corpus=corpus, folder=folder_name, source=source, reason=combined_reason,
                        indexed=False, chars=0, cache_path=cache_path, thin=False,
                    ))
                    if progress is not None:
                        progress(f"    unindexed (extraction failed): {extraction.note}")
            except extract.ExtractRefused:
                # A structural safety violation (e.g. cache_dir inside the
                # archive root) - never swallow this as a per-folder failure.
                raise
            except Exception as exc:  # noqa: BLE001 - one bad folder must not abort the walk
                entries.append(CorpusEntry(
                    corpus=corpus, folder=folder_name, source=None,
                    reason=f"unexpected error while processing folder: {exc}",
                    indexed=False, chars=0, cache_path=None, thin=False,
                ))
                if progress is not None:
                    progress(f"    ERROR: {exc}")

    return entries


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def _md_escape(s: str) -> str:
    return s.replace("|", "\\|")


def render_inventory_md(entries: list[CorpusEntry]) -> str:
    """Compact table plus explicit "Unindexed" and "Thin" sections. Every
    folder that was walked appears somewhere in this output - an unindexed
    folder is never just dropped (SAFETY.md's "never silently truncate
    coverage" rule applies here too, even though this module never writes to
    the archive), and an indexed-but-thin folder is flagged separately so a
    human can spot-check it.
    """
    indexed = [e for e in entries if e.indexed]
    unindexed = [e for e in entries if not e.indexed]
    thin = [e for e in entries if e.indexed and e.thin]

    lines: list[str] = []
    lines.append("# Corpus inventory")
    lines.append("")
    lines.append(f"Folders scanned: {len(entries)}. Indexed: {len(indexed)}. Unindexed: {len(unindexed)}.")
    lines.append("")
    lines.append("| corpus | folder | source | chars | cache |")
    lines.append("|---|---|---|---|---|")
    for e in entries:
        source_str = _md_escape(e.source.name) if e.source is not None else "-"
        cache_str = _md_escape(str(e.cache_path)) if e.cache_path is not None else "-"
        lines.append(
            f"| {_md_escape(e.corpus)} | {_md_escape(e.folder)} | {source_str} | "
            f"{e.chars} | {cache_str} |"
        )
    lines.append("")

    lines.append("## Unindexed")
    lines.append("")
    if not unindexed:
        lines.append("(none - every folder scanned yielded an indexed source.)")
    else:
        for e in unindexed:
            lines.append(f"- **{e.corpus}/{e.folder}**: {e.reason}")
    lines.append("")

    lines.append("## Thin")
    lines.append("")
    if not thin:
        lines.append("(none - every indexed folder recovered non-thin text.)")
    else:
        for e in thin:
            lines.append(f"- **{e.corpus}/{e.folder}** ({e.chars} chars): {e.reason}")
    lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _entry_to_json(e: CorpusEntry) -> dict:
    d = asdict(e)
    d["source"] = str(e.source) if e.source is not None else None
    d["cache_path"] = str(e.cache_path) if e.cache_path is not None else None
    return d


def _main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(
        prog="python3 -m lib.corpus",
        description="Build the deterministic corpus inventory over past proposals.",
    )
    parser.add_argument("--root", required=True, help="proposals archive root")
    parser.add_argument("--cache-dir", required=True, help="directory to cache extracted text in (must be outside --root)")
    parser.add_argument(
        "--corpus", action="append", default=None,
        help="corpus folder name to scan (repeatable); default: _Granted and _Archive",
    )
    parser.add_argument("--limit", type=int, default=None, help="cap the number of folders processed")
    parser.add_argument(
        "--timeout", type=int, default=300,
        help="per-extraction wall-clock timeout in seconds, for every extractor call this run makes "
             "(pdftotext/catdoc subprocess, libreoffice fallback, and the in-process python-docx/"
             "extract_msg watchdog); default: 300",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON instead of markdown")
    args = parser.parse_args(argv)

    corpora = tuple(args.corpus) if args.corpus else ("_Granted", "_Archive")

    def progress(msg: str) -> None:
        print(msg, file=sys.stderr, flush=True)

    entries = build_inventory(
        Path(args.root),
        corpora=corpora,
        cache_dir=Path(args.cache_dir),
        limit=args.limit,
        timeout=args.timeout,
        progress=progress,
    )

    if args.json:
        print(json.dumps([_entry_to_json(e) for e in entries], ensure_ascii=False, indent=2))
    else:
        print(render_inventory_md(entries))

    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
