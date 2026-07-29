"""The single chokepoint every write to the proposals archive must pass
through (SAFETY.md #3, #4).

L1 (harness permissions) is enforced outside this process. This module is
L2: even if something upstream of us decided to write, everything actually
touching the filesystem happens here, through a small number of narrow,
auditable operations - create (refuse if exists), append (never rewrite
existing bytes), and regenerate (compare-and-swap on two specific files
only). Nothing in this module ever deletes anything that wasn't a temp file
it created itself in this call.
"""

from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
import re
import sys
import time
import uuid
from pathlib import Path

from lib.paths import (
    PathRefused,
    dropbox_synced,
    companion_md_rel_for,
    is_draft_companion,
    is_figure,
    owned_artifact_conflicts,
    publish_host_ok,
    resolve_owned,
    root_artifact_conflicts,
    write_mode_for,
)


_TMP_PREFIX = ".auto-proposals.tmp."


# ---------------------------------------------------------------------------
# Safety net: this module must never delete anything except its own temp
# files. Every removal in this file goes through this helper so a future
# edit can't accidentally introduce a stray os.remove() on a real artifact.
# ---------------------------------------------------------------------------

def _assert_removable_tmp_name(name: str) -> None:
    if not name.startswith(_TMP_PREFIX):
        raise AssertionError(
            f"refusing to remove non-temp file: {name!r} "
            "(publish.py may only delete its own .auto-proposals.tmp.* files)"
        )


def _remove_tmp_dirfd(dir_fd: int, name: str) -> None:
    _assert_removable_tmp_name(name)
    try:
        os.unlink(name, dir_fd=dir_fd)
    except FileNotFoundError:
        pass


def _write_all(fd: int, data: bytes) -> None:
    """os.write() is permitted by POSIX to write fewer bytes than asked -
    a signal interruption or a filesystem/quota boundary mid-call is enough.
    A single unchecked os.write() call can therefore silently truncate a
    steering block. Loop until every byte has actually landed."""
    view = memoryview(data)
    while view:
        n = os.write(fd, view)
        if n == 0:
            raise OSError("os.write() returned 0 bytes written")
        view = view[n:]


def _check_environment() -> None:
    """Every write in this module refuses to act unless we are on the
    designated publish host and the archive is fully synced. Two hosts racing
    on an unsynced Dropbox tree is exactly how you get a conflicted copy
    instead of one winner (SAFETY.md section 6).

    The two gates have separate opt-outs on purpose. They protect against
    different things, and a single combined switch meant that anything wanting
    to run off-host (a test) also silently lost the sync check - the far more
    dangerous of the two to lose by accident.
    """
    if os.environ.get("AUTO_PROPOSALS_ALLOW_ANY_HOST") != "1":
        ok, reason = publish_host_ok()
        if not ok:
            raise PathRefused(reason)
    if os.environ.get("AUTO_PROPOSALS_ALLOW_UNSYNCED") != "1":
        ok, reason = dropbox_synced()
        if not ok:
            raise PathRefused(reason)


def _fsync_dir(dir_path: Path) -> None:
    fd = os.open(dir_path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _open_parent_dir_fd(parent: Path) -> int:
    """Open `parent` by path exactly once, with O_NOFOLLOW, and hand back a
    file descriptor. Every subsequent operation on the target (temp-file
    create, link, replace, stat, unlink) then addresses it by *name* under
    this fd rather than by re-walking the path string.

    resolve_owned() already proved every component isn't a symlink at
    validation time - but between that check and the actual write, an
    attacker (or a racing Dropbox sync) could swap a path component out from
    under a string-based open/rename. Re-resolving by name against an
    already-open, already-verified directory fd closes that window: the
    kernel resolves relative to the fd we hold, not the filesystem state at
    whatever moment a second path-string lookup would happen.
    """
    return os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)


def _make_tmp_name() -> str:
    return f"{_TMP_PREFIX}{uuid.uuid4().hex}"


def _write_temp_dirfd(dir_fd: int, content: str) -> str:
    """Write `content` to a fresh temp file inside the directory addressed by
    `dir_fd`, fsync it, and return its name. Caller must clean it up (via
    _remove_tmp_dirfd) no matter what happens next."""
    name = _make_tmp_name()
    fd = os.open(name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644, dir_fd=dir_fd)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
    except BaseException:
        _remove_tmp_dirfd(dir_fd, name)
        raise
    return name


