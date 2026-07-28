"""Owned-path grammar and containment checks.

The proposals archive is a live, un-versioned Dropbox tree that syncs across
several hosts and holds years of submitted / granted funding proposals.
Every guard in this module exists to stop one specific way a well-meaning
model could turn a single bad path string into a silent, irreversible loss:
escaping the archive root, following a symlink planted (accidentally or not)
inside the tree, or writing into a corpus folder that isn't ours to touch.
See SAFETY.md sections 2, 5 and 6 for the normative contract this implements.
"""

from __future__ import annotations

import os
import re
import socket
import subprocess
from datetime import date
from pathlib import Path


# ---------------------------------------------------------------------------
# Root
# ---------------------------------------------------------------------------

def _default_root() -> Path:
    return Path(os.environ.get("AUTO_PROPOSALS_ROOT", "~/Dropbox/Work/Proposals")).expanduser()


# Resolved once at import time so every caller in this process agrees on the
# same root. Callers that need a fresh read of the env var (tests swapping
# AUTO_PROPOSALS_ROOT between cases) should call _default_root() directly or
# construct their own Path and pass it explicitly to the functions below.
PROPOSALS_ROOT = _default_root()


class PathRefused(Exception):
    """Raised whenever a requested path fails the owned-path grammar or a
    containment/symlink check. The message is meant to be shown to a human
    (or an agent) verbatim, so it always explains *why*, not just *that*.
    """


# ---------------------------------------------------------------------------
# Grammar
# ---------------------------------------------------------------------------
#
#   OPEN.md
#   CORPUS.md
#   <call>/topics.md
#   <call>/topics-v<N>.md
#   <call>/outlines/<Tn>-<slug>.md
#   <call>/outlines/<Tn>-<slug>-v<N>.md
#   <call>/drafts/YYYY.MM.DD <letter> <rest>.md
#
# <call>   : top-level dir, not starting with "_" or "."
# <Tn>     : "T" + digits
# <slug>   : [a-z0-9-]+
# <N>      : positive integer (no leading zero beyond a bare "0", but we just
#            require digits and reject "0" itself since it is not "positive")
# YYYY.MM.DD : four-digit year, two-digit month, two-digit day, dot-separated
# <letter> : a single lowercase ascii letter a-z; "a" for the first draft
#            produced on a given date, incrementing for each further draft
#            of the same <rest> produced on that same date (see
#            next_draft_rel() below)
# <rest>   : non-empty; may contain spaces and non-ascii characters

_CALL = r"[^./_][^/]*"  # first char not "." or "_"; rest anything but "/"
_TN = r"T[0-9]+"
_SLUG = r"[a-z0-9-]+"
_N = r"[1-9][0-9]*"
_DRAFT_DATE = r"[0-9]{4}\.[0-9]{2}\.[0-9]{2}"
_DRAFT_LETTER = r"[a-z]"
_DRAFT_REST = r"[^/]+"

_ROOT_LEVEL_RE = re.compile(r"^(OPEN|CORPUS)\.md$")
_TOPICS_RE = re.compile(rf"^({_CALL})/topics\.md$")
_TOPICS_V_RE = re.compile(rf"^({_CALL})/topics-v({_N})\.md$")
_OUTLINE_RE = re.compile(rf"^({_CALL})/outlines/({_TN})-({_SLUG})\.md$")
_OUTLINE_V_RE = re.compile(rf"^({_CALL})/outlines/({_TN})-({_SLUG})-v({_N})\.md$")
_DRAFT_RE = re.compile(rf"^({_CALL})/drafts/({_DRAFT_DATE}) ({_DRAFT_LETTER}) ({_DRAFT_REST})\.md$")

# Basename-only version of the draft pattern (no call/drafts/ prefix), used
# by next_draft_rel() to scan an existing drafts/ directory listing.
_DRAFT_BASENAME_RE = re.compile(rf"^({_DRAFT_DATE}) ({_DRAFT_LETTER}) ({_DRAFT_REST})\.md$")

_REGENERATE_RE = _ROOT_LEVEL_RE
_CREATE_PATTERNS = (_TOPICS_RE, _TOPICS_V_RE, _OUTLINE_RE, _OUTLINE_V_RE, _DRAFT_RE)


def _call_name_from_rel(rel: str) -> str | None:
    parts = rel.split("/")
    return parts[0] if parts else None


def _call_ok(call: str) -> bool:
    return bool(call) and not call.startswith("_") and not call.startswith(".")


def write_mode_for(rel: str) -> str:
    """Classify a candidate relative path per the grammar in SAFETY.md #2.

    Returns "create" for topics/outlines/drafts artifacts, "regenerate" for
    the two root-level roster files (OPEN.md / CORPUS.md), or raises
    PathRefused for anything else. This function is deliberately
    string-only; resolve_owned() does the filesystem-level (symlink,
    containment) checks separately.
    """
    if _REGENERATE_RE.match(rel):
        return "regenerate"

    for pattern in _CREATE_PATTERNS:
        m = pattern.match(rel)
        if m:
            call = m.group(1)
            if not _call_ok(call):
                raise PathRefused(
                    f"call folder {call!r} is not an owned target "
                    "(top-level call folders may not start with '_' or '.')"
                )
            return "create"

    raise PathRefused(f"{rel!r} does not match the owned-path grammar")