def _write_temp_bytes_dirfd(dir_fd: int, data: bytes) -> str:
    """Byte-for-byte sibling of _write_temp_dirfd, for artifacts that are not
    text. Same contract: caller must clean up the returned temp name.

    This exists because _write_temp_dirfd opens the fd in text mode and would
    apply newline translation to a PDF, corrupting it in a way that is silent
    until someone opens the file.
    """
    name = _make_tmp_name()
    fd = os.open(name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644, dir_fd=dir_fd)
    try:
        try:
            _write_all(fd, data)
            os.fsync(fd)
        finally:
            os.close(fd)
    except BaseException:
        _remove_tmp_dirfd(dir_fd, name)
        raise
    return name


def _hash_dirfd_or_none(dir_fd: int, name: str) -> str | None:
    """Read the file `name` (inside `dir_fd`) and return its sha256 hex
    digest the same way read_owned() computes it, or None if it doesn't
    exist. Used to re-check a regenerate target's content immediately before
    the swap (see publish_regenerate)."""
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)
    except FileNotFoundError:
        return None
    try:
        h = hashlib.sha256()
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            h.update(chunk)
    finally:
        os.close(fd)
    return h.hexdigest()


def _fence_for(text: str) -> str:
    """Wrap `text` in a code fence long enough that the text cannot break out.

    Steering arrives from Slack and from Alon's own typing, and it is
    re-read on the next run. Unfenced, a line like `- [x] approve T2` sitting
    inside a quoted instruction would be indistinguishable from Alon actually
    ticking that box. A three-backtick fence is not enough on its own either:
    steering text quite legitimately contains code fences. So the fence is
    always one backtick longer than the longest backtick run in the payload,
    which is the CommonMark rule for exactly this reason.
    """
    longest = 0
    run = 0
    for ch in text:
        run = run + 1 if ch == "`" else 0
        longest = max(longest, run)
    fence = "`" * max(3, longest + 1)
    return f"{fence}\n{text}\n{fence}"


def _refuse_if_frozen(root: Path, rel: str) -> None:
    """Refuse to write into a call folder that has Dropbox conflicted copies
    of owned artifacts in it.

    A conflicted copy means two hosts disagree about the artifact's content,
    and one of those copies may be the one carrying Alon's selection. Writing
    a further artifact on top of that ambiguity would build on a decision we
    cannot actually read. SAFETY.md section 5: conflicts halt, they are not
    filtered.
    """
    call = rel.split("/")[0]
    if call in ("OPEN.md", "CORPUS.md"):
        # These two artifacts live at the archive root, not in a call
        # folder - a conflicted copy of either sits right next to it at the
        # root, not inside some call's directory. owned_artifact_conflicts()
        # only ever scans call folders, so it would never see this; use the
        # root-level counterpart instead.
        stem = call[: -len(".md")]
        conflicts = root_artifact_conflicts(Path(root), stem)
        if conflicts:
            names = ", ".join(p.name for p in conflicts)
            raise PathRefused(
                f"{call} is frozen: Dropbox conflicted copies at the archive root "
                f"({names}). Reconcile them by hand before auto-proposals writes here again."
            )
        return
    conflicts = owned_artifact_conflicts(Path(root) / call)
    if conflicts:
        names = ", ".join(p.name for p in conflicts)
        raise PathRefused(
            f"call {call!r} is frozen: Dropbox conflicted copies of owned artifacts "
            f"({names}). Reconcile them by hand before auto-proposals writes here again."
        )


_CREATABLE_SUBDIRS = ("outlines", "drafts", "tex", "grf")


def _ensure_parent(root: Path, target: Path) -> None:
    """Make sure `target`'s directory exists, creating only the specific
    subdirectory shapes the grammar allows, inside a call folder that already
    exists.

    We deliberately refuse to `mkdir -p` our way to a target. A call folder is
    supplied by a human dropping a call's material into the archive; if the
    model hallucinates or misspells a call name, `mkdir(parents=True)` would
    quietly grow a new top-level folder in someone's proposal archive and the
    mistake would then sync to five machines.

    The allowed shapes, relative to a call folder, are exhaustive on purpose -
    an allow-list of literal shapes rather than a rule about depth, so a new
    grammar entry cannot silently widen what may be created:

        outlines/            drafts/            tex/            grf/
        outlines/tex/        drafts/tex/                        grf/<slug>/
    """
    parent = target.parent
    if parent.is_dir():
        return

    root = Path(root)
    try:
        rel_parts = parent.relative_to(root).parts
    except ValueError:
        raise PathRefused(f"{parent} is outside the archive root; refused") from None

    # rel_parts[0] is the call folder, which must already exist. Anything
    # shallower than that is an attempt to create a call folder or a top-level
    # directory, both of which are refused outright.
    if len(rel_parts) < 2:
        raise PathRefused(
            f"{parent} does not exist. auto-proposals never creates call folders - "
            "a call folder only ever comes from a human putting the call's "
            "material in the archive."
        )

    call_dir = root / rel_parts[0]
    if not call_dir.is_dir():
        raise PathRefused(
            f"{call_dir} does not exist. auto-proposals never creates call folders."
        )

    sub = rel_parts[1:]
    allowed = (
        len(sub) == 1 and sub[0] in _CREATABLE_SUBDIRS
    ) or (
        len(sub) == 2 and sub[0] in ("drafts", "outlines") and sub[1] == "tex"
    ) or (
        # One folder per figure, named by the figure's own slug.
        len(sub) == 2 and sub[0] == "grf" and bool(re.fullmatch(r"[a-z0-9-]+", sub[1]))
    )
    if not allowed:
        raise PathRefused(
            f"{parent} is not a directory auto-proposals may create "
            f"(allowed: outlines/, drafts/, tex/, grf/, outlines/tex/, "
            f"drafts/tex/, grf/<slug>/)"
        )

    # Create the missing levels one at a time, fsyncing each parent, so an
    # interrupted run leaves a consistent tree rather than a half-made path.
    current = call_dir
    for part in sub:
        current = current / part
        if not current.is_dir():
            current.mkdir()
            _fsync_dir(current.parent)


# ---------------------------------------------------------------------------
# create
# ---------------------------------------------------------------------------

def publish_create(root: Path, rel: str, text: str, *, frontmatter: dict) -> Path:
    """Create a brand-new owned artifact. Refuses outright if the target
    already exists - the caller must publish the next -v<N> instead. This is
    what makes Alon's hand-ticked checkboxes unclobberable: this function
    physically cannot overwrite anything.

    Text artifacts only. Companions (.pdf, .tex, .bib) share the "create" mode
    because resolve_owned() must apply the same containment and symlink checks
    to them, but they must never come through here - see the guard below.
    """
    _check_environment()

    mode = write_mode_for(rel)
    if mode != "create":
        raise PathRefused(f"{rel!r} is not a 'create' artifact (mode={mode!r})")

    # Companions are in the grammar as "create" targets, which would otherwise
    # let them be written here in text mode with frontmatter prepended and a
    # completeness marker appended. That corrupts a PDF outright and stops a
    # .tex compiling - so the grammar alone is not enough, and this is the
    # guard that makes publish_create_companion the only way in.
    if is_draft_companion(rel):
        raise PathRefused(
            f"{rel!r} is a draft companion and must not be written as text; "
            "frontmatter and the completeness marker would corrupt it. Use "
            "publish_create_companion (CLI: create-companion) instead."
        )

    target = resolve_owned(Path(root), rel)
    _refuse_if_frozen(Path(root), rel)
    _ensure_parent(Path(root), target)
    content = _compose_content(frontmatter, text)

    # Write the full content to a temp file and fsync it *before* touching
    # the target at all. Once that has succeeded, publishing the target is
    # just os.link()-ing a new directory entry onto the same, already-
    # complete inode - there is no "target half-written" state to recover
    # from, and so no reason this function would ever need to remove
    # anything other than its own temp file (which is the one deletion this
    # module is allowed to perform). The parent is addressed by an
    # already-opened, already-verified fd throughout (see
    # _open_parent_dir_fd) so nothing here re-resolves the path by string.
    dir_fd = _open_parent_dir_fd(target.parent)
    try:
        tmp_name = _write_temp_dirfd(dir_fd, content)
        try:
            try:
                os.link(tmp_name, target.name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd, follow_symlinks=False)
            except FileExistsError:
                raise PathRefused(f"{target} already exists; publish the next -v<N> instead") from None
            except OSError as exc:
                if exc.errno == errno.ELOOP:
                    raise PathRefused(f"{target} is a symlink; refused") from None
                raise

            os.fsync(dir_fd)
        finally:
            _remove_tmp_dirfd(dir_fd, tmp_name)
    finally:
        os.close(dir_fd)

    return target