def resolve_owned(root: Path, rel: str) -> Path:
    """Validate `rel` against the owned-path grammar and containment rules,
    and return the absolute (unresolved) path to write to.

    We deliberately return root / rel rather than the realpath()-resolved
    path: if the final path component does not yet exist that's fine (it's
    what we're about to create), but if we resolved it we could silently
    follow a symlink planted at the last moment between the check and the
    write. Every existing component - including the final one - is proven
    not to be a symlink individually before we hand the path back.
    """
    root = Path(root)

    if rel is None or rel == "":
        raise PathRefused("empty path")

    # Reject absolute paths and any ".." component before we even look at
    # the grammar - these are the classic escape vectors and should never
    # reach a regex.
    candidate = Path(rel)
    if candidate.is_absolute():
        raise PathRefused(f"{rel!r} is an absolute path, refused")
    if any(part in ("..", "") for part in candidate.parts):
        if any(part == ".." for part in candidate.parts):
            raise PathRefused(f"{rel!r} contains '..', refused")
        raise PathRefused(f"{rel!r} contains an empty path component, refused")

    # Normalise to posix-style forward slashes for the grammar regexes.
    posix_rel = rel.replace(os.sep, "/") if os.sep != "/" else rel

    # Grammar check (raises PathRefused with a clear reason on failure).
    mode = write_mode_for(posix_rel)

    # For "create" targets the call folder is never created by us - it only
    # ever comes from a human dropping the call's material into the archive
    # (SAFETY.md #2). The grammar regex is lenient about the call component
    # (it merely rejects a leading "." or "_"), which admits look-alike
    # folder names a naive filesystem walk would treat as distinct from the
    # real one: trailing spaces, trailing dots, or an NFD-normalised twin of
    # an NFC folder name. Since we never create this directory ourselves,
    # requiring it to already exist and match an existing entry byte-for-byte
    # closes that door entirely - no unicode-normalisation or
    # case-insensitive comparison is "good enough" here.
    if mode == "create":
        call = _call_name_from_rel(posix_rel)
        try:
            entries = os.listdir(root)
        except OSError as exc:
            raise PathRefused(f"could not list {root}: {exc}") from exc
        if call not in entries:
            near = [e for e in entries if e.strip().rstrip(".").casefold() == call.strip().rstrip(".").casefold()]
            detail = f"; near-matches found: {near}" if near else ""
            raise PathRefused(
                f"call folder {call!r} does not exist byte-for-byte under {root} "
                "(auto-proposals never creates call folders)" + detail
            )

    # Resolve the real root once; every existing component of the candidate
    # path must land, after symlink resolution, inside this real root.
    real_root = root.resolve()

    # Walk the path component by component from root, refusing if any
    # existing component - including the last - is a symlink.
    target = root
    for part in candidate.parts:
        target = target / part
        if os.path.islink(target):
            raise PathRefused(f"path component {target} is a symlink, refused")

    # Containment: whatever of the path exists must resolve inside real_root.
    # Walk up from the target until we find an existing ancestor, then
    # confirm that ancestor's realpath is contained in real_root.
    probe = target
    while not probe.exists():
        parent = probe.parent
        if parent == probe:
            break
        probe = parent
    try:
        real_probe = probe.resolve()
    except OSError as exc:
        raise PathRefused(f"could not resolve {probe}: {exc}") from exc

    try:
        real_probe.relative_to(real_root)
    except ValueError:
        raise PathRefused(
            f"{rel!r} escapes the owned root after resolution ({real_probe} not under {real_root})"
        ) from None

    return target


def next_draft_rel(root: Path, call: str, base_name: str, today: date) -> str:
    """Pick the call-relative path for the next DRAFT version of `base_name`.

    Filenames follow `<call>/drafts/YYYY.MM.DD <letter> <base_name>.md`. The
    chokepoint that calls this never overwrites an existing draft - each new
    version is a brand-new, letter-suffixed file.

    Design choice (non-obvious, stated explicitly): the letter sequence is
    scoped per (date, base_name) pair, not per call or per day across the
    whole call. Two different topics drafted on the same date each start
    their own lettering at "a"; the same topic drafted again on a later date
    also resets to "a" for that new date. `today` must be supplied by the
    caller (never computed here) so this function stays deterministic and
    testable.

    Raises PathRefused if the highest existing letter for that (date,
    base_name) pair is already "z" - 26 versions of one draft in one day
    means something is wrong, and we refuse rather than roll over to "aa"
    or silently overwrite.
    """
    date_str = today.strftime("%Y.%m.%d")
    drafts_dir = Path(root) / call / "drafts"
    try:
        entries = os.listdir(drafts_dir)
    except OSError:
        entries = []

    highest: str | None = None
    for name in entries:
        m = _DRAFT_BASENAME_RE.match(name)
        if not m:
            continue
        file_date, letter, rest = m.group(1), m.group(2), m.group(3)
        if file_date != date_str or rest != base_name:
            continue
        if highest is None or letter > highest:
            highest = letter

    if highest is None:
        next_letter = "a"
    elif highest == "z":
        raise PathRefused(
            f"26 draft versions of {base_name!r} already exist for {date_str} "
            f"under {drafts_dir} (a..z); refusing to roll over - something is wrong"
        )
    else:
        next_letter = chr(ord(highest) + 1)

    return f"{call}/drafts/{date_str} {next_letter} {base_name}.md"