def _check_companion_payload(rel: str, data: bytes) -> None:
    """Sanity-check a companion's bytes against what its extension promises.

    Companions are written verbatim, so nothing downstream will ever notice
    that a .pdf holds an error page or that the .tex and .pdf payloads were
    passed in the wrong order. And because create-only means the file cannot
    be corrected in place - fixing it costs a whole new draft letter - the
    cheapest place to catch it is before the write.

    This is a shape check, not validation. It is not trying to prove the PDF
    renders or the LaTeX compiles, only that the payload is not obviously the
    wrong kind of thing.
    """
    if not data:
        raise PathRefused(f"refusing to publish {rel!r}: payload is empty")

    if rel.endswith(".pdf"):
        if not data.startswith(b"%PDF-"):
            raise PathRefused(
                f"refusing to publish {rel!r}: payload does not start with the "
                f"%PDF- header (got {data[:8]!r}), so it is not a PDF"
            )
        return
    if rel.endswith(".png"):
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise PathRefused(
                f"refusing to publish {rel!r}: payload does not start with the "
                f"PNG signature (got {data[:8]!r}), so it is not a PNG"
            )
        return

    # .tex and .bib are text and must be readable by a TeX engine. A payload
    # that is not UTF-8 is either the wrong file entirely or already mangled.
    try:
        data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PathRefused(
            f"refusing to publish {rel!r}: payload is not valid UTF-8 ({exc})"
        ) from None


def publish_create_companion(root: Path, rel: str, data: bytes) -> Path:
    """Create a brand-new draft companion - the rendered PDF, or the LaTeX
    source it was compiled from - writing `data` verbatim.

    Companions are held to a stricter rule than any other artifact: **the
    markdown draft they belong to must already exist and be owned by us.**
    Neither a PDF nor a .tex we hand back unchanged can carry our frontmatter,
    so neither has a way to say who generated it; anchoring both to an .md we
    can prove we wrote is what keeps `drafts/` from becoming a place arbitrary
    files can be deposited. It also enforces the naming scheme by construction -
    a companion cannot drift to a different date or letter than its draft.

    Note what is deliberately absent: no frontmatter is prepended and no
    completeness marker is appended. Both would corrupt a PDF, and both would
    stop a .tex compiling. Truncation is therefore not detectable the way it is
    for our markdown artifacts, which is the honest reason the write is done as
    write-temp-then-link like every other create here - the target only ever
    appears once its bytes are complete and fsynced.
    """
    _check_environment()

    if is_figure(rel):
        raise PathRefused(
            f"{rel!r} is a figure, which has no markdown sibling to take its "
            "provenance from. Use publish_create_figure (CLI: create-figure)."
        )

    if not is_draft_companion(rel):
        raise PathRefused(
            f"{rel!r} is not a companion; verbatim publishing is limited to the "
            "PDF and LaTeX sources of a proposal, outline or draft, and to "
            "figures under <call>/grf/<slug>/"
        )

    _check_companion_payload(rel, data)

    md_rel = companion_md_rel_for(rel)
    found = read_owned(Path(root), md_rel)
    if found is None:
        raise PathRefused(
            f"refusing to publish {rel!r}: its markdown draft {md_rel!r} does not "
            "exist. Publish the draft first; a companion is derived from it, never "
            "a standalone artifact."
        )
    if not is_agent_owned(found[0]):
        raise PathRefused(
            f"refusing to publish {rel!r}: the markdown draft {md_rel!r} is not "
            "owned by auto-proposals, so this companion would have no provenance "
            "and would be depositing a file next to someone else's."
        )

    target = resolve_owned(Path(root), rel)
    _refuse_if_frozen(Path(root), rel)
    _ensure_parent(Path(root), target)

    dir_fd = _open_parent_dir_fd(target.parent)
    try:
        tmp_name = _write_temp_bytes_dirfd(dir_fd, data)
        try:
            try:
                os.link(tmp_name, target.name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd, follow_symlinks=False)
            except FileExistsError:
                raise PathRefused(
                    f"{target} already exists; a new rendering belongs to a new draft letter"
                ) from None
            except OSError as exc:
                if exc.errno == errno.ELOOP:
                    raise PathRefused(f"{target} is a symlink; refused") from None
                raise

            os.fsync(dir_fd)
        finally:
            _remove_tmp_dirfd(dir_fd, tmp_name)
    finally:
        os.close(dir_fd)

    return target


def publish_create_figure(root: Path, rel: str, data: bytes) -> Path:
    """Publish one figure file - a TikZ source or a compiled image - under
    `<call>/grf/<slug>/`, writing `data` verbatim.

    Figures need their own mode because they break the companion rule: a
    companion borrows provenance from the .md of identical basename, and a
    figure has no such sibling. A figure belongs to the CALL, not to one
    document, and deliberately so - several drafts and versions of a draft
    should include the same figure rather than each carrying a private copy
    that drifts.

    Provenance is therefore positional: `grf/` is a directory only
    auto-proposals ever creates, and every path inside it must match the
    figure grammar (`<slug>/<slug>.{tex,pdf,png}`, slug lowercase). That is
    weaker than frontmatter, and it is why the mode is separate and narrow
    rather than folded into create-companion, where it would have widened the
    companion rule for every artifact type at once.

    Create-only, like everything else here: a changed figure is a new figure
    name, never an overwrite of the one a published PDF already embeds.
    """
    _check_environment()

    if not is_figure(rel):
        raise PathRefused(
            f"{rel!r} is not a figure path; figures are "
            "<call>/grf/<slug>/<slug>.{tex,pdf,png} with a lowercase slug"
        )
    _check_companion_payload(rel, data)

    target = resolve_owned(Path(root), rel)
    _ensure_parent(Path(root), target)

    tmp_name = None
    dir_fd = _open_parent_dir_fd(target.parent)
    try:
        tmp_name = _write_temp_bytes_dirfd(dir_fd, data)
        try:
            try:
                os.link(tmp_name, target.name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd, follow_symlinks=False)
            except FileExistsError:
                raise PathRefused(
                    f"{target} already exists; a changed figure belongs to a new "
                    "figure name, because a published PDF already embeds this one"
                ) from None
            except OSError as exc:
                if exc.errno == errno.ELOOP:
                    raise PathRefused(f"{target} is a symlink; refused") from None
                raise

            os.fsync(dir_fd)
        finally:
            _remove_tmp_dirfd(dir_fd, tmp_name)
    finally:
        os.close(dir_fd)

    return target


# ---------------------------------------------------------------------------
# append
# ---------------------------------------------------------------------------