# ---------------------------------------------------------------------------
# Conflicted copies
# ---------------------------------------------------------------------------

# Dropbox's own English pattern: "<name> (<who>'s conflicted copy <date>).<ext>"
# Localised variants (including Hebrew) wrap the same idea in different words,
# so the authoritative rule is the case-insensitive substring catch-all below;
# the parenthesised pattern is just a stricter, more explicit first check.
_CONFLICTED_COPY_RE = re.compile(r"\(.*conflicted copy.*\)", re.IGNORECASE)


def is_conflicted_copy(name: str) -> bool:
    """True if `name` (a basename) looks like a Dropbox conflicted-copy file.

    Filtering these out of corpus scans is fine (they're just duplicated
    source material - SAFETY.md #5). Finding one next to an *owned* artifact
    is not something we may filter: it might be the copy holding Alon's
    actual selection, and silently picking the other one is a decision-losing
    bug, not a filtering nicety. Hence this function is deliberately
    permissive (broad substring match) rather than trying to be clever about
    which copy "looks newer".
    """
    if _CONFLICTED_COPY_RE.search(name):
        return True
    return "conflicted copy" in name.lower()


def owned_artifact_conflicts(call_dir: Path) -> list[Path]:
    """List every conflicted-copy sibling of an owned artifact within one
    call folder (top level, outlines/, drafts/). A non-empty result means
    that call is FROZEN: no further stage work until a human reconciles it.
    """
    call_dir = Path(call_dir)
    found: list[Path] = []
    for sub in (call_dir, call_dir / "outlines", call_dir / "drafts"):
        try:
            entries = list(os.scandir(sub))
        except OSError:
            continue
        for entry in entries:
            try:
                if entry.is_file(follow_symlinks=False) and is_conflicted_copy(entry.name):
                    found.append(Path(entry.path))
            except OSError:
                continue
    return sorted(found)


def root_artifact_conflicts(root: Path, stem: str) -> list[Path]:
    """List conflicted-copy siblings of a root-level owned artifact (OPEN.md,
    CORPUS.md) sitting directly in the archive root.

    `owned_artifact_conflicts` only ever scans inside a call folder (and its
    outlines/drafts subfolders); it never looks at the archive root itself,
    so a `CORPUS (Alon's conflicted copy 2026-07-27).md` sitting next to
    CORPUS.md at the top level was previously invisible to the freeze check.
    `stem` is the artifact's basename without extension, e.g. "CORPUS".
    """
    root = Path(root)
    found: list[Path] = []
    try:
        entries = list(os.scandir(root))
    except OSError:
        return found
    for entry in entries:
        try:
            if not entry.is_file(follow_symlinks=False):
                continue
            name = entry.name
            if not is_conflicted_copy(name):
                continue
            if not name.startswith(stem):
                continue
            found.append(Path(entry.path))
        except OSError:
            continue
    return sorted(found)


def is_call_dir(p: Path) -> bool:
    """True if `p` is a top-level call directory: a directory whose name does
    not start with '_' (reserved corpora like _Granted, _Archive, _resources)
    or '.' (dotfiles / .obsidian)."""
    p = Path(p)
    return p.is_dir() and not p.name.startswith("_") and not p.name.startswith(".")


# ---------------------------------------------------------------------------
# Host / sync gates
# ---------------------------------------------------------------------------

def publish_host_ok() -> tuple[bool, str]:
    """Writes are restricted to one designated host because Dropbox does not
    propagate locks: two hosts racing to create the same "missing" file
    produce a conflicted copy, not one winner (SAFETY.md #6)."""
    expected = os.environ.get("AUTO_PROPOSALS_PUBLISH_HOST", "HL")
    actual = socket.gethostname()
    if actual == expected:
        return True, f"host {actual!r} matches AUTO_PROPOSALS_PUBLISH_HOST"
    return False, f"host {actual!r} is not the designated publish host ({expected!r}); read-only"


def dropbox_synced() -> tuple[bool, str]:
    """Before publishing, `dropbox status` must report the tree is fully
    synced. Acting on a partially-materialised tree risks generating an
    artifact against half a call's worth of source material."""
    try:
        result = subprocess.run(
            ["dropbox", "status"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except FileNotFoundError:
        return False, (
            "dropbox CLI not present - sync state unknown, refusing to publish "
            "(cron/minimal-PATH environments must not fail open; set "
            "AUTO_PROPOSALS_ALLOW_UNSYNCED=1 to opt out of this gate)"
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return False, f"could not run 'dropbox status': {exc}"

    output = (result.stdout or "").strip()
    if output.startswith("Up to date"):
        return True, output
    return False, f"dropbox status not clean: {output!r}"