def publish_append(root: Path, rel: str, block_text: str) -> Path:
    """Append a fenced, dated steering block to an artifact the agent already
    owns.

    This is a true O_APPEND write to the existing inode, not a
    write-temp-and-replace. Replace would have been atomic but wrong: it
    reads, concatenates, and swaps in a whole new file, so anything Alon (or
    another host's Dropbox sync) wrote between our read and our swap is
    silently discarded. O_APPEND cannot lose a concurrent edit, cannot
    shorten the file, and never rewrites a byte that was already there.
    """
    _check_environment()

    target = resolve_owned(Path(root), rel)
    _refuse_if_frozen(Path(root), rel)

    dir_fd = _open_parent_dir_fd(target.parent)
    try:
        # A single dir_fd-addressed open, with O_NOFOLLOW, replaces the old
        # separate exists()/islink()/open() sequence: those were three
        # different lookups of the same path string, each a chance for the
        # filesystem underneath to have changed between them.
        try:
            fd = os.open(target.name, os.O_RDWR | os.O_APPEND | os.O_NOFOLLOW, dir_fd=dir_fd)
        except FileNotFoundError:
            raise PathRefused(f"{target} does not exist; append requires an existing owned artifact") from None
        except OSError as exc:
            if exc.errno == errno.ELOOP:
                raise PathRefused(f"{target} is a symlink; refused") from None
            raise

        try:
            chunks = []
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                chunks.append(chunk)
            original = b"".join(chunks).decode("utf-8")
            if not is_agent_owned(original):
                raise PathRefused(f"{target} has no auto-proposals provenance frontmatter; refused")

            stamp = time.strftime("%d/%m/%Y %H:%M")
            block = (
                f"\n\n<!-- auto-proposals: steering appended {stamp} -->\n"
                f"{_fence_for(block_text)}\n"
            )

            # O_APPEND: the kernel positions every write at the current end
            # of file, so we never need to know (or re-state) what was
            # already there. _write_all loops so a short write can never
            # silently truncate the block.
            _write_all(fd, block.encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        os.close(dir_fd)

    return target


# ---------------------------------------------------------------------------
# regenerate
# ---------------------------------------------------------------------------

def publish_regenerate(
    root: Path,
    rel: str,
    text: str,
    *,
    expected_sha256: str | None,
    frontmatter: dict,
) -> Path:
    """Read-modify-write OPEN.md / CORPUS.md under compare-and-swap: the
    caller must pass the SHA-256 it last read. If the on-disk file has since
    changed, we refuse rather than clobber a concurrent edit.

    Residual race (documented honestly, not swept under the rug - see
    SAFETY.md #3): this function re-hashes the target a second time,
    immediately before the swap, which shrinks the window between "we know
    what's on disk" and "we replace it" down to the handful of instructions
    between that re-hash and os.replace(). It cannot close that window
    completely without a kernel primitive Linux does not give us for this
    case - renameat2(RENAME_EXCHANGE) atomically swaps two *existing* names,
    it does not compare-and-swap against content, so it would not actually
    help here. A write that lands in the surviving few-instruction window is
    still possible in principle; it is not eliminated, only made extremely
    unlikely.
    """
    _check_environment()

    mode = write_mode_for(rel)
    if mode != "regenerate":
        raise PathRefused(f"{rel!r} is not a 'regenerate' artifact (mode={mode!r}); it is {mode!r}")

    root_path = Path(root)
    target = resolve_owned(root_path, rel)
    _refuse_if_frozen(root_path, rel)

    current = read_owned(root, rel)
    if current is None:
        if expected_sha256 is not None:
            raise PathRefused(
                f"{target} does not exist but expected_sha256 was given; refused"
            )
    else:
        current_text, current_sha = current
        if expected_sha256 != current_sha:
            raise PathRefused(
                f"{target} has changed since it was read (sha mismatch); "
                "concurrent-edit conflict, refused"
            )
        # A file that exists but carries no auto-proposals provenance is
        # human-written (SAFETY.md #4: provenance is what makes it safe to
        # touch at all). Overwriting it just because its hash happened to
        # match whatever the caller thought it read would clobber
        # Alon's own edits to OPEN.md/CORPUS.md.
        if not is_agent_owned(current_text):
            raise PathRefused(
                f"{target} exists and is not agent-owned (missing auto-proposals "
                "provenance frontmatter); refusing to regenerate over a human-written file"
            )

    content = _compose_content(frontmatter, text)

    dir_fd = _open_parent_dir_fd(target.parent)
    try:
        tmp_name = _write_temp_dirfd(dir_fd, content)
        try:
            final_sha = _hash_dirfd_or_none(dir_fd, target.name)
            if final_sha != expected_sha256:
                raise PathRefused(
                    f"{target} changed since it was read (sha mismatch immediately "
                    "before replace); concurrent-edit conflict, refused"
                )
            os.replace(tmp_name, target.name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
            os.fsync(dir_fd)
        finally:
            _remove_tmp_dirfd(dir_fd, tmp_name)
    finally:
        os.close(dir_fd)

    return target


# ---------------------------------------------------------------------------
# read
# ---------------------------------------------------------------------------

def read_owned(root: Path, rel: str) -> tuple[str, str] | None:
    """Read an owned artifact and return (text, sha256_hex), or None if it
    does not exist. This is the only sanctioned way to get the SHA a caller
    later passes back in as expected_sha256 for publish_regenerate.

    Deliberately NOT gated on the publish host or on Dropbox sync state.
    Reading has to work everywhere: gating it would leave a non-publish host
    unable even to report what the archive contains, and would push callers
    into opening these files by hand instead of through the chokepoint.

    The SHA is taken over the file's RAW BYTES, never over decoded-and-
    re-encoded text. Two reasons, both load-bearing:

    * `read_text()` applies universal-newline translation, so a CRLF file
      would hash as though it were LF here while _hash_dirfd_or_none() (which
      reads bytes) hashed the real content. The two would disagree and
      publish_regenerate would refuse every regenerate of that file with a
      spurious mismatch.
    * A file with non-UTF-8 bytes must not be able to crash a caller that only
      wanted to know whether the artifact had changed underneath it.

    Decoding still happens strictly, because callers get text back and a
    silently mangled decode would be written straight back out on the next
    regenerate - but it fails as a refusal naming the file, not as a bare
    UnicodeDecodeError from somewhere deep in a scan.
    """
    target = resolve_owned(Path(root), rel)
    if not target.exists():
        return None
    if os.path.islink(target):
        raise PathRefused(f"{target} is a symlink; refused")

    data = target.read_bytes()
    sha = hashlib.sha256(data).hexdigest()
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PathRefused(
            f"{target} is not valid UTF-8 ({exc}); refusing to read it as an "
            "owned artifact"
        ) from exc
    return text, sha


# ---------------------------------------------------------------------------
# Frontmatter
# ---------------------------------------------------------------------------

_SPECIAL_LEADING = set("!&*-?|>%@`\"'#{}[],")


def _quote_scalar(value: str) -> str:
    needs_quoting = (
        value == ""
        or ":" in value
        or (value[0] in _SPECIAL_LEADING)
    )
    if not needs_quoting:
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _unquote_scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        inner = value[1:-1]
        return inner.replace('\\"', '"').replace("\\\\", "\\")
    return value


COMPLETE_MARKER = "<!-- auto-proposals:end -->"


def render_frontmatter(d: dict) -> str:
    """Render the YAML frontmatter block described in SAFETY.md #4.

    `complete` is always emitted last, regardless of where it appears (or
    doesn't appear) in `d`, because a reader is allowed to treat "the last
    key is complete: true" as its cue that the file is safe to act on -
    that invariant must hold no matter what order the caller built the dict.

    NOTE: `complete: true` here is informational only - it is written at the
    TOP of the file, so a write that gets truncated partway through the body
    still leaves a complete-looking frontmatter block behind. The actual
    completion sentinel that is_complete() checks is COMPLETE_MARKER,
    written by _compose_content() as the literal last line of the file,
    after the entire body. See SAFETY.md #4.
    """
    d = dict(d)
    complete = d.pop("complete", True)

    lines = ["---"]
    for key, value in d.items():
        if key == "sources":
            lines.append("sources:")
            items = value or []
            if not items:
                lines[-1] = "sources: []"
            else:
                for item in items:
                    lines.append(f"  - {_quote_scalar(str(item))}")
        elif isinstance(value, bool):
            lines.append(f"{key}: {'true' if value else 'false'}")
        else:
            lines.append(f"{key}: {_quote_scalar(str(value))}")

    lines.append(f"complete: {'true' if complete else 'false'}")
    lines.append("---")
    lines.append("")
    return "\n".join(lines)


_FRONTMATTER_BOUNDS_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n?", re.DOTALL)

# Frontmatter is trusted enough to drive is_agent_owned()/is_complete(), which
# in turn gate whether publish.py will write over a file. A block that is
# absurdly large or absurdly repetitive is a sign of either a bug or a
# deliberately hostile input (e.g. something upstream tried to smuggle
# thousands of duplicate keys to exhaust memory or to hide a late
# authoritative-looking key past a naive scanner) - cap both rather than
# trust an unbounded hand-rolled parser with untrusted-ish text.
_MAX_FRONTMATTER_BLOCK_BYTES = 16 * 1024
_MAX_FRONTMATTER_KEYS = 64


def parse_frontmatter(text: str) -> dict:
    """Tolerant reader for the frontmatter fields we ourselves write. This is
    intentionally not a general YAML parser (no third-party deps allowed) -
    it only needs to round-trip what render_frontmatter() produces plus
    whatever a human might plausibly hand-edit in that same shape.

    Only the FIRST `---`-delimited block is ever considered (via `.match`,
    anchored at position 0) - a block later in the file cannot masquerade as
    the frontmatter. Duplicate keys and oversized blocks are rejected rather
    than silently taking "whichever the loop saw last": a duplicate
    `generated_by` or `complete` key is exactly the kind of ambiguity an
    attacker (or a bad merge) could use to make a human reading the top of
    the file see one value while the parser picks another.
    """
    m = _FRONTMATTER_BOUNDS_RE.match(text)
    if not m:
        return {}

    body = m.group(1)
    if len(body.encode("utf-8", errors="replace")) > _MAX_FRONTMATTER_BLOCK_BYTES:
        return {}

    result: dict = {}
    current_list_key = None
    seen_keys: set = set()

    for raw_line in body.split("\n"):
        if not raw_line.strip():
            continue
        if raw_line.startswith("  - ") or raw_line.startswith("- "):
            if current_list_key is None:
                continue
            item = raw_line.strip()[2:].strip()
            result[current_list_key].append(_unquote_scalar(item))
            continue

        if ":" not in raw_line:
            continue
        key, _, rest = raw_line.partition(":")
        key = key.strip()
        rest = rest.strip()

        if key in seen_keys:
            # Ambiguous provenance is treated as no provenance at all.
            return {}
        seen_keys.add(key)
        if len(seen_keys) > _MAX_FRONTMATTER_KEYS:
            return {}

        if rest == "":
            result[key] = []
            current_list_key = key
            continue

        if rest == "[]":
            result[key] = []
            current_list_key = None
            continue

        current_list_key = None
        if rest == "true":
            result[key] = True
        elif rest == "false":
            result[key] = False
        else:
            result[key] = _unquote_scalar(rest)

    return result


def is_agent_owned(text: str) -> bool:
    """True only when the frontmatter both claims auto-proposals authorship
    AND carries the fields a real auto-proposals write always sets
    (artifact/call/version). This is an accident-guard, not authentication -
    see SAFETY.md #4 - but requiring the full shape rather than just the one
    `generated_by` scalar means a human hand-typing `generated_by:
    auto-proposals` at the top of a note they're drafting doesn't
    accidentally make it look machine-owned and eligible to be silently
    regenerated over."""
    fm = parse_frontmatter(text)
    if fm.get("generated_by") != "auto-proposals":
        return False
    return all(fm.get(key) not in (None, "") for key in ("artifact", "call", "version"))


def _compose_content(frontmatter: dict, text: str) -> str:
    """Compose the full file content: frontmatter block + body, with the
    real completion sentinel appended as the literal last line when the
    caller says the artifact is complete.

    `complete: true` inside the frontmatter (rendered by render_frontmatter)
    is NOT itself the completion signal - it's written at the TOP of the
    file, so a write that gets truncated partway through the body still has
    a complete-looking frontmatter block. COMPLETE_MARKER is written only
    after the entire body, so its presence can only mean every byte before
    it was actually persisted. See SAFETY.md #4.
    """
    complete = frontmatter.get("complete", True)
    content = render_frontmatter(frontmatter) + text
    if complete:
        if not content.endswith("\n"):
            content += "\n"
        content += COMPLETE_MARKER + "\n"
    return content


def is_complete(text: str) -> bool:
    """An artifact is complete iff COMPLETE_MARKER is the last non-blank
    line of the file - see _compose_content()'s docstring for why the
    frontmatter's own `complete: true` key cannot be trusted for this."""
    return text.rstrip("\n").endswith(COMPLETE_MARKER)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _cli_frontmatter(args) -> dict:
    if not args.frontmatter:
        return {}
    return json.loads(args.frontmatter)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="python3 -m lib.publish")
    sub = parser.add_subparsers(dest="command", required=True)

    for name in ("create", "append", "regenerate", "create-companion", "create-figure"):
        p = sub.add_parser(name)
        p.add_argument("--root", required=True)
        p.add_argument("--rel", required=True)
        p.add_argument("--file", required=True, help="path to a file with the content to publish")
        p.add_argument("--sha", default=None, help="expected sha256 (regenerate only)")
        p.add_argument(
            "--frontmatter",
            default=None,
            help="JSON object of frontmatter fields (create/regenerate only)",
        )

    args = parser.parse_args(argv)

    # create-companion is the one command whose payload is verbatim bytes.
    # Reading it as text would mangle a PDF, so it is dispatched before the
    # text path reads --file.
    if args.command in ("create-companion", "create-figure"):
        try:
            data = Path(args.file).read_bytes()
        except OSError as exc:
            print(f"refused: could not read --file {args.file!r}: {exc}", file=sys.stderr)
            return 1
        writer = (
            publish_create_companion
            if args.command == "create-companion"
            else publish_create_figure
        )
        try:
            path = writer(args.root, args.rel, data)
        except PathRefused as exc:
            print(f"refused: {exc}", file=sys.stderr)
            return 1
        print(str(path))
        return 0

    try:
        body = Path(args.file).read_text(encoding="utf-8")
    except OSError as exc:
        print(f"refused: could not read --file {args.file!r}: {exc}", file=sys.stderr)
        return 1

    try:
        if args.command == "create":
            path = publish_create(args.root, args.rel, body, frontmatter=_cli_frontmatter(args))
        elif args.command == "append":
            path = publish_append(args.root, args.rel, body)
        elif args.command == "regenerate":
            path = publish_regenerate(
                args.root,
                args.rel,
                body,
                expected_sha256=args.sha,
                frontmatter=_cli_frontmatter(args),
            )
        else:  # pragma: no cover - argparse guards this
            raise PathRefused(f"unknown command {args.command!r}")
    except PathRefused as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return 1

    print(str(path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
